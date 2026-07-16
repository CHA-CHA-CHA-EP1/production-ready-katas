---
tier: file-handling/01-read-patterns
difficulty: 2
concepts: [read-contract, io-reader, partial-read, io-readfull]
---

# Kata: Chunked Read

## Context

ทุกครั้งที่อ่านข้อมูลจาก `io.Reader` — ไม่ว่าจะเป็นไฟล์, network socket, หรือ pipe —
kernel ไม่การันตีว่าจะส่งข้อมูลครบตาม buffer ที่ขอมาในครั้งเดียว
นี่คือ contract ของ `Read()` ที่คนส่วนใหญ่ไม่รู้จนกว่าจะเจอ bug ใน production

## Real World Incidents

**Incident 1 — Binary file parser อ่านข้อมูลขาด (HashiCorp Vault)**
Parser อ่าน record จาก WAL file โดยเรียก `f.Read(buf)` แล้วใช้ `buf` ทันที
บน local dev ได้รับข้อมูลครบทุกครั้ง แต่บน NFS mount `Read()` อาจ return น้อยกว่า buffer
parser ตีความ partial data ผิด → record corruption → vault ไม่ยอม unseal
แก้โดยเปลี่ยนมาใช้ `io.ReadFull` ซึ่งการันตีว่าอ่านครบหรือ error

**Incident 2 — Network protocol parser หลุดเฉพาะ traffic สูง**
Service รับ binary message จาก TCP connection อ่านด้วย `conn.Read(buf)`
บน dev traffic น้อย TCP ส่งมาครั้งเดียวครบ แต่ high traffic TCP อาจแตก packet
parser เห็น partial message ตีความ length field ผิด → message ทั้งหมดหลังจากนั้น desync
แก้โดย loop `Read()` จนครบ length ที่กำหนดไว้ใน header

**Incident 3 — File copy tool ข้อมูลหาย**
Tool copy ไฟล์ binary โดย `n, _ := src.Read(buf)` แล้ว `dst.Write(buf)` โดยไม่เช็ค `n`
เมื่อ `Read()` return 512 bytes แต่ buf มีขนาด 4096 → write buf ทั้งก้อน 4096 bytes
ปลายทางได้ข้อมูลเกิน + garbage จาก buf เดิม
แก้โดยใช้ `dst.Write(buf[:n])`

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```
buf := make([]byte, 4096)
n, err := f.Read(buf)
// ใช้ buf ทันทีโดยสมมติว่าครบ
process(buf)
```

**พังตอนไหน:**
- `Read()` spec บอกว่า return ได้ตั้งแต่ 1 byte ถึง `len(buf)` bytes
- บน local disk มักได้ครบเพราะ page cache อยู่ใน RAM อยู่แล้ว
- บน NFS, network, FIFO, หรือ slow disk → partial read เกิดได้ตลอด
- การ assume ว่าครบทำให้ bug หายากมาก: ทำงานได้ 99.9% แต่พังเฉพาะ edge case

**Root cause:**
`Read()` ใน POSIX คือ syscall `read(2)` ซึ่งระบุชัดว่า return value คือ "จำนวน byte ที่อ่านได้จริง"
ไม่ใช่ "จำนวน byte ที่ขอ" — การ assume ว่าเท่ากันคือ undefined behavior

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `io.ReadFull()` — signature คืออะไร? ต่างจาก `Read()` ยังไง? return `ErrUnexpectedEOF` เมื่อไหร่?
- hint: `io.ReadAtLeast()` — ใช้แทน `ReadFull` ได้ในกรณีไหน?
- hint: `(*os.File).Read()` — ถ้า return `n < len(buf)` แต่ `err == nil` หมายความว่าอะไร?
- `io.EOF` กับ `io.ErrUnexpectedEOF` ต่างกันยังไง? แต่ละอันเกิดเมื่อไหร่?
- ถ้าต้องอ่านให้ครบ N bytes แน่ๆ โดยไม่ใช้ `io.ReadFull` จะต้อง loop ยังไง?

### Rust

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std::io::Read::read()` — return type คืออะไร? `Ok(0)` หมายความว่าอะไร?
- hint: `read_exact()` — ต่างจาก `read()` ยังไง? error `UnexpectedEof` เกิดเมื่อไหร่?
- hint: `std::io::Read::read_to_end()` — ทำงานยังไง? เหมาะกับ use case ไหน?
- Rust มี `io::copy()` — ทำงานยังไง? buffer ขนาดเท่าไหร่?
- ถ้า `read()` return `Ok(n)` ที่ n < buf.len() แต่ไม่ใช่ 0 — ควรทำอะไร?

### Zig

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `file.read()` — return type คืออะไร? `0` หมายความว่าอะไร?
- hint: `file.readAll()` — ต่างจาก `read()` ยังไง? เหมาะกับ use case ไหน?
- hint: `file.reader().readAll()` vs `file.readAll()` — ต่างกันยังไง?
- ถ้าต้องการ read exact N bytes ใน Zig ต้องเขียน loop เองยังไง?
- `error.EndOfStream` กับ `error.InputOutput` ต่างกันยังไง?

## Task

implement `readChunked(path, chunkSize, fn)` ที่:

1. อ่านไฟล์ทีละ chunk ขนาด `chunkSize` bytes
2. เรียก `fn` ทุกครั้งที่ได้ chunk — `fn` ได้รับข้อมูลครบเสมอ ยกเว้น chunk สุดท้ายที่อาจสั้นกว่า
3. หยุดและ return error ถ้า `fn` return error

จากนั้นเขียน `readExact(r, n)` ที่:

1. อ่านข้อมูลให้ได้ครบ n bytes เสมอ
2. ถ้าไฟล์หมดก่อน n bytes → return error

## Requirements

- `fn` ต้องได้รับ slice ที่มีข้อมูลจริงเท่านั้น — ห้ามส่ง trailing zeros จาก buffer
- `ReadExact` ต้องไม่ return partial data — ครบหรือ error เท่านั้น
- ห้ามใช้ read-all shortcut หรือ stdlib one-liner shortcut
- Buffer ต้อง reuse ข้ามการเรียก `fn` ได้ (ไม่ allocate ใหม่ทุก chunk)

## Acceptance Criteria

- [ ] `ReadChunked` เรียก `fn` ด้วยข้อมูลครบทุก chunk
- [ ] chunk สุดท้ายที่เล็กกว่า `chunkSize` ถูกส่งถูกต้อง ไม่มี zero padding
- [ ] ถ้า `fn` return error การอ่านหยุดและ error ถูก propagate
- [ ] `ReadExact` คืน error ถ้าข้อมูลน้อยกว่า n bytes
- [ ] ทดสอบกับ `readable stream` ที่ return partial data จงใจ (เช่น `iotest.HalfReader`)

## Concepts Involved

- `read-contract` — POSIX `read(2)` contract, partial read คืออะไร → `shared/concepts/read-contract.md`
- `io-reader` — `io.Reader` interface และ idiomatic usage → `shared/concepts/io-reader.md`
- `buffered-io` — kernel buffer, userspace buffer, ทำไมบน local disk มักได้ครบ → `shared/concepts/buffered-io.md`

## Production Reality

- **ใช้จริง:** `io.ReadFull(r, buf)` สำหรับ exact-size read, `io.Copy` สำหรับ stream copy — stdlib จัดการ partial read ให้แล้ว
- **ทำ manual เมื่อ:** protocol parsing ที่ต้องการ reuse buffer เพื่อ zero-allocation, หรือ chunk callback pattern
- **kata สอนว่า:** `Read()` ใน POSIX ไม่การันตีว่าให้ครบ — `io.ReadFull` แก้ปัญหานี้ เข้าใจแล้วจะไม่เขียน `Read()` เปล่าๆ อีก
