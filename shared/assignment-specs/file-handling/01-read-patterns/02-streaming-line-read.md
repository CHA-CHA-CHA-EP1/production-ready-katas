---
tier: file-handling/01-read-patterns
difficulty: 2
concepts: [streaming-io, buffered-read, io-reader, line-processing]
---

# Kata: Streaming Line Read

## Context

Log processor, ETL pipeline, หรือ data importer ทุกตัวต้องอ่านไฟล์ขนาดใหญ่แบบ line-by-line
ไม่มีทางรู้ล่วงหน้าว่าไฟล์จะใหญ่แค่ไหน — log file วันนี้ 10 MB พรุ่งนี้อาจ 10 GB

## Real World Incidents

**Incident 1 — Log aggregator OOM ใน Kubernetes (Datadog, 2019)**
Agent อ่าน log file ด้วย `os.ReadFile` ก่อน parse
วันที่ disk เต็มช้า log file โตไม่หยุด agent โหลดทั้งก้อนเข้า heap
RSS พุ่งแซง memory limit → OOM kill → log หาย → alert storm
แก้โดยเปลี่ยนมาใช้ `bufio.Scanner` อ่านทีละบรรทัด RSS คงที่ไม่ว่าไฟล์จะใหญ่แค่ไหน

**Incident 2 — CSV importer timeout ใน payment service**
Batch import ใบแจ้งหนี้ CSV ขนาด 500 MB
โหลดทั้งไฟล์เข้า memory ก่อน process → request timeout ก่อนเสร็จ
แก้โดย stream อ่านทีละ row process ทันที memory ใช้คงที่ที่ ~1 MB ตลอด job

**Incident 3 — grep ใน monitoring tool ทำ latency spike**
Monitoring tool สแกน application log หา error pattern ทุก 30 วินาที
ใช้ `ioutil.ReadAll` แล้วค่อย `strings.Split` → GC pressure จากการ allocate string ใหญ่
แก้โดยใช้ `bufio.Scanner` + `bytes.Contains` ใน callback — ไม่ allocate string ขนาดใหญ่เลย

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```
data, _ := os.ReadFile(path)
lines := strings.Split(string(data), "\n")
for _, line := range lines { process(line) }
```

**พังตอนไหน:**
- ไฟล์ 1 GB → allocate string 1 GB + slice of strings อีกก้อน → RSS พุ่ง 2-3x ขนาดไฟล์
- ต้องรอโหลดครบก่อนจึงเริ่ม process ได้ — latency สูงโดยไม่จำเป็น
- GC ต้องเก็บ garbage ก้อนใหญ่หลัง process เสร็จ → GC pause

**Root cause:**
`strings.Split` สร้าง copy ของทุก line — memory usage เป็น O(file size) เสมอ
Streaming อ่านทีละ chunk ใช้ memory คงที่ไม่ว่าไฟล์จะใหญ่แค่ไหน

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `bufio.NewScanner()` — รับ argument อะไร? return type คืออะไร?
- hint: `(*bufio.Scanner).Scan()` — return type คืออะไร? หยุดเมื่อไหร่?
- hint: `(*bufio.Scanner).Text()` vs `(*bufio.Scanner).Bytes()` — ต่างกันยังไง? อันไหน allocate น้อยกว่า?
- hint: `(*bufio.Scanner).Err()` — ทำไมต้องเช็คหลัง loop? `Scan()` return false หมายความว่าอะไรได้บ้าง?
- `bufio.Scanner` มี default buffer size เท่าไหร่? ถ้า line ยาวกว่านั้นจะเกิดอะไร?

### Rust

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std::io::BufReader::new()` — รับ argument อะไร? return type คืออะไร?
- hint: `BufReader::lines()` — return type คืออะไร? แต่ละ item ใน iterator เป็น type อะไร?
- hint: `std::io::BufRead` trait — มี method อะไรบ้าง? `BufReader` implement trait นี้ยังไง?
- `lines()` allocate `String` ใหม่ทุก line ไหม? ถ้าอยากลด allocation จะใช้ method อะไรแทน?
- error จาก `lines()` iterator propagate ยังไง? ต้อง handle ตรงไหน?

### Zig

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std.io.bufferedReader()` — รับ argument อะไร? return type คืออะไร?
- hint: `reader.readUntilDelimiterOrEof()` — signature คืออะไร? `delimiter` คือ byte อะไรสำหรับ newline?
- buffer ที่ส่งเข้า `readUntilDelimiterOrEof` ต้องมีขนาดเท่าไหร่? จะเกิดอะไรถ้า line ยาวกว่า buffer?
- Zig ไม่มี `bufio.Scanner` แบบ Go — ต้องจัดการ buffer เองยังไง?
- `error.StreamTooLong` เกิดเมื่อไหร่? handle ยังไง?

## Task

implement `countLines(path)` ที่:

1. อ่านไฟล์ข้อความขนาดใดก็ได้แบบ streaming
2. นับจำนวนบรรทัดทั้งหมด
3. ใช้ memory คงที่ไม่ว่าไฟล์จะใหญ่แค่ไหน

จากนั้นเขียน `grepLines(path, pattern)` ที่:

1. อ่านแบบ streaming เช่นเดียวกัน
2. คืน slice ของบรรทัดที่มี pattern อยู่
3. ไม่โหลด content ทั้งหมดเข้า memory

## Requirements

- RSS ต้องคงที่ไม่เกิน 10 MB ไม่ว่าไฟล์จะมีขนาดเท่าไหร่
- ต้อง handle บรรทัดที่ยาวกว่า default scanner buffer (64 KB) ได้โดยไม่ panic
- ต้องปิด file descriptor ทุก code path
- ต้อง handle ไฟล์ที่ไม่มี newline ต่อท้ายบรรทัดสุดท้าย

## Acceptance Criteria

- [ ] `CountLines` นับถูกต้องสำหรับไฟล์ปกติ
- [ ] `CountLines` นับถูกต้องสำหรับไฟล์ที่บรรทัดสุดท้ายไม่มี `\n`
- [ ] `CountLines` ทำงานกับไฟล์ขนาด 1 GB โดย RSS ไม่เกิน 10 MB
- [ ] `GrepLines` คืนเฉพาะบรรทัดที่ match pattern
- [ ] ทั้งสองฟังก์ชัน return error ถ้าไฟล์อ่านไม่ได้
- [ ] Scanner error ถูก propagate กลับ ไม่ถูก swallow

## Concepts Involved

- `buffered-io` — kernel buffer vs userspace buffer, ทำไม bufio ถึงเร็ว → `shared/concepts/buffered-io.md`

## Production Reality

- **ใช้จริง:** `bufio.Scanner` / `bufio.NewReader` คือ production way จริงๆ — kata นี้ไม่ได้ห้ามใช้ สอนให้เข้าใจว่า bufio ทำงานยังไงก่อนใช้
- **ทำ manual เมื่อ:** บรรทัดยาวกว่า 64 KB ต้องการ custom `SplitFunc` หรือ resize buffer ด้วย `Scanner.Buffer()`
- **kata สอนว่า:** streaming ≠ magic — มี kernel buffer + userspace buffer อยู่ เข้าใจแล้วจะ tune ได้เมื่อเจอ bottleneck
- `io-reader` — `io.Reader` interface contract, streaming abstraction → `shared/concepts/io-reader.md`
- `memory-allocation` — heap allocation กับ GC pressure → `shared/concepts/memory-allocation.md`
