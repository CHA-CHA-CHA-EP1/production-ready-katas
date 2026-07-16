---
tier: file-handling/01-read-patterns
difficulty: 5
concepts: [binary-format, framing, io-readfull, endianness, length-prefix]
---

# Kata: Binary Format Parsing

## Context

ไม่ใช่ทุกไฟล์ที่เป็น text — database files, WAL logs, network packet captures, custom binary protocols
ล้วนใช้ binary format เพราะ compact กว่าและ parse เร็วกว่า
Bug ที่พบบ่อยที่สุดใน binary parser คือ assume ว่า `Read()` ให้ข้อมูลครบในครั้งเดียว

## Real World Incidents

**Incident 1 — WAL corruption ใน distributed database (etcd)**
etcd WAL reader ใช้ `f.Read(headerBuf)` อ่าน 8-byte header ของแต่ละ record
บน busy system read อาจ return น้อยกว่า 8 bytes โดยไม่มี error
parser ตีความ partial header เป็น length field → อ่าน body ผิดขนาด → WAL corrupt
แก้โดยเปลี่ยนมาใช้ `io.ReadFull` ทุกที่ที่ต้องการ exact bytes

**Incident 2 — Protobuf length-prefix framing อ่านข้อมูลข้ามกัน**
gRPC-like service encode message เป็น `[4-byte length][payload]`
receiver ใช้ `Read(lenBuf)` แล้ว `Read(payloadBuf)` สองครั้งแยกกัน
ถ้า Read แรกได้ 2 bytes และ Read สองได้ payload ของ message ก่อนหน้า → desync
ทุก message หลังจากนั้น parse ผิดหมด ไม่มี error เลย
แก้โดยใช้ `io.ReadFull` สำหรับทั้ง header และ payload

**Incident 3 — Endianness bug ระหว่าง ARM และ x86**
Binary format เขียนบน x86 (little-endian) อ่านบน ARM server
developer ใช้ `*(*uint32)(unsafe.Pointer(&buf[0]))` แปลง bytes เป็น int
ได้ค่าผิดบน ARM เพราะ byte order ต่างกัน → ตีความ record size ผิด → อ่านเกิน → panic
แก้โดยใช้ `binary.LittleEndian.Uint32()` ซึ่งระบุ byte order ชัดเจน

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
var header [8]byte
f.Read(header[:])      // อาจได้ partial
length := binary.LittleEndian.Uint32(header[:4])
body := make([]byte, length)
f.Read(body)           // อาจได้ partial
```

**พังตอนไหน:**
- `f.Read(header[:])` อาจ return 1-8 bytes
- บน local disk พบน้อยมาก แต่บน network, FIFO, slow disk เกิดบ่อย
- ไม่มี error → bug เงียบ ตรวจยากมาก

**Root cause:**
Binary format parser ต้องการ exact bytes ไม่ใช่ "อย่างน้อย N bytes"
`Read()` ไม่การันตี exact count — ต้องใช้ `io.ReadFull` หรือ loop

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `encoding/binary` package — `binary.LittleEndian` และ `binary.BigEndian` ต่างกันยังไง?
- hint: `binary.Read()` — รับ argument อะไร? ทำอะไรได้มากกว่า `LittleEndian.Uint32()`?
- hint: `io.ReadFull()` — ต่างจาก `io.ReadAtLeast()` ยังไง?
- Endianness คืออะไร? x86 ใช้ byte order แบบไหน? network byte order คืออะไร?
- `unsafe.Pointer` cast bytes เป็น struct ได้ แต่ทำไมถึงอันตรายกว่า `binary.Read`?

### Rust

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `u32::from_le_bytes()` และ `u32::from_be_bytes()` — รับ argument อะไร? ต่างจาก `byteorder` crate ยังไง?
- hint: `std::io::Read::read_exact()` — ต่างจาก `read()` ยังไง? ใช้แทน `io.ReadFull` ใน Go ได้ไหม?
- hint: `std::io::Cursor` — ใช้ทำอะไร? ทำไมถึงมีประโยชน์สำหรับ binary parsing?
- `byteorder` crate vs standard library — เมื่อไหรควรใช้อันไหน?
- CRC32 ใน Rust — `crc32fast` crate มี API ยังไง?

### Zig

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std.mem.readIntLittle()` และ `std.mem.readIntBig()` — signature คืออะไร? type parameter คืออะไร?
- hint: `std.mem.readIntSliceLittle()` — ต่างจาก `readIntLittle` ยังไง?
- hint: `std.io.fixedBufferStream()` — ใช้ทำอะไร? เหมาะกับ binary parsing ยังไง?
- Zig มี `packed struct` — ใช้ map binary format โดยตรงได้ไหม? มี risk อะไร?
- `std.hash.Crc32` — ใช้ verify checksum ยังไง?

## Task

ออกแบบ binary format สำหรับ "append-only event log" ที่มี record format:

```
[magic: 4 bytes][version: 1 byte][flags: 1 byte][payload_len: 4 bytes][payload: N bytes][crc32: 4 bytes]
```

เขียน:
1. `writeRecord(w, payload)` — encode และเขียน record
2. `readRecord(r)` — อ่านและ decode record หนึ่ง record
3. `readAllRecords(path)` — อ่านทุก record จากไฟล์

## Requirements

- ใช้ little-endian สำหรับ multi-byte integer ทั้งหมด
- ต้อง verify magic bytes ก่อนอ่าน — return error ถ้าไม่ตรง
- ต้อง verify CRC32 ของ payload — return error ถ้า corrupt
- ต้องใช้ `io.ReadFull` สำหรับทุก read — ห้าม assume ว่า `Read()` ให้ครบ
- ต้อง handle truncated record (EOF กลางคัน) ด้วย error ที่อ่านออก

## Acceptance Criteria

- [ ] เขียนแล้วอ่านกลับได้ถูกต้อง byte-for-byte
- [ ] detect magic byte ผิด → return error
- [ ] detect CRC mismatch → return error
- [ ] record ถูก truncate กลางคัน → return `io.ErrUnexpectedEOF` หรือ error ที่ wrap มัน
- [ ] อ่านถูกต้องบนทั้ง little-endian และ big-endian architecture
- [ ] ทดสอบด้วย `iotest.HalfReader` เพื่อ simulate partial read

## Concepts Involved

- `read-contract` — `Read()` partial return, `io.ReadFull` → `shared/concepts/read-contract.md`
- `endianness` — byte order, little vs big endian, network byte order → `shared/concepts/endianness.md`
- `binary-framing` — length-prefix, magic bytes, CRC, framing patterns → `shared/concepts/binary-framing.md`
- `integrity` — CRC32, checksum ใน binary format → `shared/concepts/integrity.md`

## Production Reality

- **ใช้จริง:** `encoding/binary` + `io.ReadFull` คือ production pattern สำหรับ custom binary format — ถ้า format ซับซ้อนพิจารณา protobuf / flatbuffers แทน
- **ทำ manual เมื่อ:** custom binary protocol, WAL format, ต้องการ zero-allocation parsing, หรือ interop กับ format ที่มีอยู่แล้ว
- **kata สอนว่า:** binary format ที่ดีต้องมี magic bytes + length prefix + checksum — เพื่อ detect corruption และ parse ได้โดยไม่ต้องรู้ขนาดล่วงหน้า
