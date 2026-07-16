---
tier: file-handling/01-read-patterns
difficulty: 4
concepts: [checkpoint, offset-persistence, atomic-write, crash-recovery]
---

# Kata: Checkpoint Read (Resume from Offset)

## Context

Log shipper, batch processor, หรือ ETL pipeline ที่รันบน Kubernetes ต้องรับมือกับ pod restart ตลอดเวลา
ถ้าไม่บันทึกว่าอ่านถึงไหนแล้ว ทุกครั้งที่ restart ต้องเริ่มใหม่ตั้งแต่ต้น
หรือแย่กว่านั้น ถ้าบันทึก offset ผิด อาจข้ามข้อมูลสำคัญไป

## Real World Incidents

**Incident 1 — Log shipper ส่ง log ซ้ำทุกครั้งที่ pod restart (Fluentd)**
Fluentd ถูก config ให้อ่าน access log แล้วส่งไป Elasticsearch
checkpoint file ถูกเขียนทุก 10 วินาที แต่ไม่ได้ fsync
ตอน pod restart กะทันหัน OS buffer ยังไม่ flush → checkpoint file ว่างเปล่า
Fluentd อ่านใหม่จากต้น → Elasticsearch ได้ log ซ้ำ → dashboard metrics ผิด
แก้โดย fsync checkpoint ก่อน acknowledge message

**Incident 2 — Batch processor ข้าม record ตอน failover**
Processor เขียน checkpoint ก่อนที่จะ process record จริง
ตายระหว่าง process → restart แล้วเห็น checkpoint ที่ advance แล้ว → ข้าม record
แก้โดยเขียน checkpoint หลัง process + acknowledge สำเร็จเท่านั้น (at-least-once delivery)

**Incident 3 — Checkpoint file corrupt ทำให้ processor หยุด**
Checkpoint เขียนด้วย `os.WriteFile` โดยตรงทับไฟล์เดิม
ถ้า process ตายระหว่างเขียน checkpoint file อาจเป็น partial write → corrupt JSON
processor อ่าน checkpoint ไม่ได้ → panic → ไม่มีทาง recover อัตโนมัติ
แก้โดยใช้ atomic write (write temp file → rename)

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```
offset, _ := os.ReadFile("checkpoint")
f.Seek(int64(offset), io.SeekStart)
// ... process ...
os.WriteFile("checkpoint", []byte(newOffset))
```

**พังตอนไหน:**
- `os.WriteFile` ไม่ atomic → ถ้าตายระหว่างเขียน checkpoint corrupt
- ไม่ fsync → OS crash → checkpoint ใน buffer หาย
- เขียน checkpoint ก่อน process → ข้าม record ถ้า process fail

**Root cause:**
Checkpoint ที่ดีต้องการ atomicity (เขียนสำเร็จหรือไม่สำเร็จทั้งหมด)
และต้องเขียนในลำดับที่ถูก: process สำเร็จ → flush checkpoint → ยืนยัน

## Explore First

### Go

ก่อนเขียน code ให้เปิด stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `(*os.File).Sync()` — ทำอะไร? ต่างจาก `Close()` ยังไง? ต้องเรียกเมื่อไหร่?
- hint: `os.Rename()` — ทำไม rename ถึง atomic บน POSIX? ข้อจำกัดคืออะไร?
- hint: `os.CreateTemp()` — ใช้สร้าง temp file สำหรับ atomic write ยังไง?
- ถ้า checkpoint และ data file อยู่ต่าง filesystem กัน `os.Rename` ยังใช้ได้ไหม?
- "at-least-once" vs "exactly-once" delivery ต่างกันยังไง? checkpoint ช่วย guarantee อะไรได้บ้าง?

### Rust

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `std::fs::File::sync_all()` — ทำอะไร? ต่างจาก `sync_data()` ยังไง? เรียกเมื่อไหร่?
- hint: `std::fs::rename()` — atomic บน POSIX ไหม? ข้อจำกัดข้าม filesystem คืออะไร?
- hint: `tempfile` crate (หรือ `NamedTempFile`) — ใช้สร้าง temp file สำหรับ atomic write ยังไง?
- Rust ไม่มี `defer` — จะ ensure file ถูก close + sync ทุก code path ยังไง? `Drop` ช่วยได้ไหม?
- "at-least-once" delivery หมายความว่าอะไรในบริบทของ checkpoint? เขียน checkpoint ก่อนหรือหลัง process?

### Zig

ก่อนเขียน code ให้เปิด official docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ official docs / go to definition)

- hint: `file.sync()` — ทำอะไร? เรียก fsync(2) ไหม?
- hint: `std.fs.rename()` — signature คืออะไร? ทำไม atomic บน POSIX?
- hint: `std.fs.Dir.createFile()` กับ `std.fs.AtomicFile` — ต่างกันยังไง?
- Zig มี `std.fs.AtomicFile` — ใช้ทำ atomic write ยังไง? `.finish()` ทำอะไร?
- error handling: ถ้า `finish()` fail หลัง write แล้ว temp file จะถูก cleanup ไหม?

## Task

implement `CheckpointReader` struct ที่:

1. `read(n)` — อ่าน n บรรทัดถัดไปจาก checkpoint ล่าสุด
2. `commit()` — บันทึก checkpoint ปัจจุบันลงดิสก์แบบ atomic
3. `close()` — ปิด resource ทั้งหมด

พร้อม constructor `newCheckpointReader(dataPath, checkpointPath)`

## Requirements

- Checkpoint ต้องเขียนแบบ atomic — ไม่มี partial state
- ต้อง fsync checkpoint ก่อน return จาก `Commit()`
- ถ้า checkpoint file corrupt หรือไม่มี ให้ start จากต้นไฟล์
- `Commit` ต้องเรียกหลัง process เสมอ ไม่ใช่ก่อน
- ถ้า `Read` เรียกหลาย batch แล้ว `Commit` เพียงครั้งเดียว ต้อง commit offset ล่าสุดที่ถูกต้อง

## Acceptance Criteria

- [ ] หลัง `Commit` แล้ว restart — `Read` ต่อจาก offset ที่ commit ไว้
- [ ] ถ้า process ตายระหว่าง `Read` ก่อน `Commit` — restart อ่านข้อมูลซ้ำ (at-least-once)
- [ ] checkpoint file corrupt → fallback ไปอ่านจากต้นโดยไม่ panic
- [ ] เขียน checkpoint concurrent 2 goroutine — ไม่เกิด corrupt
- [ ] ไฟล์ว่างเปล่า → `Read` คืน empty slice ไม่ error

## Concepts Involved

- `fsync` — kernel page cache, fsync ทำอะไรกับ durability → `shared/concepts/fsync.md`
- `atomic-write` — write temp + rename pattern → `shared/concepts/atomic-write.md`
- `seek-lseek` — tracking และ restoring file offset → `shared/concepts/seek-lseek.md`
- `crash-recovery` — at-least-once vs exactly-once, checkpoint ordering → `shared/concepts/crash-recovery.md`

## Production Reality

- **ใช้จริง:** write-to-temp + rename คือ production pattern จริงๆ ไม่มี stdlib shortcut — ต้องทำเองทุกครั้ง
- **ทำ manual เมื่อ:** เสมอ สำหรับ durable checkpoint — library เช่น Kafka consumer ก็ใช้ pattern นี้ under the hood
- **kata สอนว่า:** ทำไม "write แล้ว crash" ถึงอันตราย — rename atomicity ของ OS คือหัวใจของ crash-safe write
