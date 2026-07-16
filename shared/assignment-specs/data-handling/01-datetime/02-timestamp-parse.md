---
tier: data-handling/01-datetime
difficulty: 3
concepts: [timestamp-parsing, ambiguous-timezone, rfc3339, log-timestamp]
---

# Kata: Timestamp Parsing

## Context

Log จากระบบต่างๆ มี timestamp format หลากหลายมาก — บางอันมี timezone, บางอันไม่มี
การ parse timestamp ที่ไม่มี timezone info เป็น trap ที่คนเจอบ่อยมาก
เพราะ parse ได้โดยไม่ error แต่ได้เวลาผิดโดยไม่รู้

## Real World Incidents

**Incident 1 — Log correlation ผิดระหว่าง 2 services**
Service A log: `2024-01-15 10:30:00` (ไม่มี timezone, server UTC+7)
Service B log: `2024-01-15T03:30:00Z` (UTC)
ทั้งคู่เกิดเวลาเดียวกัน แต่ parse แล้ว diff กัน 7 ชั่วโมง
Kibana แสดง timeline ผิด → debug ไม่ได้ว่า request ไหนเกิดก่อน
แก้โดย standardize log format ทั้ง company เป็น RFC3339 + UTC

**Incident 2 — Import CSV จาก partner แล้ว timestamp เลื่อน**
Partner ส่ง CSV column `transaction_date` format `15/01/2024 10:30`
code ใช้ `time.Parse("02/01/2006 15:04", str)` → ได้ `time.Time` ที่ location เป็น UTC (default)
แต่ partner อยู่ Bangkok → ข้อมูลทุก row เลื่อน 7 ชั่วโมง
แก้โดย confirm กับ partner ว่า timestamp ใช้ timezone อะไร แล้ว parse ด้วย location ที่ถูก

**Incident 3 — DST bug ใน timestamp comparison (US service)**
Log timestamp `2024-03-10 02:30:00` (US Eastern) ไม่มี offset
วันนั้น DST เปลี่ยน → `02:30` ไม่มีอยู่จริง (clock skip จาก 02:00 ไป 03:00)
`time.ParseInLocation` return เวลาที่ ambiguous
service ตีความผิด → event ดูเหมือนเกิด 1 ชั่วโมงก่อนเวลาจริง

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
t, _ := time.Parse("2006-01-02 15:04:05", logLine)
```

**พังตอนไหน:**
- `time.Parse` กับ format ที่ไม่มี timezone → location เป็น `UTC` โดย default
- ถ้า string จริงๆ เป็น Bangkok time → ได้ค่าผิด 7 ชั่วโมง โดยไม่มี error เลย
- bug เงียบที่สุดใน codebase เพราะ "ทำงานได้" แต่ผิด

**Root cause:**
`time.Parse` ไม่รู้ timezone ของ string ที่ไม่มี offset
ต้องใช้ `time.ParseInLocation` เพื่อระบุว่า string นั้น "assume" timezone อะไร

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `time.Parse()` vs `time.ParseInLocation()` — ต่างกันยังไง? แต่ละอันเหมาะกับ input แบบไหน?
- hint: `time.Time.Location()` — หลัง Parse ได้ location อะไร? เช็คยังไง?
- RFC3339 format ใน Go เขียนยังไง? `time.RFC3339` กับ `time.RFC3339Nano` ต่างกันยังไง?
- `time.Parse("2006-01-02 15:04:05", "2024-01-15 10:30:00")` — result มี timezone อะไร?
- ถ้า timestamp string มี offset เช่น `+07:00` แต่ใช้ `ParseInLocation` ด้วย UTC จะได้อะไร?

### Rust

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `chrono::DateTime::parse_from_rfc3339()` — return type คืออะไร? error เมื่อไหร่?
- hint: `chrono::NaiveDateTime::parse_from_str()` — ต่างจาก `parse_from_rfc3339()` ยังไง? timezone มาจากไหน?
- hint: `chrono::format::strftime` — format string ใช้ syntax อะไร? ต่างจาก Go's reference time ยังไง?
- `DateTime<FixedOffset>` vs `DateTime<Utc>` — แปลงระหว่างกันยังไง?
- string ที่มี `+07:00` parse ด้วย `parse_from_rfc3339` แล้ว timezone ถูก preserve ไหม?

### Zig

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- Zig standard library มี datetime parsing built-in ไหม? ถ้าไม่มีต้องทำอะไร?
- hint: `std.fmt.parseInt()` — จะใช้ parse timestamp components (year, month, day) ยังไง?
- RFC3339 format คืออะไร? จะ parse `2024-01-15T10:30:00+07:00` ด้วย manual parsing ยังไง?
- Zig ไม่มี `time.Parse` เหมือน Go — จะ design `parseTimestamp` function ยังไง?
- offset string `+07:00` แปลงเป็น seconds ยังไง?

## Task

implement `parseTimestamp(s, assumeLocation)` ที่:

1. รองรับ format เหล่านี้:
   - RFC3339: `2024-01-15T10:30:00+07:00` หรือ `2024-01-15T03:30:00Z`
   - Common log: `15/Jan/2024:10:30:00 +0700`
   - No-timezone: `2024-01-15 10:30:00` → ใช้ `assumeLocation`
2. ถ้า format มี timezone info อยู่แล้ว — ใช้จาก string ไม่ใช่ `assumeLocation`
3. คืน UTC เสมอ ไม่ว่า input จะเป็น timezone อะไร

## Requirements

- Output ต้องเป็น UTC เสมอ
- String ที่มี offset → ใช้ offset จาก string (ไม่ override ด้วย `assumeLocation`)
- String ที่ไม่มี offset → ใช้ `assumeLocation` แปลงเป็น UTC
- `assumeLocation` เป็น nil → assume UTC
- ถ้า parse ไม่ได้ทุก format → return error ที่บอก format ที่ลองแล้วทั้งหมด

## Acceptance Criteria

- [ ] RFC3339 `+07:00` → UTC ลบ 7 ชั่วโมงถูกต้อง
- [ ] RFC3339 `Z` → UTC เหมือนเดิม
- [ ] No-timezone string + `Asia/Bangkok` location → convert เป็น UTC ถูกต้อง
- [ ] No-timezone string + nil → assume UTC, ไม่ error
- [ ] String ที่มี offset ไม่ถูก override โดย `assumeLocation`
- [ ] Format ที่ไม่รู้จัก → return error ที่อ่านออก

## Concepts Involved

- `datetime-timezone` — UTC, offset, IANA timezone, RFC3339 → `shared/concepts/datetime-timezone.md`

## Production Reality

- **ใช้จริง:** `time.Parse(time.RFC3339, s)` สำหรับ RFC3339 input — ถ้า input format ไม่มี timezone ต้อง `time.ParseInLocation` พร้อมระบุ location ที่รู้จาก source
- **ทำ manual เมื่อ:** input มาจากหลาย format (เช่น log จากหลาย vendor) ต้องเขียน multi-format parser เอง
- **kata สอนว่า:** `time.Parse` ที่ไม่มี timezone ใน format string → return UTC โดย default — "ไม่ error" ไม่ได้แปลว่า "ถูก"
