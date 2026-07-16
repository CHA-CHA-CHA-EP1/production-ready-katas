---
tier: resilience-and-consistency/01-write-patterns
difficulty: 1
concepts: [atomic-write, fd-lifecycle, fsync, rename-syscall, crash-consistency]
---

# Kata: Atomic Write

## Context

ทุก service มีจุดที่ต้อง "เขียนไฟล์" — เช่น บันทึก config หลัง apply, เขียน state ก่อน restart, หรืออัปเดต lock file
ดูเหมือนง่าย แต่ถ้าเขียนตรงไปยัง path ปลายทางเลย — process crash ระหว่างเขียนทิ้งไว้ไฟล์ที่อ่านไม่ได้
ปัญหานี้ไม่โชว์ใน dev เพราะ dev machine ไม่ค่อย crash — โชว์ตอน production pod ถูก kill กลางคัน

## Real World Incidents

**Incident 1 — Config corruption หลัง OOM kill (HashiCorp Consul)**
Consul เขียน config snapshot ไปยัง path ตรงๆ ทุกครั้งที่ state เปลี่ยน
ช่วง memory spike, OS OOM Killer kill process กลางการเขียน
ผล: config file ถูก truncate ครึ่งคัน — Consul restart ครั้งต่อไปอ่านไฟล์ไม่ได้ ปฏิเสธที่จะ boot
แก้โดยเปลี่ยนมาใช้ write-to-temp + rename แทน

**Incident 2 — Package.json เสียหายหลัง npm crash (npm)**
npm เขียน `package.json` โดย open ไฟล์เดิมแล้ว overwrite ตรงๆ
ถ้า `npm install` ถูก Ctrl-C กลางคัน ไฟล์จะอยู่ในสถานะกึ่งเขียน
project ที่ได้รับผลกระทบ parse `package.json` ไม่ได้ → build พัง
npm แก้ใน v5 โดยเขียนไปยัง temp file ก่อน แล้วค่อย rename

**Incident 3 — Database checkpoint ทำให้ข้อมูลหาย (SQLite user report)**
Application เปิด SQLite database แล้วเขียนข้อมูลโดยไม่มี WAL mode
ไฟฟ้าดับระหว่าง write syscall ที่ยังไม่ fsync
page ที่เขียนลง disk ไม่ครบ — B-tree structure เสีย — database corrupt ทั้งไฟล์
SQLite แก้ด้วย WAL (Write-Ahead Log) ซึ่งใช้หลักการเดียวกับ write-then-rename

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```
open(path, O_WRONLY|O_TRUNC) → write() → close()
```
หรือใน Go: `os.WriteFile(path, data, 0644)`

**พังตอนไหน:**
- Process ถูก kill ระหว่าง write → file อยู่ในสถานะ partial — อ่านได้แต่ข้อมูลไม่ครบ
- Disk เต็มระหว่างเขียน → file ถูก truncate ครึ่งคัน แต่ original ก็หายไปแล้ว
- Power failure ก่อน kernel flush page cache → bytes ที่คิดว่าเขียนแล้วหายไป

**Root cause:**
`open + write + close` ไม่ใช่ atomic operation — มีหลาย syscall ที่แต่ละอันอาจ fail
ตอนที่ open ด้วย `O_TRUNC`, original content ถูกล้างทันที — ยังไม่ทันเขียน content ใหม่ด้วยซ้ำ

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `os.CreateTemp(dir, pattern string)` — return type คืออะไร? `dir` ควรใส่ค่าอะไรถ้าต้องการให้ temp file อยู่ใน filesystem เดียวกับ target?
- hint: `(*os.File).Sync()` — ทำอะไร? ต่างจาก `Close()` ยังไง? ทำไมต้องเรียกก่อน rename?
- hint: `os.Rename(oldpath, newpath string)` — POSIX guarantee ของ rename คืออะไร? ทำไมถึง atomic? มีข้อจำกัดอะไรบ้าง?
- ถ้า `os.CreateTemp` และ `os.Rename` อยู่คนละ filesystem จะเกิดอะไรขึ้น? จะรู้ได้ยังไง?
- error ที่ควร cleanup: ถ้า rename fail, temp file จะอยู่ที่ไหน? ใครรับผิดชอบลบ?

### Rust

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `tempfile::NamedTempFile` (crate) หรือ `std::fs::File::create` ใน `/tmp` — ต่างกันยังไงในแง่ cleanup?
- hint: `file.sync_all()` vs `file.sync_data()` — ต่างกันยังไง? อันไหนพอสำหรับ crash safety?
- hint: `std::fs::rename(from, to)` — POSIX guarantee ของ rename บน Linux คืออะไร?
- Rust's `Drop` trait จัดการ temp file cleanup ยังไงถ้าใช้ `tempfile` crate?
- cross-filesystem rename fail ด้วย error อะไร? จะ fallback ยังไง?

### Zig

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std.fs.Dir.createFile()` กับ `std.fs.Dir.rename()` — ใช้ร่วมกันยังไง?
- hint: `file.sync()` ใน Zig — map ไปยัง syscall อะไร?
- Zig ไม่มี defer-based RAII เหมือน Rust — จะ cleanup temp file ใน error path ยังไง?
- `Dir.rename()` ต้องการ `Dir` handle — ทำไมถึง safer กว่า path string?

## Task

implement `writeFileAtomic(path, data, perm)` ที่:

1. รับ target path, content ที่จะเขียน, และ file permission
2. เขียน content ไปยัง temp file ในโฟลเดอร์เดียวกับ target
3. fsync temp file เพื่อให้ data ลง disk ก่อน rename
4. rename temp → target แบบ atomic
5. cleanup temp file ถ้าเกิด error ระหว่างทาง

## Requirements

- ต้องเขียนไปยัง temp file ก่อน — ห้ามเปิด target file โดยตรง
- temp file ต้องอยู่ใน directory เดียวกับ target — ป้องกัน cross-filesystem rename error
- ต้อง fsync ก่อน rename — ไม่ใช่แค่ close
- ต้อง cleanup temp file ทุก error path — ห้ามทิ้ง temp file ค้างไว้บน disk
- ต้องปิด file descriptor ทุกกรณี (ทั้ง success และ error path)
- Error message ต้องบอก context ได้ เช่น `"WriteFileAtomic: sync: no space left on device"` ไม่ใช่แค่ `"write failed"`

## Acceptance Criteria

- [ ] เขียนไฟล์ใหม่ได้ถูกต้อง — content ตรงกับที่ส่งเข้ามา byte-for-byte
- [ ] overwrite ไฟล์เดิมได้ — reader ที่อ่านไฟล์เดิมอยู่ไม่ได้รับผลกระทบ (old fd ยังใช้ได้)
- [ ] ถ้า write fail กลางคัน — target file ยังคงเป็น content เดิม ไม่ corrupt
- [ ] ถ้า disk เต็ม — target ไม่โดน truncate, temp file ถูกลบทิ้ง
- [ ] ไม่มี temp file หลงเหลือบน disk หลังเรียกฟังก์ชัน ไม่ว่าจะ success หรือ error
- [ ] ฟังก์ชันทนต่อการเรียกพร้อมกันกับ target path เดียวกัน (last writer wins — ไม่ corrupt)

## Concepts Involved

- `fd-lifecycle` — file descriptor คืออะไร, เปิด/ปิดอย่างไร, leak มีผลอะไร → `shared/concepts/fd-lifecycle.md`
- `error-wrapping` — การ wrap error ให้ context ไม่หาย → `shared/concepts/error-wrapping.md`
- `fsync` — ทำไม close ไม่พอ, kernel page cache, durability guarantee → (concept doc ยังไม่มี)
- `rename-atomicity` — POSIX rename guarantee, cross-filesystem limitation → (concept doc ยังไม่มี)

## Production Reality

- **ใช้จริง:** หลาย library ทำ pattern นี้ให้แล้ว เช่น `github.com/natefinish/go-atomicwrite` หรือ `renameio` package
- **ทำ manual เมื่อ:** ต้องการ control เรื่อง permission, ownership, หรือ error context เฉพาะทาง
- **fsync tradeoff:** fsync ก่อน rename ให้ crash safety สูงสุด แต่ช้ากว่า — บาง use case (เช่น ephemeral cache) ยอมรับ risk ของ unsynced rename ได้
- **kata สอนว่า:** `os.WriteFile` สะดวกแต่ไม่ crash-safe — รู้ tradeoff แล้วเลือกใช้ได้อย่างมั่นใจ ไม่ใช่ magic
