---
tier: cloud-storage
difficulty: 1
concepts: [streaming-io, io.ReadCloser, io.Copy, defer, disk-avoidance]
---

# Kata: Streaming Download

## Context

เมื่อ service ต้องส่งไฟล์จาก S3/MinIO ไปให้ client (HTTP response, another service, หรือ pipeline downstream) มีสองทาง — download มาเก็บ temp file บน disk ก่อนแล้วค่อยส่ง หรือ pipe ตรงจาก S3 ไปยัง destination เลย
วิธีแรกดูปลอดภัยและเข้าใจง่าย แต่ใน production ที่มี concurrent request จำนวนมาก disk จะเต็มจาก temp file สะสม และ latency จะสูงกว่าเพราะต้อง write+read สองรอบ
Pattern ที่ถูกต้องคือใช้ `io.Copy` เพื่อ pipe bytes จาก S3 response โดยตรง — disk ไม่ถูกแตะเลย

## Real World Incidents

**Incident 1 — Disk เต็มจาก temp file สะสม (File sharing service)**
ทีมเขียน download handler โดย `GetObject` → เขียนลง `/tmp` → อ่านกลับ → ส่ง HTTP response → ลบ temp file
ใน error path (client disconnect, timeout) code ข้ามบรรทัด delete ไป — temp file ค้างอยู่บน disk
หลังรันไป 3 วัน disk เต็ม — service ใหม่ที่ต้องการเขียน log ทำไม่ได้ — cascading failure ทั่วทั้ง node
แก้โดยใช้ `defer os.Remove(tmpPath)` และเปลี่ยนมา pipe ตรงแทน

**Incident 2 — Latency สูงจาก double-write (Image CDN backend)**
ระบบ CDN origin server download image จาก S3 มาเก็บ temp file ก่อนส่ง response
สำหรับไฟล์ 10MB ใช้เวลา: download S3→disk (500ms) + read disk→response (300ms) = 800ms ทั้งหมด
เมื่อเปลี่ยนมาใช้ `io.Copy(responseWriter, s3Object)` — latency ลดลงเหลือ ~500ms ทันที (first byte ออกไปก่อน download เสร็จ)
นอกจากนี้ยังลด IOPS บน disk ไปได้ประมาณ 60%

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
obj, err := client.GetObject(ctx, bucket, key, minio.GetObjectOptions{})
if err != nil { return err }

tmpFile, _ := os.CreateTemp("", "download-*")
io.Copy(tmpFile, obj)          // เขียนลง disk ก่อน
tmpFile.Seek(0, io.SeekStart)
io.Copy(w, tmpFile)            // อ่านกลับแล้วค่อยส่ง
os.Remove(tmpFile.Name())      // ลบ temp
```

**พังตอนไหน:**
- Client disconnect ระหว่าง download → `io.Copy(w, tmpFile)` return error → code ข้าม `os.Remove` → temp file ค้างบน disk
- 500 concurrent downloads ขนาด 50MB → ต้องการ disk space 25GB ชั่วคราว — disk เต็ม
- Large file (1GB+) → ต้องรอ download เสร็จทั้งหมดก่อน client จะเห็น byte แรก — TTFB สูงมาก

**Root cause:**
temp file เป็น unnecessary middleman — data ต้องเดินทาง S3 → disk → memory → client แทนที่จะเป็น S3 → memory → client
และการ cleanup temp file ใน every possible error path นั้นยากมากในทางปฏิบัติ — มักมี path ที่พลาด

## Explore First

### Go

ก่อนเขียน code ให้เปิด MinIO SDK และ stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `minio.Client.GetObject(...)` — return type คืออะไร? implements interface อะไรบ้าง? ต้อง `Close()` ไหมและทำไม?
- hint: `io.Copy(dst io.Writer, src io.Reader)` — allocate buffer ขนาดเท่าไหร่ภายใน? copy ทีละกี่ bytes? memory footprint คงที่ไหม?
- hint: `defer obj.Close()` — ถ้าไม่ defer แล้ว return error ก่อน Close จะเกิดอะไรขึ้น? connection leak มีผลต่อ S3 ยังไง?
- `*minio.Object` implements `io.ReadCloser` — หมายความว่าอะไร? สามารถส่งตรงเข้า `io.Copy` ได้เลยไหม?
- `io.Writer` ที่ส่งเข้ามา อาจเป็น `http.ResponseWriter` — มีข้อแตกต่างจาก regular `io.Writer` ตรงไหน? error handling ต่างกันไหม?

### Concepts to understand first

- `io.ReadCloser`: ทำไม S3 object ถึงต้อง `Close()` ด้วย? HTTP connection ที่ open ค้างไว้มีต้นทุนอะไร?
- `io.Copy` internals: copy ทีละ 32KB โดย default — ทำให้ memory สำหรับ stream ขนาด 1GB ยังคงอยู่ที่ ~32KB เท่านั้น
- `TTFB (Time To First Byte)`: ทำไม streaming แบบ pipe จึงให้ TTFB ต่ำกว่า download-then-serve?

## Task

เขียนฟังก์ชัน `StreamDownload(client *minio.Client, bucket, key string, w io.Writer) error` ที่:

1. Download object จาก MinIO/S3 โดยไม่เขียนลง disk เลย
2. Pipe bytes ตรงจาก S3 response ไปยัง `w` ทันที
3. Close S3 object ทุกกรณี — ทั้ง success และ error path
4. Return error พร้อม context ถ้าเกิดปัญหาระหว่าง download หรือ write

## Requirements

- ห้ามสร้าง temp file หรือ buffer ทั้งไฟล์ใน memory
- ต้อง `defer obj.Close()` ทันทีหลังได้ object — ห้ามข้ามบรรทัดนี้
- ถ้า object ไม่มีใน bucket — return error ที่ชัดเจน เช่น `"StreamDownload: bucket/key: object not found"`
- ถ้า write ไปยัง `w` fail กลางคัน (เช่น client disconnect) — ฟังก์ชันต้อง return error ทันที ไม่ใช่อ่าน S3 ต่อจนจบ
- ฟังก์ชันต้องไม่สนใจว่า `w` คืออะไร — `http.ResponseWriter`, `os.File`, `bytes.Buffer` ล้วน valid

## Acceptance Criteria

- [ ] Download object ได้ถูกต้อง — bytes ตรงกับที่ upload ไปทุก byte
- [ ] ไม่มี temp file ถูกสร้างบน disk ระหว่าง download
- [ ] ถ้า `w` return error (เช่น pipe broken) — ฟังก์ชัน return error และ S3 connection ถูกปิด
- [ ] Object ที่ไม่มีอยู่ใน bucket → return error ที่ wrap bucket+key ไว้ใน message
- [ ] S3 connection ถูก Close เสมอ ไม่ว่าจะ success หรือ error (ตรวจด้วย mock หรือ goroutine count)
- [ ] ไม่มี goroutine leak หลังฟังก์ชัน return

## Concepts Involved

- `io.ReadCloser` — extends `io.Reader` ด้วย `Close()` method — ทำไม resource cleanup ถึงสำคัญ
- `io.Copy` — efficient byte piping ด้วย internal buffer คงที่
- `defer` — pattern สำหรับ guaranteed cleanup ไม่ว่า control flow จะไปทางไหน
- `disk-avoidance` — การออกแบบ pipeline ที่ไม่แตะ disk โดยไม่จำเป็น

## Production Reality

- **ใช้จริง:** `io.Copy(w, s3Object)` คือ pattern หลักของ proxy server, CDN origin, และ download API ทั้งหลาย
- **ทำ manual เมื่อ:** ต้องการ checksum verification ระหว่าง stream, bandwidth throttling, หรือ progress callback
- **http.ResponseWriter gotcha:** ถ้า `w` เป็น `http.ResponseWriter` ต้อง set header (Content-Type, Content-Length) ก่อนเรียก `io.Copy` — เพราะหลังจาก write bytes ไปแล้ว header จะเปลี่ยนไม่ได้
- **kata สอนว่า:** `defer obj.Close()` ทันทีหลังได้ object เป็น habit ที่สำคัญที่สุด — resource leak จาก S3 connection ที่ไม่ปิดทำให้ S3 rate limit และ connection pool หมดได้
