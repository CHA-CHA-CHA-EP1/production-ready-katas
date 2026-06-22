---
tier: file-handling/01-read-patterns
difficulty: 3
concepts: [seek, io-seeker, lseek, backward-traversal]
---

# Kata: Tail Read

## Context

On-call engineer ต้องการดู 100 บรรทัดล่าสุดของ log ขนาด 50 GB
หรือ health check endpoint ที่ดึง last N errors จาก log file
การโหลดทั้งไฟล์เพื่อเอาแค่ท้ายนั้นไม่ใช่ option — ต้องอ่านจากท้ายไฟล์ได้โดยตรง

## Real World Incidents

**Incident 1 — On-call tool ทำให้ server OOM ระหว่าง incident**
ทีม ops มี script ที่อ่าน last 200 lines จาก application log เพื่อดู error context
script ใช้ `ioutil.ReadAll` แล้ว split แล้วเอา 200 อันสุดท้าย
ตอน incident log file โตเป็น 80 GB → script โหลดทั้งก้อน → server ที่กำลัง incident OOM ซ้ำ
แก้โดยใช้ backward seek อ่านเฉพาะท้ายไฟล์

**Incident 2 — Log viewer ใน web UI ช้ามากบน production**
Web UI มี feature "show recent logs" ที่อ่านจาก file backend
dev environment ไฟล์ขนาด 1 MB เร็วมาก แต่ production ไฟล์ขนาด 20 GB
response time 30+ วินาที ทั้งที่ผู้ใช้ต้องการแค่ 50 บรรทัดสุดท้าย
แก้โดย implement `tail` algorithm ด้วย seek from end

**Incident 3 — Audit log reader ใช้ memory เกิน quota บน Lambda**
AWS Lambda function อ่าน audit log จาก EFS เพื่อ export last 1000 entries
Lambda memory limit 512 MB แต่ log file ใหญ่กว่า → function crash ทุกครั้ง
แก้โดย seek from end อ่านแบบ backward จนครบ 1000 บรรทัด

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```
data, _ := os.ReadFile(path)
lines := strings.Split(string(data), "\n")
return lines[max(0, len(lines)-n):]
```

**พังตอนไหน:**
- ไฟล์ 50 GB → allocate 50 GB ใน heap → OOM
- ไม่สามารถใช้กับไฟล์ที่ใหญ่กว่า available RAM ได้เลย

**Root cause:**
`tail` ที่ถูกต้องต้อง seek ไปท้ายไฟล์ก่อน แล้ว scan backward หา newline
อ่านข้อมูลเฉพาะส่วนที่ต้องการ — O(result size) ไม่ใช่ O(file size)

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `(*os.File).Seek()` — signature คืออะไร? parameter `whence` มีค่าอะไรได้บ้าง?
- hint: `io.SeekStart`, `io.SeekCurrent`, `io.SeekEnd` — แต่ละค่าหมายความว่าอะไร?
- hint: `(*os.File).Stat()` — ใช้หา file size ได้ยังไง? ก่อน seek ต้องรู้อะไร?
- ถ้า file size 1000 bytes และ seek ไป offset -100 จาก end จะอยู่ที่ byte ไหน?
- การ scan backward หา `\n` — ต้องอ่าน buffer ขนาดเท่าไหร่ต่อครั้ง? trade-off คืออะไร?

### Rust

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std::io::Seek::seek()` — รับ argument `SeekFrom` enum มีค่าอะไรบ้าง?
- hint: `SeekFrom::End()` — รับ argument `i64` ทำไม? negative value หมายความว่าอะไร?
- hint: `file.metadata().len()` — ใช้รู้ file size ก่อน seek ได้ยังไง?
- Rust มี `rev()` บน iterator — จะใช้กับ byte buffer backward traversal ยังไง?
- `BufReader` หลัง `seek()` — internal buffer ยัง valid ไหม? ต้องทำอะไรก่อน seek?

### Zig

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `file.seekFromEnd()` — รับ argument อะไร? negative value หมายความว่าอะไร?
- hint: `file.seekTo()` vs `file.seekBy()` vs `file.seekFromEnd()` — แต่ละอันต่างกันยังไง?
- hint: `file.getEndPos()` — ใช้ทำอะไร? ต่างจาก `stat().size` ยังไง?
- backward scan หา `\n` ใน Zig — ต้องอ่าน buffer ยังไง? `std.mem.lastIndexOfScalar` ช่วยได้ไหม?
- Zig allocator pattern: backward scan ที่ต้อง collect lines — ใช้ `ArrayList` ยังไง?

## Task

เขียนฟังก์ชัน `TailLines(path string, n int) ([]string, error)` ที่:

1. คืน n บรรทัดสุดท้ายของไฟล์
2. ใช้ seek อ่านจากท้ายไฟล์ — ไม่อ่านทั้งไฟล์
3. memory usage เป็น O(result) ไม่ใช่ O(file size)

## Requirements

- ห้ามโหลดไฟล์ทั้งหมดเข้า memory
- ต้อง handle กรณีที่ไฟล์มีบรรทัดน้อยกว่า n (คืนทุกบรรทัดที่มี)
- ต้อง handle ไฟล์ที่บรรทัดสุดท้ายไม่มี `\n`
- ต้อง handle ไฟล์เปล่า
- บรรทัดต้องเรียงลำดับถูกต้อง (บรรทัดแรกของ result = บรรทัดที่เก่ากว่า)

## Acceptance Criteria

- [ ] คืน n บรรทัดสุดท้ายถูกต้องสำหรับไฟล์ปกติ
- [ ] ถ้าไฟล์มีน้อยกว่า n บรรทัด คืนทั้งหมดที่มี ไม่ error
- [ ] ไฟล์เปล่า คืน empty slice ไม่ error
- [ ] บรรทัดสุดท้ายที่ไม่มี `\n` ถูก include
- [ ] ทำงานกับไฟล์ขนาด 1 GB โดยไม่โหลดทั้งหมดเข้า memory
- [ ] บรรทัดผลลัพธ์เรียงลำดับ oldest → newest

## Concepts Involved

- `seek-lseek` — `lseek(2)` syscall, offset, whence → `shared/concepts/seek-lseek.md`
- `io-seeker` — `io.Seeker` interface ใน Go → `shared/concepts/io-reader.md`
- `fd-lifecycle` — file descriptor state หลัง seek → `shared/concepts/fd-lifecycle.md`
