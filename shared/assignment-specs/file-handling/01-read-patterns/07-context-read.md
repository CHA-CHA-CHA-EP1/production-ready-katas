---
tier: file-handling/01-read-patterns
difficulty: 4
concepts: [context, cancellation, goroutine-leak, fifo, non-blocking-io]
---

# Kata: Context-Aware Read (Timeout / Cancellation)

## Context

`os.File.Read()` บน regular file แทบไม่ block นาน แต่บน FIFO, named pipe, slow NFS mount,
หรือ `/proc` special file — `Read()` อาจ block ตลอดไป
Service ที่ไม่มี timeout จะมี goroutine ค้างอยู่ไม่มีวันจบ และ leak ไปเรื่อยๆ

## Real World Incidents

**Incident 1 — Goroutine leak จาก FIFO reader ใน log pipeline**
Pipeline รับ log ผ่าน named pipe (`/run/app/log.pipe`)
reader goroutine เรียก `f.Read()` โดยไม่มี timeout
เมื่อ writer process ตาย reader block ตลอดไป ไม่มีทางรู้ว่า writer หายไป
หลัง deploy หลายครั้ง goroutine สะสมจนถึงหลักพัน → memory leak
แก้โดยใช้ non-blocking read + context cancellation

**Incident 2 — Config reloader hang บน NFS timeout**
Service reload config จาก NFS mount ทุก 30 วินาที
NFS server มีปัญหา network intermittent — mount ยังอยู่แต่ read block นานมาก
`os.ReadFile` block นานกว่า 2 นาที ทำให้ reload goroutine ค้าง
config เก่าถูกใช้ไปเรื่อยๆ โดยไม่รู้ว่า reload fail
แก้โดย wrap read ด้วย context ที่มี timeout 5 วินาที

**Incident 3 — Health check endpoint timeout เพราะอ่าน `/proc/net/tcp` ช้า**
Health check อ่าน `/proc/net/tcp` เพื่อนับ open connections
บน container ที่มี network namespace ใหญ่ การอ่านไฟล์นี้ช้ามาก
health check timeout → load balancer คิดว่า pod ไม่ healthy → remove จาก pool
แก้โดยเพิ่ม deadline ให้การอ่าน

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
f, _ := os.Open(path)
data, err := io.ReadAll(f)  // block ตลอดไปถ้า source ช้า
```

**พังตอนไหน:**
- regular file บน local disk แทบไม่เจอปัญหา
- FIFO, NFS, `/proc`, pipe → block ได้นานหรือตลอดไป
- goroutine ที่ block ไม่ถูก GC → memory leak เงียบๆ
- ไม่มีทาง cancel จาก outside โดยไม่ kill process

**Root cause:**
`os.File` ไม่มี `SetDeadline` แบบ `net.Conn`
ต้องใช้ OS-level non-blocking flag หรือ goroutine + select pattern

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `context.WithTimeout()` และ `context.WithDeadline()` — ต่างกันยังไง? return อะไร?
- hint: `context.Context.Done()` — return type คืออะไร? ใช้ใน `select` ยังไง?
- hint: `syscall.SetNonblock()` — ทำอะไร? ถ้า `Read()` บน non-blocking fd แล้วไม่มีข้อมูล return อะไร?
- goroutine ที่ block อยู่ใน `Read()` จะถูก GC เก็บไหม? ทำไม?
- ถ้าจะ cancel read โดยใช้ goroutine + channel pattern ต้องระวังอะไร? goroutine ที่ spawn แล้วจะจบยังไง?

### Rust

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `tokio::time::timeout()` — รับ argument อะไร? return type คืออะไร?
- hint: `tokio::select!` macro — ใช้ cancel async operation ยังไง?
- hint: `tokio::fs::File` vs `std::fs::File` — ต่างกันยังไงในแง่ async/blocking?
- Rust async runtime (Tokio) handle cancellation ยังไง? `CancellationToken` คืออะไร?
- goroutine leak ใน Go เทียบกับ Rust async task leak — เหมือนหรือต่างกันยังไง?

### Zig

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- Zig standard library ไม่มี built-in async runtime เหมือน Go/Rust — จะ implement timeout ยังไง?
- hint: `std.os.poll()` หรือ `std.os.epoll_wait()` — ใช้ทำ non-blocking I/O บน Linux ยังไง?
- hint: `std.Thread` — ถ้าใช้ thread-based timeout จะ design ยังไง?
- Zig มี `async`/`await` (experimental) — ต่างจาก Rust async ยังไง?
- named pipe (FIFO) บน Linux — `open()` กับ flag `O_NONBLOCK` ทำงานยังไงใน Zig?

## Task

เขียนฟังก์ชัน `ReadWithContext(ctx context.Context, path string) ([]byte, error)` ที่:

1. อ่านไฟล์ทั้งหมด แต่หยุดทันทีถ้า context ถูก cancel หรือ timeout
2. ถ้า cancel → return `ctx.Err()`
3. ไม่ leak goroutine ไม่ว่าจะ cancel หรือ success

จากนั้นเขียน `ReadLineWithContext(ctx context.Context, r io.Reader) (string, error)` ที่:

1. อ่านหนึ่งบรรทัดจาก `io.Reader` ที่อาจ block ได้
2. cancel ได้ผ่าน context

## Requirements

- ต้องไม่ leak goroutine ทั้งกรณี success, cancel, และ timeout
- ถ้า context cancel ระหว่างอ่าน ต้องหยุดทันที ไม่รอให้ `Read()` จบ
- ต้อง return `context.DeadlineExceeded` หรือ `context.Canceled` ตาม context error
- ทดสอบกับ FIFO ที่ไม่มี writer (block ตลอดไป)

## Acceptance Criteria

- [ ] อ่านไฟล์ปกติสำเร็จเมื่อไม่มี timeout
- [ ] cancel context ระหว่างอ่าน → return error ทันที
- [ ] timeout หมด → return `context.DeadlineExceeded`
- [ ] ไม่มี goroutine leak หลังจากทุก test case (ตรวจด้วย `goleak` หรือ `runtime.NumGoroutine()`)
- [ ] ทำงานถูกต้องกับ FIFO (`mkfifo`) ที่ไม่มี writer

## Concepts Involved

- `context-cancellation` — context tree, cancellation propagation → `shared/concepts/context-cancellation.md`
- `goroutine-leak` — goroutine ที่ block ค้างอยู่, วิธีตรวจ → `shared/concepts/goroutine-leak.md`
- `non-blocking-io` — O_NONBLOCK, EAGAIN, epoll → `shared/concepts/non-blocking-io.md`
- `fifo-pipe` — named pipe บน Linux, blocking behavior → `shared/concepts/fifo-pipe.md`
