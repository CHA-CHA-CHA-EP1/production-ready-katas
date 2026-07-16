---
tier: cloud-storage
difficulty: 1
concepts: [streaming-io, io.Reader, memory-efficiency, object-storage]
---

# Kata: Streaming Upload

## Context

ทุก service ที่รับ file upload จาก user ต้องตัดสินใจว่าจะจัดการ bytes เหล่านั้นยังไง — buffer ทั้งหมดในหน่วยความจำก่อน แล้วค่อย upload ไป S3/MinIO หรือ pipe bytes ตรงไปเลยโดยไม่แตะ RAM
เมื่อ file มีขนาดเล็กกว่า 10MB ทั้งสองวิธีดูเหมือนจะทำงานได้เหมือนกัน — แต่พอ user upload วิดีโอ 2GB หรือ database dump ขนาดใหญ่ วิธีแรกทำให้ service พัง
Production system ที่ดีต้องรับ file ขนาดใดก็ได้โดยที่ memory footprint คงที่ ไม่ขึ้นกับขนาดไฟล์

## Real World Incidents

**Incident 1 — OOM crash ระหว่าง video upload (Media streaming startup, 2021)**
ทีม backend เขียน endpoint รับ video upload โดย `io.ReadAll(r.Body)` ก่อนแล้วค่อยส่งไป S3
ช่วง marketing campaign มี user พร้อมกันหลายร้อยคน แต่ละคน upload วิดีโอ 500MB–1GB
pod memory พุ่งจาก 512MB ไปถึง 8GB ใน 10 นาที — Kubernetes kill pod ทิ้งทุก upload ที่กำลังทำอยู่
แก้โดยเปลี่ยนมาส่ง `r.Body` (io.Reader) ตรงไปให้ SDK — memory ต่อ request กลับมาอยู่ที่ ~256KB

**Incident 2 — Service crash จาก single large file upload (Document management system)**
ระบบ internal ของบริษัทรับ CAD file และ PDF ขนาดใหญ่จาก engineer
มีคนพยายาม upload ไฟล์ขนาด 4.2GB — service โหลด bytes ทั้งหมดเข้า `[]byte` ก่อน
ไม่มี heap พอ: Go runtime panic ด้วย `runtime: out of memory` — service ล่มกลางคัน ทำให้ user อื่นที่ไม่เกี่ยวข้องพัง
แก้โดยเปลี่ยน signature จาก `data []byte` เป็น `r io.Reader` และใช้ PutObject แบบ streaming

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
data, err := io.ReadAll(r)      // โหลดทั้งไฟล์เข้า memory
if err != nil { return err }
_, err = client.PutObject(ctx, bucket, key,
    bytes.NewReader(data), int64(len(data)), opts)
```

**พังตอนไหน:**
- File ขนาด 2GB บน pod ที่มี memory limit 512MB → OOM kill ทันที
- มี 100 concurrent upload พร้อมกัน แม้แค่ 50MB ต่อไฟล์ก็ใช้ 5GB RAM
- Lambda หรือ serverless function ที่มี memory limit เข้มงวด → function timeout หรือ crash ก่อนจะ upload เสร็จ

**Root cause:**
`io.ReadAll` ต้องการ memory เท่ากับขนาดไฟล์ทั้งหมด ก่อนที่จะส่ง byte แรกไปถึง S3 เลยด้วยซ้ำ
SDK รองรับ `io.Reader` โดยตรง — bytes สามารถไหลผ่านโดยใช้ buffer เล็กๆ (~32KB) ตลอดทาง

## Explore First

### Go

ก่อนเขียน code ให้เปิด MinIO SDK แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `minio.Client.PutObject(ctx, bucket, object string, reader io.Reader, objectSize int64, opts minio.PutObjectOptions)` — parameter `objectSize` รับค่าอะไรได้บ้าง? ถ้า size ไม่รู้ล่วงหน้าใส่ค่าอะไร?
- hint: `minio.PutObjectOptions` — field `ContentType` มีผลต่อ object ที่เก็บยังไง? ถ้าไม่ set จะเกิดอะไรขึ้น?
- hint: `io.Reader` vs `[]byte` — SDK ต้องการ `io.Reader` ไม่ใช่ `[]byte` เพราะอะไร? connection กับ S3 เปิดค้างไว้ระหว่าง read ไหม?
- hint: `http.Request.Body` implements `io.Reader` — หมายความว่าส่งตรงเข้า PutObject ได้เลยโดยไม่ต้อง buffer ไหม? มีข้อควรระวังอะไรบ้าง?
- `minio.UploadInfo` ที่ return มาจาก PutObject มีข้อมูลอะไรบ้าง? ใช้ verify ว่า upload สำเร็จได้ยังไง?

### Concepts to understand first

- `io.Reader interface`: Go streaming abstraction — `Read(p []byte) (n int, err error)` ทำงานยังไง? ทำไมถึงเรียกว่า "pull-based"?
- `memory allocation`: `[]byte` กับ `io.Reader` allocate memory ต่างกันยังไง? ลองนึกภาพ pipeline ของ bytes จาก network ไป S3

## Task

implement `streamUpload(client, bucket, key, r, size)` ที่:

1. รับ `readable stream` เป็น source ของ bytes — ห้าม buffer ทั้งหมดเข้า memory
2. Upload ไปยัง MinIO/S3 bucket ที่ระบุ ด้วย key ที่กำหนด
3. ใช้ `size` เป็น hint ให้ SDK (ถ้าไม่รู้ size จะใส่ `-1` มาก็ต้องรองรับได้)
4. Return error ถ้า upload ไม่สำเร็จ พร้อม context ที่เพียงพอ

## Requirements

- ห้ามเรียก read-all shortcut, `io.ReadFull`, หรือ read bytes ทั้งหมดเข้า `bytes` ก่อน upload
- ต้องส่ง `readable stream` โดยตรงไปให้ MinIO SDK
- รองรับ `size = -1` (unknown size) — SDK จะจัดการ chunked transfer encoding เอง
- Error message ต้องบอก bucket และ key ที่ fail เช่น `"StreamUpload: bucket/key: connection reset"`
- ห้ามสร้าง temp file บน disk — ทุกอย่างต้องผ่าน memory buffer เล็กๆ ของ SDK

## Acceptance Criteria

- [ ] Upload file ขนาด 1MB ได้ถูกต้อง — content ตรงกับ source byte-for-byte
- [ ] Upload file ขนาด 100MB ได้โดยที่ Go heap ไม่โต (ใช้ `runtime.ReadMemStats` ตรวจ)
- [ ] ส่ง `http.Request.Body` โดยตรงเข้าฟังก์ชันได้โดยไม่ต้อง wrap
- [ ] รองรับ `size = -1` โดยไม่ panic หรือ error
- [ ] ถ้า reader return error กลางคัน — ฟังก์ชัน return error ที่ wrap context ไว้ครบ

## Concepts Involved

- `io.Reader` — Go's streaming interface สำหรับอ่าน bytes ทีละนิด → `shared/concepts/streaming-io.md` (ถ้ามี)
- `PutObject` — MinIO/S3 SDK method สำหรับ upload object
- `memory-efficiency` — ความแตกต่างระหว่าง buffering กับ streaming ในแง่ memory usage

## Production Reality

- **ใช้จริง:** AWS SDK v2 (`s3.PutObjectInput.Body`), MinIO SDK (`PutObject`), GCS (`NewWriter`) ทั้งหมดรองรับ `io.Reader` โดยตรง
- **ทำ manual เมื่อ:** ต้องการ progress tracking, bandwidth throttling, หรือ retry แบบ byte-level
- **size hint:** SDK บางตัวใช้ `size` เพื่อตั้ง `Content-Length` header — ถ้าใส่ผิดอาจ upload ได้บางส่วนหรือ error
- **kata สอนว่า:** signature ที่รับ `io.Reader` แทน `[]byte` เป็น API design decision ที่มีผลกระทบใหญ่มากต่อ scalability — เปลี่ยนทีหลังยาก เพราะ caller ทั้งหมดต้องเปลี่ยนตาม
