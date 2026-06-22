---
tier: file-handling/01-read-patterns
difficulty: 4
concepts: [inode, file-rotation, inotify, reopen, log-shipping]
---

# Kata: Rotated Log Read

## Context

Log rotation เกิดขึ้นทุกคืนบนทุก production server
`logrotate` เปลี่ยนชื่อ `app.log` เป็น `app.log.1` แล้วสร้าง `app.log` ใหม่
ถ้า log shipper ยังถือ file handle เดิมอยู่ มันจะอ่าน `app.log.1` ต่อไปเรื่อยๆ
ในขณะที่ `app.log` ใหม่กำลังสะสม log ที่ไม่มีใครอ่าน

## Real World Incidents

**Incident 1 — Log หายหลัง logrotate ทุกคืน (Elastic Filebeat)**
Filebeat อ่าน nginx access log ส่งไป Elasticsearch
หลัง logrotate เวลาตี 2 Filebeat ยังอ่านจาก inode เดิม (app.log.1)
app.log ใหม่สะสม log ที่ไม่ถูกส่ง จนกว่า Filebeat จะ restart ตอนเช้า
หายไปกว่า 6 ชั่วโมงของ access log ทุกวัน
แก้โดย detect inode change แล้ว reopen ไฟล์ใหม่

**Incident 2 — Audit log ขาดหายในช่วง rotation**
Security audit log ต้องครบทุก record ตาม compliance requirement
Log shipper ไม่ detect rotation → ส่ง log ไม่ครบ → fail compliance audit
แก้โดย drain ไฟล์เก่าจนหมดก่อน switch ไปอ่านไฟล์ใหม่

**Incident 3 — Disk เต็มเพราะ log shipper ไม่ปล่อย file handle**
logrotate ใช้ `copytruncate` mode (copy แล้ว truncate แทน rename) เพราะ app ไม่รองรับ SIGHUP
log shipper ยึด fd ของไฟล์ที่ถูก truncate → อ่านข้อมูล 0 bytes วนไป
log เก่าถูก copy แต่ space ไม่ถูกคืนเพราะ fd ยังเปิดอยู่ → disk เต็ม
แก้โดยตรวจ inode + size แล้ว reopen เมื่อ detect truncation

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
f, _ := os.Open("app.log")
for {
    scanner.Scan()
    process(scanner.Text())
}
```

**พังตอนไหน:**
- หลัง logrotate `f` ยังชี้ inode เดิม (ตอนนี้คือ `app.log.1`)
- `app.log` ใหม่ถูกสร้างแต่ไม่มีใคร watch
- ไม่รู้ว่า rotation เกิดขึ้นแล้ว จนกว่าจะ restart

**Root cause:**
File handle ผูกกับ inode ไม่ใช่ path
logrotate เปลี่ยน path ที่ชี้ไป inode แต่ fd เดิมยังชี้ inode เดิมอยู่

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `(*os.File).Stat()` — return type มี field อะไรที่ identify ไฟล์ได้โดยไม่ใช้ path?
- hint: `os.Stat()` (ใช้ path) vs `(*os.File).Stat()` (ใช้ fd) — ต่างกันยังไงตอน rotation?
- hint: `syscall.Stat_t` — field `Ino` คืออะไร? ใช้เปรียบ inode ได้ยังไง?
- inode คืออะไร? ทำไม rename ไม่เปลี่ยน inode แต่เปลี่ยน path ได้?
- `inotify(7)` บน Linux watch event อะไรได้บ้าง? `IN_MOVE_SELF`, `IN_CREATE` ต่างกันยังไง?

### Rust

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std::fs::metadata()` vs `file.metadata()` — ต่างกันยังไงตอน file rotation?
- hint: `std::os::unix::fs::MetadataExt` — มี method อะไรที่ได้ inode number?
- hint: `inotify` crate หรือ `notify` crate — ใช้ watch file system events บน Linux ยังไง?
- Rust `std::fs::File` ผูกกับ inode หรือ path? หลัง rename file handle ยังใช้ได้ไหม?
- `IN_MOVE_SELF` event ใน inotify คืออะไร? ต่างจาก `IN_DELETE` ยังไง?

### Zig

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std.os.fstat()` — return type คืออะไร? field `ino` คืออะไร?
- hint: `std.os.inotify_init1()` และ `std.os.inotify_add_watch()` — ใช้ยังไง?
- `std.os.linux.IN` constants — `IN_MOVE_SELF`, `IN_CREATE` ต่างกันยังไง?
- Zig ไม่มี high-level file watcher — ต้องเรียก Linux syscall โดยตรงยังไง?
- inode ใน Linux เก็บอยู่ใน `std.os.Stat` field ไหน?

## Task

เขียน `LogTailer` struct ที่:

1. `Start(ctx context.Context) (<-chan string, error)` — เริ่ม tail `path` แบบ follow (`tail -F`)
2. detect การ rotation โดย compare inode ของ path กับ fd ที่กำลังอ่าน
3. เมื่อ detect rotation: drain ไฟล์เก่าจนหมด → reopen path ใหม่ → อ่านต่อ

## Requirements

- ต้องไม่ miss บรรทัดใด ระหว่าง rotation (drain เก่าก่อน open ใหม่)
- ต้อง handle กรณีที่ path ยังไม่มี (รอจนกว่าจะถูกสร้าง)
- ต้อง handle `copytruncate` mode: ตรวจ file size ลดลงแล้ว reopen
- หยุดทำงานเมื่อ context cancel
- poll interval สำหรับ check rotation configurable (default 1 วินาที)

## Acceptance Criteria

- [ ] อ่าน log ต่อเนื่องก่อนและหลัง rotation โดยไม่ miss บรรทัด
- [ ] detect rename rotation (`logrotate` default) ได้
- [ ] detect truncate rotation (`copytruncate`) ได้
- [ ] ถ้าไฟล์ยังไม่มี รอจนกว่าจะสร้าง ไม่ error ทันที
- [ ] cancel context → หยุด tail และ close resource ทั้งหมด
- [ ] ไม่ leak goroutine หลัง cancel

## Concepts Involved

- `inode` — inode คืออะไร, path กับ inode ต่างกัน → `shared/concepts/inode.md`
- `inotify` — Linux file system event notification → `shared/concepts/inotify.md`
- `fd-lifecycle` — fd ผูกกับ inode ไม่ใช่ path → `shared/concepts/fd-lifecycle.md`
- `log-rotation` — logrotate modes, SIGHUP, copytruncate → `shared/concepts/log-rotation.md`
