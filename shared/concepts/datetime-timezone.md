# Concept: DateTime และ Timezone

## UTC คืออะไร

**UTC (Coordinated Universal Time)** คือ time standard กลางของโลก ไม่มี offset, ไม่มี DST
ทุก timezone ในโลกนิยามตัวเองเป็น offset จาก UTC:

```
UTC+0  = London (ฤดูหนาว), GMT
UTC+7  = Bangkok, Jakarta, Hanoi  (ไม่มี DST)
UTC+8  = Singapore, Kuala Lumpur, Beijing
UTC+9  = Tokyo, Seoul
UTC-5  = New York (ฤดูหนาว, EST)
```

## UTC Offset vs Timezone — ไม่ใช่สิ่งเดียวกัน

นี่คือ source of confusion ที่พบบ่อยที่สุด:

```
UTC+7          ≠          Asia/Bangkok
  ↑                            ↑
fixed offset              timezone name
ไม่รู้ DST             รู้ DST rules ทุก historical change
```

**ตัวอย่าง:**
- `America/New_York` ตอนนี้อาจเป็น UTC-5 (EST) หรือ UTC-4 (EDT) ขึ้นอยู่กับฤดูกาล
- ถ้าบันทึกแค่ `UTC-5` จะไม่รู้ว่าช่วงไหนของปีที่ record นี้ถูกสร้าง
- `Asia/Bangkok` ไม่มี DST → `UTC+7` ตลอดปี ดังนั้น Bangkok ทั้งสองรูปแบบใช้แทนกันได้ แต่ไม่จริงสำหรับทุก timezone

**IANA Timezone Database** คือ standard สำหรับ timezone name (เช่น `Asia/Bangkok`)
เก็บ historical DST rules ทุก country — Go ใช้ database นี้ผ่าน `time/tzdata` package

## Unix Timestamp

**Unix timestamp** = จำนวนวินาทีนับจาก `1970-01-01 00:00:00 UTC`

```
1704067200  =  2024-01-01 00:00:00 UTC
           =  2024-01-01 07:00:00 Asia/Bangkok
           =  2023-12-31 19:00:00 America/New_York (EST)
```

Unix timestamp ไม่มี timezone — มันคือ "จุดเวลาบน timeline" เสมอ
การแปลงเป็น human-readable ต้องการ timezone เพิ่มเติม

## Layers ที่มี Timezone ของตัวเอง

นี่คือต้นเหตุหลักของ bug ใน production — หลาย layer ต่างมี timezone setting:

```
┌─────────────────────────────────────────────────────┐
│  Docker OS / Linux                                  │
│  /etc/localtime → Asia/Bangkok                      │
│  ส่งผลต่อ: cron, log timestamp, time.Local          │
├─────────────────────────────────────────────────────┤
│  Go Runtime                                         │
│  time.Local = อ่านจาก OS ตอน startup               │
│  time.Now() ใช้ timezone ของ OS                    │
├─────────────────────────────────────────────────────┤
│  Database Connection                                │
│  PostgreSQL: SET timezone = 'Asia/Bangkok'          │
│  MySQL: SET time_zone = '+07:00'                   │
│  ส่งผลต่อ: TIMESTAMP column, NOW() function         │
├─────────────────────────────────────────────────────┤
│  Database Column Type                               │
│  TIMESTAMPTZ (PostgreSQL) — เก็บ UTC convert ตาม session │
│  TIMESTAMP   (PostgreSQL) — เก็บตรงตัว ไม่แปลง    │
│  DATETIME    (MySQL)      — เก็บตรงตัว ไม่แปลง    │
└─────────────────────────────────────────────────────┘
```

## ตัวอย่าง Bug: Bangkok Server + UTC Code

```
OS timezone:   Asia/Bangkok (UTC+7)
Go code:       time.Now()  → 2024-01-15 10:00:00 +0700
Insert to DB:  INSERT INTO events (created_at) VALUES ('2024-01-15 10:00:00')
DB timezone:   Asia/Bangkok

ผล: เก็บ 10:00 Bangkok ลง DB
```

ดูเหมือนถูก แต่ถ้า:

```
ย้าย DB ไป UTC server → อ่านได้ 10:00 UTC = 17:00 Bangkok ← ผิด 7 ชั่วโมง
Scale out เพิ่ม app server ที่ OS เป็น UTC → time.Now() = 03:00 UTC
Insert ลง DB ที่ Bangkok timezone → 03:00 ≠ 10:00 ← ข้อมูลไม่ consistent
```

## ตัวอย่างที่ถูก: เก็บ UTC เสมอ

**Go:**
```go
// ❌ ผิด — เก็บ local time
event.CreatedAt = time.Now()                    // depends on OS timezone

// ✅ ถูก — เก็บ UTC เสมอ
event.CreatedAt = time.Now().UTC()              // always UTC+0

// ✅ ถูก — แปลงเพื่อแสดงผลเท่านั้น
bkk, _ := time.LoadLocation("Asia/Bangkok")
display := event.CreatedAt.In(bkk)             // แปลงตอน render ไม่ใช่ตอนเก็บ
```

**Rust:**
```rust
use chrono::{DateTime, Utc};

// ❌ ผิด — Local time
let now = chrono::Local::now(); // timezone มาจาก OS

// ✅ ถูก — UTC เสมอ
let now: DateTime<Utc> = Utc::now();

// แปลงเพื่อแสดงผลใน Bangkok
use chrono_tz::Asia::Bangkok;
let display = now.with_timezone(&Bangkok);
println!("{}", display.format("%Y-%m-%d %H:%M:%S %Z"));
```

**Zig:**
```zig
// Zig stdlib มีแค่ Unix timestamp — ไม่มี timezone support built-in
const timestamp = std.time.timestamp(); // seconds since Unix epoch, UTC

// แปลงเป็น human-readable ต้องใช้ library หรือทำเอง
// timestamp นี้เป็น UTC+0 เสมอ — safe สำหรับเก็บลง database
```

## Go time.Time ภายใน

`time.Time` ใน Go เก็บ 3 อย่าง:

**Go:**
```go
type Time struct {
    wall uint64    // wall clock (nanoseconds since Jan 1 year 1)
    ext  int64     // monotonic clock reading (ถ้ามี)
    loc  *Location // timezone location
}
```

```go
t1 := time.Now()              // มี monotonic clock, location = Local
t2 := time.Now().UTC()        // มี monotonic clock, location = UTC
t3 := time.Now().Round(0)     // ตัด monotonic ออก — ใช้ก่อนเก็บลง DB หรือ serialize

// สำคัญ: time.Time ที่มี monotonic กับไม่มี compare กันอาจงงได้
t1 == t2  // false เพราะ location ต่าง แม้ชี้ "จุดเดียวกันบน timeline"
t1.Equal(t2)  // true — correct way to compare
```

**Rust `chrono::DateTime`:**
```rust
// chrono::DateTime<Tz> — generic over timezone
// DateTime<Utc>        — UTC fixed
// DateTime<Local>      — OS local timezone
// DateTime<FixedOffset> — เช่น +07:00

let utc: DateTime<Utc> = Utc::now();
let local: DateTime<Local> = Local::now();

// compare: ใช้ == ได้เลย chrono handle timezone ให้
// utc == local.with_timezone(&Utc) → true ถ้าเวลาเดียวกัน
```

**Zig:**
```zig
// Zig ไม่มี DateTime type built-in
// ใช้ Unix timestamp (i64) แล้วแปลงเองหรือใช้ library
const ts: i64 = std.time.timestamp();
const ms: i64 = std.time.milliTimestamp();
const ns: i64 = std.time.nanoTimestamp();
// ทั้งหมดเป็น UTC epoch — safe สำหรับ storage
```

## PostgreSQL: TIMESTAMP vs TIMESTAMPTZ

```sql
-- TIMESTAMP — เก็บตรงตัว ไม่แปลง timezone
created_at TIMESTAMP
INSERT: '2024-01-15 10:00:00'         → เก็บ 10:00:00
SELECT (session UTC+7): 10:00:00      → คืน 10:00:00 เสมอ

-- TIMESTAMPTZ — เก็บเป็น UTC แปลงตาม session timezone
created_at TIMESTAMPTZ
INSERT (session UTC+7): '2024-01-15 10:00:00+07' → เก็บ 03:00:00 UTC
SELECT (session UTC+7): 10:00:00+07   → แปลงกลับ
SELECT (session UTC):   03:00:00+00   → แสดงใน UTC
```

**Best practice:** ใช้ `TIMESTAMPTZ` เสมอใน PostgreSQL

## Best Practices

```
1. เก็บ UTC เสมอ
   - time.Now().UTC() ไม่ใช่ time.Now()
   - Database column ใช้ TIMESTAMPTZ (PostgreSQL) หรือ DATETIME UTC (MySQL)

2. แปลง timezone ที่ display layer เท่านั้น
   - API response → RFC3339 พร้อม offset: "2024-01-15T03:00:00Z"
   - UI → แปลงจาก UTC เป็น user timezone บน client

3. อย่าเชื่อ OS timezone
   - Set timezone explicit ใน code: time.Now().UTC()
   - ไม่พึ่ง time.Local ใน business logic

4. ใช้ IANA timezone name ไม่ใช่ offset
   - "Asia/Bangkok" ไม่ใช่ "UTC+7"
   - เพราะ offset อาจเปลี่ยนในประวัติศาสตร์หรือกฎหมาย

5. Serialize เป็น RFC3339 / ISO8601
   - "2024-01-15T10:00:00+07:00" — มี timezone info ครบ
   - ไม่ใช่ "2024-01-15 10:00:00" — ambiguous ไม่รู้ timezone
```

## Linux: ตรวจสอบ Timezone ของ System

```bash
# ดู timezone ปัจจุบัน
timedatectl status
cat /etc/timezone
ls -la /etc/localtime   # symlink ชี้ไป IANA timezone file

# เปลี่ยน timezone (systemd)
timedatectl set-timezone Asia/Bangkok
timedatectl set-timezone UTC

# ใน Docker — set ผ่าน environment variable
ENV TZ=UTC   # แนะนำให้ set UTC เสมอใน container

# ตรวจ timezone ของ PostgreSQL session
SHOW timezone;
SELECT NOW();             -- แสดงตาม session timezone
SELECT NOW() AT TIME ZONE 'UTC';  -- force UTC
```

## ระดับลึก: Monotonic Clock vs Wall Clock

Linux kernel มี 2 clock:

```
CLOCK_REALTIME  — wall clock, อ่านได้จาก time.Now()
                  อาจกระโดด backward ถ้า NTP sync หรือ admin เปลี่ยนเวลา
                  ใช้สำหรับ: timestamp, log, record creation time

CLOCK_MONOTONIC — monotonic clock, ไม่กระโดดย้อน
                  ใช้สำหรับ: measure duration, timeout, benchmark
```

```go
// วัด duration — ใช้ monotonic
start := time.Now()
doWork()
elapsed := time.Since(start)   // ใช้ monotonic internally — ถูกต้องแม้ NTP sync

// เก็บ timestamp — ต้องการ wall clock
created := time.Now().UTC()    // ใช้ wall clock
```
