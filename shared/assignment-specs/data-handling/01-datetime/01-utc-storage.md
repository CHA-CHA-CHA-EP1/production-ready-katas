---
tier: data-handling/01-datetime
difficulty: 2
concepts: [utc, timezone, time-now, database-timestamp, timestamptz]
---

# Kata: UTC Storage

## Context

ทุก service ที่เก็บ timestamp ลง database มีโอกาสเก็บผิด timezone โดยไม่รู้ตัว
Bug นี้ไม่โชว์ใน dev (ทุก machine ใช้ timezone เดียวกัน) แต่โชว์ตอน deploy บน server ที่ OS timezone ต่างออกไป
หรือตอนที่ต้องย้าย database ไปอีก region

## Real World Incidents

**Incident 1 — ข้อมูล transaction เลื่อน 7 ชั่วโมงหลัง migrate (e-commerce, Thailand)**
App server ตั้ง OS เป็น `Asia/Bangkok`, code ใช้ `time.Now()` ไม่ใช่ `.UTC()`
PostgreSQL column เป็น `TIMESTAMP` (ไม่ใช่ `TIMESTAMPTZ`)
หลัง migrate database ไป AWS RDS region `ap-southeast-1` ที่ default เป็น UTC
record เก่าทุกตัวแสดงเวลาผิดไป 7 ชั่วโมงใน report
แก้โดย backfill ข้อมูล + เปลี่ยน column เป็น `TIMESTAMPTZ` + แก้ code ให้ store UTC

**Incident 2 — Cron job ยิง report ผิดเวลาใน multi-region setup**
Cron schedule กำหนดด้วย local time `0 9 * * *` (9 โมงเช้า)
Server ย้ายจาก Bangkok ไป Singapore (UTC+8) → cron ยิงเร็วขึ้น 1 ชั่วโมง
Report ที่ควรเป็น "ยอดขายวันนี้" ได้ข้อมูลที่ตัด boundary ผิด
แก้โดยใช้ UTC เสมอใน cron และ query boundary

**Incident 3 — `created_at` ใน audit log ไม่ consistent ระหว่าง services**
Microservices หลายตัวเก็บ `created_at` ต่างกัน — บางตัว UTC, บางตัว Bangkok
Join ข้ามตารางเพื่อ audit trail ได้ timestamp ที่ไม่ตรงกัน
ทำให้ debug "event ไหนเกิดก่อน" ไม่ได้
แก้โดยกำหนด standard ทั้ง company: เก็บ UTC+0 ทุกที่ แสดง Bangkok เฉพาะ UI

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
event.CreatedAt = time.Now()  // ได้ local timezone จาก OS
db.Save(event)
```

**พังตอนไหน:**
- Dev machine Bangkok + Prod server UTC → ค่าต่างกัน 7 ชั่วโมง
- Database column `TIMESTAMP` เก็บตรงตัวไม่แปลง → query ด้วย UTC range ผิด
- multi-region → แต่ละ server ส่ง timezone ต่างกันลง DB เดียวกัน

**Root cause:**
`time.Now()` คืน wall clock ที่มี `time.Local` เป็น location
location นั้นมาจาก OS ซึ่งต่างกันใน dev กับ production

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `time.Now()` — return type คืออะไร? location ของ Time ที่ได้คือ timezone อะไร?
- hint: `(time.Time).UTC()` — return อะไร? location เปลี่ยนไหม หรือแค่ representation?
- hint: `(time.Time).Equal()` vs `==` — ต่างกันยังไง? อันไหนถูกต้องสำหรับ compare timestamp?
- hint: `(time.Time).In()` — ใช้ทำอะไร? รับ argument อะไร?
- `time.LoadLocation("Asia/Bangkok")` return อะไร? error เมื่อไหร่?

### Rust

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `chrono::Utc::now()` — return type คืออะไร? ต่างจาก `chrono::Local::now()` ยังไง?
- hint: `chrono::DateTime<Utc>` vs `chrono::NaiveDateTime` — ต่างกันยังไง? อันไหนเก็บ timezone?
- hint: `chrono_tz::Asia::Bangkok` — ใช้ convert timezone ยังไง?
- Rust `chrono` crate serialize เป็น JSON/database ยังไง? `serde` feature ทำอะไร?
- `DateTime<Utc>.naive_utc()` กับ `DateTime<Utc>.naive_local()` ต่างกันยังไง?

### Zig

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std.time.timestamp()` — return type คืออะไร? เป็น UTC ไหม?
- hint: `std.time.milliTimestamp()` และ `std.time.nanoTimestamp()` — ต่างกันยังไง?
- Zig standard library มี timezone support ไหม? ถ้าไม่มีจะ handle ยังไง?
- Unix timestamp ที่ Zig return — แปลงเป็น human-readable format ยังไง?
- ถ้าต้องการ timezone-aware datetime ใน Zig ต้องใช้ library อะไร?

## Task

เขียน `EventStore` struct ที่:

1. `Save(name string) (Event, error)` — สร้าง event พร้อม `CreatedAt` เป็น UTC
2. `FindBetween(from, to time.Time) ([]Event, error)` — query event ใน time range
3. `DisplayInBangkok(e Event) string` — format timestamp สำหรับแสดงผลใน Bangkok timezone

```go
type Event struct {
    ID        int
    Name      string
    CreatedAt time.Time  // ต้องเป็น UTC เสมอ
}
```

## Requirements

- `CreatedAt` ต้องเป็น UTC+0 เสมอ ไม่ว่า OS timezone จะเป็นอะไร
- `FindBetween` ต้องรับ `from`/`to` ในทุก timezone แล้วแปลงเป็น UTC ก่อน compare
- `DisplayInBangkok` ต้องแสดง format `2006-01-02 15:04:05 WIB` (Bangkok time)
- ห้าม hardcode `+7` — ต้องใช้ IANA timezone name `Asia/Bangkok`

## Acceptance Criteria

- [ ] `Save()` บน OS timezone ใดก็ตาม → `CreatedAt.Location()` เป็น UTC
- [ ] Event ที่ save จาก OS Bangkok และ OS UTC — `Equal()` เป็น true ถ้าสร้างเวลาเดียวกัน
- [ ] `FindBetween` ด้วย Bangkok time range → คืน event ที่ถูกต้อง
- [ ] `DisplayInBangkok` แสดง Bangkok time ถูกต้อง ไม่ใช่ UTC
- [ ] เมื่อ simulate `time.Local = UTC` code ยังทำงานถูกต้อง

## Concepts Involved

- `datetime-timezone` — UTC, offset, IANA timezone → `shared/concepts/datetime-timezone.md`
