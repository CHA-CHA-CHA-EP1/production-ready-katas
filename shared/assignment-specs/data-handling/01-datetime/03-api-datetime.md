---
tier: data-handling/01-datetime
difficulty: 3
concepts: [rfc3339, api-serialization, json-time, display-timezone]
---

# Kata: API DateTime Serialization

## Context

API ที่ return timestamp ต้องตอบคำถาม 3 ข้อให้ได้: เก็บ timezone อะไร, ส่งออก format อะไร, client แปลงยังไง
ถ้า API ส่ง timestamp ที่ไม่มี timezone info — client แต่ละตัวจะตีความเองและได้ผลต่างกัน

## Real World Incidents

**Incident 1 — Mobile app แสดงเวลานัดหมายผิดในต่างประเทศ**
API ส่ง `"appointment_time": "2024-01-15 14:00:00"` ไม่มี timezone
iOS interpret เป็น device local time, Android interpret เป็น UTC
user ใน Singapore เห็น `14:00` แต่จริงๆ นัดไว้ `14:00 Bangkok` = `21:00 Singapore`
แก้โดยเปลี่ยน API เป็น RFC3339 `"2024-01-15T14:00:00+07:00"`

**Incident 2 — JSON unmarshal เงียบๆ เปลี่ยน timezone**
Go struct มี field `CreatedAt time.Time`
JSON: `"created_at": "2024-01-15T10:00:00+07:00"`
`json.Unmarshal` parse ถูกต้อง แต่ developer ทำ `db.Save(event)` โดยไม่ `.UTC()`
database ได้ `10:00:00+07:00` แต่ column เป็น `TIMESTAMP` → เก็บ `10:00:00` ตัดทิ้ง offset
แก้โดยเพิ่ม custom `UnmarshalJSON` ที่ force UTC ก่อนเสมอ

**Incident 3 — Sorting timestamp ผิดใน API response**
API คืน list of events sorted by `created_at`
events มาจากหลาย source บางตัว UTC บางตัว Bangkok
sort ด้วย string comparison `"2024-01-15T10:00:00+07:00"` vs `"2024-01-15T04:00:00Z"`
string sort บอกว่า 10:00 มาก่อน 04:00 แต่จริงๆ เหมือนกัน
แก้โดย parse เป็น `time.Time` แล้ว sort ด้วย `.Before()`

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
type Event struct {
    CreatedAt string `json:"created_at"`  // เก็บเป็น string
}
// หรือ
type Event struct {
    CreatedAt time.Time `json:"created_at"`  // ไม่ได้ control format
}
```

**พังตอนไหน:**
- string → client ตีความ timezone เอง → inconsistent
- `time.Time` default JSON format คือ RFC3339Nano ซึ่งมี timezone แต่ใช้ location ที่ struct มีอยู่
- ถ้า struct มี Bangkok time → JSON มี `+07:00` ถ้ามี UTC → JSON มี `Z`
- API response ไม่ consistent ขึ้นอยู่กับ timezone ของ server

**Root cause:**
ไม่มี explicit contract ว่า API ส่ง timezone อะไร
ต้องกำหนด: รับ UTC เก็บ UTC ส่งออก RFC3339+UTC เสมอ

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `(time.Time).MarshalJSON()` — default format คืออะไร? timezone มาจากไหน?
- hint: `(time.Time).Format()` — Go reference time คืออะไร? ทำไมใช้ `2006-01-02` ไม่ใช่ `YYYY-MM-DD`?
- hint: `time.RFC3339` กับ `time.RFC3339Nano` — format string คืออะไร?
- `json:",omitempty"` กับ `time.Time` zero value — ทำงานยังไง? zero value ของ `time.Time` คืออะไร?
- ถ้าต้องการ custom JSON format สำหรับ `time.Time` ต้องทำอะไร?

### Rust

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `chrono::DateTime<Utc>` กับ `serde::Serialize` — default serialize format คืออะไร?
- hint: `chrono::serde::ts_seconds` vs `chrono::serde::ts_milliseconds` — ต่างกันยังไง? เมื่อไหรใช้อันไหน?
- hint: `#[serde(with = "chrono::serde::ts_seconds")]` — ใช้ custom serialize format ยังไง?
- `DateTime<Utc>` serialize เป็น RFC3339 โดย default ไหม? ถ้าไม่ ต้องทำอะไร?
- zero value ของ `DateTime<Utc>` คืออะไร? serialize เป็น `null` ได้ไหม?

### Zig

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- Zig ไม่มี built-in JSON datetime serialization — จะ implement `MarshalJSON` equivalent ยังไง?
- hint: `std.json.stringify()` — รับ custom type ยังไง? จะ control output format ได้ไหม?
- hint: `std.json.Value` — ใช้ represent JSON ก่อน stringify ยังไง?
- RFC3339 format string สำหรับ UTC คืออะไร? จะ format ด้วย `std.fmt.bufPrint` ยังไง?
- Zig `comptime` — ใช้ generate serialization code สำหรับ datetime ได้ไหม?

## Task

เขียน `UTCTime` type ที่ wrap `time.Time` โดย:

1. `MarshalJSON()` — serialize เป็น RFC3339 UTC เสมอ (`Z` suffix)
2. `UnmarshalJSON()` — parse RFC3339 ทุก timezone แล้วแปลงเป็น UTC
3. `MarshalText()` / `UnmarshalText()` — สำหรับ non-JSON serialization

จากนั้นเขียน `FormatForDisplay(t time.Time, loc *time.Location) string` ที่:
1. แปลงจาก UTC เป็น timezone ที่กำหนด
2. Return format: `2 Jan 2006, 15:04 (MST)`

## Requirements

- `MarshalJSON` ต้องส่ง UTC เสมอ (suffix `Z`) ไม่ว่า Time นั้นจะมี location อะไร
- `UnmarshalJSON` ต้องรับ timezone ใดก็ได้แล้วแปลงเป็น UTC
- Zero value ของ `UTCTime` ต้อง marshal เป็น `null` ไม่ใช่ zero timestamp
- `FormatForDisplay` ต้องไม่แก้ไข original time.Time (immutable)

## Acceptance Criteria

- [ ] `UTCTime` ที่มี Bangkok time → JSON มี `Z` suffix ไม่ใช่ `+07:00`
- [ ] JSON `+07:00` → Unmarshal แล้ว location เป็น UTC
- [ ] JSON `Z` → Unmarshal แล้ว location เป็น UTC
- [ ] Zero `UTCTime` → Marshal เป็น `null`
- [ ] `FormatForDisplay` กับ `Asia/Bangkok` → แสดง `+07` หรือ `WIB` ใน output
- [ ] Sort slice ของ `UTCTime` ด้วย `.Before()` → เรียงลำดับถูกต้อง

## Concepts Involved

- `datetime-timezone` — UTC, RFC3339, display vs storage → `shared/concepts/datetime-timezone.md`
