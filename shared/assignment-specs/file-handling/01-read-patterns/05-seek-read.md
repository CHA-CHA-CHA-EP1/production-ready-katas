---
tier: file-handling/01-read-patterns
difficulty: 3
concepts: [seek, random-access, io-seeker, io-reader-at, file-as-array]
---

# Kata: Seek / Random Access Read

## Context

ไฟล์ไม่ใช่แค่ stream ที่อ่านจากต้นจนจบ — มันคือ byte array ที่ addressable
Database page file, index file, binary log, custom binary format ล้วนต้องการกระโดดไปอ่าน offset ที่ต้องการโดยไม่ต้องผ่านข้อมูลทั้งหมดก่อน

## Real World Incidents

**Incident 1 — Event replay ช้าผิดปกติใน audit system**
Audit system เก็บ event ใน append-only log file พร้อม index file ที่เก็บ offset ของแต่ละ event
ตอน replay developer อ่านทั้ง log file ตั้งแต่ต้นแล้วนับ event จนถึง ID ที่ต้องการ
log file โตขึ้นทุกวัน → replay เริ่ม event ที่ 1 ล้านใช้เวลาหลายนาที ทั้งที่ควรใช้เวลา milliseconds
แก้โดยใช้ index + `ReadAt` กระโดดไปยัง offset ตรงๆ

**Incident 2 — SQLite-style pager อ่าน page ผิด**
Custom storage engine เก็บข้อมูลเป็น fixed-size pages (4096 bytes)
อ่าน page ด้วย `f.Seek(pageID * 4096, io.SeekStart)` แล้ว `f.Read(buf)`
ในระบบที่มี concurrent reader Seek + Read ไม่ atomic → reader อื่น Seek แทรก → อ่าน page ผิด
แก้โดยเปลี่ยนมาใช้ `f.ReadAt(buf, offset)` ซึ่ง atomic

**Incident 3 — Media server ส่งไฟล์ช้าเพราะไม่ใช้ range read**
Video streaming server รับ HTTP Range request แต่ implement ด้วยการอ่านทั้งไฟล์แล้ว slice
ไฟล์ 2 GB user ขอ byte range 1.5 GB-1.5 GB+1MB → server โหลด 2 GB ก่อน
แก้โดยใช้ `ReadAt` ไปยัง offset ที่ต้องการโดยตรง

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```
// อยากได้ข้อมูลที่ offset 1000000
data, _ := os.ReadFile(path)
chunk := data[1000000 : 1000000+size]
```

**พังตอนไหน:**
- ต้องโหลดทั้งไฟล์ก่อนเสมอ → O(file size) memory
- ถ้าต้องการหลาย offset → อ่านซ้ำหลายรอบหรือเก็บทั้งไฟล์ไว้ใน memory

**Root cause:**
ไม่รู้ว่า `os.File` เป็น seekable — สามารถกระโดดไปอ่าน offset ไหนก็ได้
`ReadAt` ยิ่งดีกว่าเพราะ atomic และ concurrent-safe

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `(*os.File).ReadAt()` — signature คืออะไร? ต่างจาก `Seek + Read` ยังไง?
- hint: `io.ReaderAt` interface — มี method อะไร? `os.File` implement ไหม?
- hint: `(*os.File).Seek()` — หลัง `Seek` แล้ว concurrent goroutine เรียก `Seek` อีกจะเกิดอะไร?
- `ReadAt` เรียกพร้อมกันหลาย goroutine ปลอดภัยไหม? ทำไม?
- ถ้า offset + length เกินขนาดไฟล์ `ReadAt` จะ return อะไร?

### Rust

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std::os::unix::fs::FileExt::read_at()` — ต่างจาก `seek + read` ยังไง? thread-safe ไหม?
- hint: `std::io::SeekFrom` — มี variant อะไรบ้าง? แต่ละอันใช้เมื่อไหร่?
- `pread(2)` syscall กับ `read_at()` ใน Rust สัมพันธ์กันยังไง?
- Windows ไม่มี `read_at` เหมือน Unix — Rust handle cross-platform ยังไง?
- `Seek + Read` ไม่ atomic บน multi-thread — `read_at` แก้ปัญหานี้ยังไง?

### Zig

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `file.pread()` — signature คืออะไร? ต่างจาก `seek + read` ยังไง?
- hint: `file.preadAll()` — ต่างจาก `pread()` ยังไง?
- `pread` บน Linux คือ syscall `pread64(2)` — Zig map ยังไง?
- Zig standard library มี `File.Reader` และ `File.SeekableStream` — interface นี้คืออะไร?
- ถ้า offset + size เกินขนาดไฟล์ `pread` จะ return อะไร?

## Task

implement `readAt(path, offset, size)` ที่:

1. อ่านข้อมูล `size` bytes จาก `offset` ที่กำหนด
2. ไม่โหลดข้อมูลส่วนอื่นของไฟล์

จากนั้นเขียน `readPages(path, pageSize, pageIDs)` ที่:

1. อ่าน page ตาม pageID แต่ละอัน (page = fixed-size block ใน file)
2. รองรับการเรียกพร้อมกัน — สามารถ refactor ให้ใช้ goroutine ได้

## Requirements

- `ReadAt` ต้องไม่ affect read position ของ caller อื่นที่ใช้ไฟล์เดียวกัน
- `ReadPages` ต้องทำงานถูกต้องแม้ pageID ไม่เรียงลำดับ
- ต้อง return error ถ้า offset อยู่นอกขอบเขตไฟล์
- ต้อง handle กรณี page สุดท้ายที่อาจเล็กกว่า pageSize

## Acceptance Criteria

- [ ] `ReadAt` คืนข้อมูลที่ offset และ size ถูกต้อง
- [ ] `ReadAt` return error ถ้า offset >= file size
- [ ] `ReadPages` คืน data ถูกต้องสำหรับทุก pageID
- [ ] เรียก `ReadAt` พร้อมกัน 10 goroutine บนไฟล์เดียวกัน ผลลัพธ์ถูกต้องทุก goroutine
- [ ] ไม่ read ข้อมูลส่วนอื่นนอกจาก offset ที่กำหนด

## Concepts Involved

- `seek-lseek` — `lseek(2)`, `pread(2)` syscall, ทำไม `ReadAt` = `pread` → `shared/concepts/seek-lseek.md`
- `concurrency-file` — ทำไม Seek+Read ไม่ atomic แต่ ReadAt atomic → `shared/concepts/concurrency-file.md`
- `fd-lifecycle` — file offset state ต่อ fd → `shared/concepts/fd-lifecycle.md`

## Production Reality

- **ใช้จริง:** `(*os.File).ReadAt(b, off)` — atomic, thread-safe, ไม่กระทบ file offset ของ caller อื่น (map ไป `pread(2)` syscall โดยตรง)
- **ทำ manual เมื่อ:** ไม่ต้องทำ — `ReadAt` คือ production way จริงๆ ห้ามใช้ `Seek()` + `Read()` ใน concurrent code
- **kata สอนว่า:** `Seek` + `Read` ไม่ atomic — race condition เกิดได้ใน concurrent read ต้อง `ReadAt` เท่านั้น
