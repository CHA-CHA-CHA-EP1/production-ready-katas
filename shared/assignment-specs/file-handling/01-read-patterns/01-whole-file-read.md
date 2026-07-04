---
tier: file-handling/01-read-patterns
difficulty: 1
concepts: [whole-file-read, memory-allocation, error-handling, resource-management]
---

# Kata: Whole-File Read

## Context

ทุก service มีจุดหนึ่งที่ต้อง "อ่านไฟล์ทั้งไฟล์" — เช่น อ่าน config ตอน startup, โหลด template ก่อน render, หรืออ่าน certificate/key จาก disk
ดูเหมือนโจทย์ง่าย แต่โค้ดที่เขียนตามสัญชาตญาณมักมีรูรั่วที่ไม่โชว์ตอน dev — โชว์ตอน production เท่านั้น

## Real World Incidents

**Incident 1 — Kubernetes pod OOM loop (GitHub, 2018)**
Service อ่าน config จาก mounted ConfigMap ซึ่งปกติมีขนาดแค่ไม่กี่ KB
วันหนึ่ง ops เผลอ mount Secret ขนาดใหญ่ทับ path เดิมโดยไม่ตั้งใจ
Service โหลดทั้งก้อนเข้า heap ทุกครั้งที่ reload → RSS พุ่ง → OOM Killer kill → pod restart loop
ไม่มี error log เพราะ process ถูก kill ก่อนจะ log อะไร (`exit code 137`)
แก้โดยเพิ่ม size check ก่อนโหลด + alert ถ้าขนาดไฟล์ผิดปกติ

**Incident 2 — fd leak ทำให้ HTTP server หยุดรับ connection (Cloudflare blog)**
Go service อ่าน TLS certificate จากไฟล์ทุกครั้งที่มี TLS handshake
โค้ดเดิม open file แต่ handle error ไม่ครบ — บาง code path return ก่อนที่ `Close()` จะถูกเรียก
ในสภาวะ traffic ต่ำ ไม่มีปัญหา แต่ตอน traffic spike fd เพิ่มเร็วจนถึง limit (1024)
ผล: `accept: too many open files` — server รับ connection ใหม่ไม่ได้เลย
แก้โดยเพิ่ม `defer f.Close()` ทุก code path + ตั้ง `ulimit -n 65536` บน production

**Incident 3 — symlink attack ใน container build system**
CI system อ่านไฟล์ config จาก path ที่ผู้ใช้ส่งมา
ผู้ใช้สร้าง symlink ชี้ไป `/proc/1/environ` (environment variables ของ init process)
service โหลดทั้งหมดเข้า memory แล้วส่งกลับใน error message
แก้โดย validate ว่า path ไม่ใช่ symlink + จำกัดขนาดไฟล์ + ไม่ส่ง content กลับใน error

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
เปิดไฟล์ → อ่านทีเดียวทั้งหมด → ใช้ข้อมูล
ถ้าภาษานั้นมี one-liner (`os.ReadFile`, `ioutil.ReadFile`, `File.read()`) ก็มักใช้โดยไม่คิดต่อ

**พังตอนไหน:**
- ไฟล์หายไป / path ผิด → panic หรือ silent empty string ถ้าไม่ handle error
- file descriptor ไม่ถูกปิด (ในบางภาษา / บาง pattern) → fd leak สะสมจนถึง limit (`too many open files`)
- ไฟล์ใหญ่กว่าที่คาด (เช่น log file ถูก symlink มาแทน config) → โหลดทั้งก้อนเข้า RAM → OOM

**Root cause:**
Whole-file read โหลด content ทั้งหมดเข้า memory ในครั้งเดียว ซึ่ง OK ก็ต่อเมื่อรู้ว่าไฟล์มีขนาดจำกัดแน่นอน
ปัญหาคือคนมักไม่ validate ขนาดก่อน และไม่ handle error path ครบ

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `os.Open()` — return type คืออะไร? ต่างจาก `os.OpenFile()` ยังไง?
- hint: `(*os.File).Stat()` — return type คืออะไร? จะรู้ขนาดไฟล์ก่อนอ่านได้ยังไง?
- hint: `(*os.File).Read()` — signature เป็นยังไง? `n int` ที่ return มาหมายความว่าอะไร? ทำไมต้องเช็ค?
- `os.File` implement interface อะไรจาก package `io` บ้าง? แต่ละ interface มี contract ว่าอะไร?
- error ที่ `os.Open` return อาจเป็น type อะไร? จะแยกแยะ "ไฟล์ไม่มี" กับ "ไม่มีสิทธิ์" ได้ยังไง?
- ถ้าวาง `defer reader.Close()` ก่อน error check จะเกิดอะไรขึ้น? ทำไม `os.Open` fail แล้ว `reader` ถึง panic ตอน Close?
- ถ้าใช้ `Stat()` เช็คขนาดก่อน แล้วค่อย `ReadAll()` — มีช่วงเวลาไหนที่ไฟล์อาจโตขึ้นได้ระหว่างสองขั้นนั้นไหม? จะป้องกันได้ยังไง?

### Rust

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std::fs::File::open()` — return type คืออะไร? ต่างจาก `std::fs::read()` ยังไง?
- hint: `file.metadata()` — return type คืออะไร? จะรู้ขนาดไฟล์ก่อนอ่านได้ยังไง?
- hint: `std::io::Read` trait — `read()` method มี signature ยังไง? `n` ที่ return หมายความว่าอะไร?
- `File` implement trait อะไรจาก `std::io` บ้าง? แต่ละ trait มี contract ว่าอะไร?
- Rust จัดการ fd lifecycle ยังไงโดยไม่มี `defer`? `Drop` trait เกี่ยวข้องยังไง?

### Zig

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std.fs.cwd().openFile()` — return type คืออะไร? flags ที่ต้องส่งมีอะไรบ้าง?
- hint: `file.stat()` — return type คืออะไร? จะรู้ขนาดไฟล์ได้ยังไง?
- hint: `file.read()` — signature เป็นยังไง? return value หมายความว่าอะไร?
- Zig ใช้ `defer file.close()` คล้าย Go — แต่ถ้า `openFile` fail แล้ว defer จะรันไหม? ทำไม?
- error handling ใน Zig ใช้ `!` และ `try` — `try file.stat()` ทำงานยังไงถ้า stat fail?

## Task

เขียนฟังก์ชัน `ReadConfig(path string) ([]byte, error)` ที่:

1. รับ path ของไฟล์ config (plaintext, ขนาดไม่เกิน 1 MB)
2. คืน content ทั้งหมดเป็น `[]byte`
3. คืน error ที่อธิบายได้ว่าเกิดอะไรขึ้น ถ้าไฟล์อ่านไม่ได้

## Requirements

- ต้องปิด file descriptor ทุกกรณี (ทั้ง success และ error path)
- ต้องปฏิเสธไฟล์ที่ใหญ่กว่า 1 MB โดย return error ที่อ่านออก (ไม่ใช่ panic)
- ห้ามใช้ `os.ReadFile` หรือ `ioutil.ReadFile` โดยตรง — ต้องเปิด/อ่าน/ปิดเอง เพื่อให้เห็น lifecycle ของ fd
- Error message ต้องบอก context ได้ เช่น "`ReadConfig: open /etc/app/config.json: no such file or directory`" ไม่ใช่แค่ `"file not found"`

## Acceptance Criteria

- [ ] อ่านไฟล์ปกติได้ถูกต้อง — content ตรงกับที่อยู่ในไฟล์ byte-for-byte
- [ ] คืน error ถ้าไฟล์ไม่มีอยู่ (`os.IsNotExist` เป็น true)
- [ ] คืน error ถ้าไฟล์ขนาดเกิน 1 MB — ยอมรับทั้ง Stat-before-read และ LimitReader approach แต่ต้องอธิบายได้ว่าแต่ละแบบมี tradeoff อะไร และทำไมถึงควรมีทั้งสองชั้น (defense-in-depth)
- [ ] คืน error ถ้าไม่มีสิทธิ์อ่าน (`permission denied`)
- [ ] ไม่มี fd leak — หลังเรียกฟังก์ชัน ไม่ว่าจะ success หรือ error fd ต้องถูกปิดแล้ว (`defer` ต้องวางหลัง error check ของ `os.Open` เสมอ)
- [ ] ฟังก์ชันทนต่อการเรียกพร้อมกัน 100 ครั้ง (concurrent-safe) — ไม่มี shared mutable state
- [ ] มี test ครอบคลุม: happy path, file not found, file too large, permission denied

## Concepts Involved

- `fd-lifecycle` — file descriptor คืออะไร, เปิด/ปิดอย่างไร, leak มีผลอะไร → `shared/concepts/fd-lifecycle.md`
- `error-wrapping` — การ wrap error ให้ context ไม่หาย → `shared/concepts/error-wrapping.md`
- `memory-allocation` — whole-file read กับ memory tradeoff → `shared/concepts/memory-allocation.md`

## Production Reality

- **ใช้จริง:** `os.ReadFile(path)` — จัดการ fd lifecycle, partial read, error path ครบอยู่แล้ว คืน `[]byte` พร้อมใช้
- **ทำ manual เมื่อ:** ต้องการ size check ก่อนโหลด (ป้องกัน OOM), หรือต้องการ error context เฉพาะทาง เช่น บอกว่า path มาจากไหน
- **kata สอนว่า:** `os.ReadFile` ปลอดภัยเพราะ *ทำทุกอย่างที่คุณเพิ่งเขียน* — รู้แล้วใช้ได้อย่างมั่นใจ ไม่ใช่ magic
