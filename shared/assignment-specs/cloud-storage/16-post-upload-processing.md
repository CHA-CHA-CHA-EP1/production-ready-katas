---
tier: cloud-storage
difficulty: 2
concepts: [async-processing, s3-trigger, image-processing, s3manager, lambda-pipeline]
provider: aws-only
---

# Kata: Post-Upload Processing via S3 Trigger

> **Provider:** AWS only — ต้องการ AWS account, IAM permissions, S3 bucket, Lambda, และ AWS SDK

## Context

หลาย application ต้องทำ processing หลัง user อัปโหลดไฟล์ เช่น:
- resize รูปภาพให้เป็น thumbnail
- compress video ให้เล็กลง
- extract metadata จาก PDF
- generate preview

วิธี naive คือทำทุกอย่างใน HTTP handler เดียวกับที่รับ upload — synchronously
แต่การ process ไฟล์ใหญ่ใน HTTP handler มีปัญหาหลัก: **timeout**

HTTP request มี timeout (เช่น 30 วินาที, 60 วินาที) — ถ้า process ไม่เสร็จภายในเวลาที่กำหนด
connection ถูก drop และ user ได้รับ error ทั้งๆ ที่ไฟล์อาจยังถูก process ต่อใน background

วิธีที่ถูกต้องคือแยก upload และ processing ออกจากกัน:
upload เสร็จ → S3 trigger → Lambda ทำ processing แบบ async

## Real World Incidents

**Incident 1 — Image resize timeout ทำให้ upload ล้มเหลวซ้ำๆ (E-commerce Platform, 2020)**
ระบบ product listing รับภาพสินค้า แล้ว resize เป็น 4 ขนาด (thumbnail, small, medium, large) ใน HTTP handler เดียว
สินค้าบางชิ้น seller upload ภาพ RAW ขนาด 45MB
resize กินเวลา 75 วินาที — load balancer ตัด connection หลัง 60 วินาที
seller เห็น error "Upload Failed" ทั้งๆ ที่ไฟล์ขึ้น S3 ครบ
seller กด upload ซ้ำ — ได้ภาพซ้ำใน S3 จำนวนมาก
แก้โดยแยก resize ออกไปเป็น async Lambda trigger จาก S3 event

**Incident 2 — Synchronous video transcode block ทุก request (Video Platform, 2021)**
ทีมพัฒนา video upload feature แล้วใส่ ffmpeg transcode ใน HTTP handler
ช่วง peak upload เวลา 20.00-22.00 น. มีคน upload พร้อมกัน 500 คน
server thread หมดเพราะแต่ละ request block รอ ffmpeg นาน 2-5 นาที
ผล: request ทุกอย่าง (ไม่ใช่แค่ upload) ช้าลงเพราะ thread pool หมด
ต้องรีบ rollback feature และ redesign ใหม่ด้วย async processing

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
func (h *Handler) UploadImage(w http.ResponseWriter, r *http.Request) {
    // 1. receive upload
    data, _ := io.ReadAll(r.Body)

    // 2. process ทันทีใน HTTP handler (ปัญหา!)
    thumbnail, _ := generateThumbnail(data) // อาจใช้เวลานาน
    resized, _ := resizeImage(data, 800, 600)

    // 3. save ทุกอัน
    s3.PutObject(ctx, &s3.PutObjectInput{Key: "original/" + key, Body: data})
    s3.PutObject(ctx, &s3.PutObjectInput{Key: "thumb/" + key, Body: thumbnail})
    s3.PutObject(ctx, &s3.PutObjectInput{Key: "medium/" + key, Body: resized})

    w.WriteHeader(http.StatusOK) // อาจไม่ถึงบรรทัดนี้ถ้า timeout
}
```

**พังตอนไหน:**
- ไฟล์ใหญ่ → HTTP timeout ก่อน processing เสร็จ
- หลาย request พร้อมกัน → goroutine/thread หมด, server ช้าทั้งระบบ
- processing fail ครึ่งทาง → upload "สำเร็จ" แต่ thumbnail ไม่มี
- retry ทำให้ process ซ้ำ — ไม่มี idempotency

**Root cause:**
HTTP handler ถูกออกแบบมาสำหรับ short-lived request-response cycle
งาน compute-heavy ไม่ควรอยู่ใน HTTP handler — ต้องแยกออกไปเป็น async job

## Explore First

### AWS SDK (Go)
ก่อนเขียน code ให้เปิด AWS SDK docs แล้วตอบคำถามเหล่านี้ก่อน

- hint: `events.S3Event` และ `events.S3EventRecord` — field อะไรบอก bucket name, object key, และ object size?
- hint: `s3.GetObject` — return `*s3.GetObjectOutput` ซึ่งมี `Body io.ReadCloser` — ต้อง close ยังไง? เมื่อไหร่?
- hint: `manager.NewUploader(client)` จาก `github.com/aws/aws-sdk-go-v2/feature/s3/manager` — ต่างจาก `s3.PutObject` ยังไง? เมื่อไหรถึงจะใช้?
- hint: `manager.Upload` — ใช้ `io.Reader` เป็น input — สามารถ pipe จาก image processing ตรงๆ ได้ไหม? ดีกว่า buffer ใน memory ยังไง?
- `image` package ใน Go standard library decode รูปได้รูปแบบไหนบ้าง? JPEG, PNG, WebP? ต้อง import อะไรเพิ่ม?
- Lambda timeout เริ่ม count จากตอนไหน? ถ้า download ใหญ่ + process นาน + upload ซ้ำ — estimate timeout ที่เหมาะสมคือเท่าไหร่?

## Task

เขียน Lambda function ที่ triggered จาก S3 event แล้วทำ image processing:

```
processUpload(ctx, event) → error
```

ฟังก์ชันต้องทำตามขั้นตอน:
1. loop ผ่านทุก record ใน event
2. download original image จาก `uploads/` prefix
3. generate thumbnail ขนาด 200x200 px
4. generate medium size ขนาด 800x600 px
5. upload ทั้งสองขนาดไปยัง `processed/thumb/` และ `processed/medium/` prefix ตามลำดับ
6. log duration ของแต่ละ step

เพิ่มเติม — เขียน helper:

```
resizeImage(src, width, height) → readable stream, error
```

## Requirements

- ต้อง stream ข้อมูลถ้าเป็นไปได้ — หลีกเลี่ยงการ load ไฟล์ทั้งหมดเข้า memory ถ้าทำได้
- ถ้า record หนึ่ง fail → log error แล้วทำ record ถัดไปต่อ — ไม่หยุดทั้งหมด
- output key ต้องสัมพันธ์กับ input key เช่น `uploads/photo.jpg` → `processed/thumb/photo.jpg`
- ต้อง log ขนาดไฟล์ original และ output พร้อม duration ของแต่ละ step
- ถ้า original ไม่ใช่รูปภาพ (decode fail) → log warning แล้ว skip — ไม่ return error

## Acceptance Criteria

- [ ] อัปโหลดรูปไปที่ `uploads/` prefix → Lambda ถูก trigger และ generate thumbnail + medium size
- [ ] `processed/thumb/{key}` และ `processed/medium/{key}` ถูกสร้างใน S3
- [ ] thumbnail มีขนาด 200x200 px (หรือ maintain aspect ratio จนถึง 200px ด้านใดด้านหนึ่ง)
- [ ] medium มีขนาดไม่เกิน 800x600 px
- [ ] อัปโหลดไฟล์ที่ไม่ใช่รูปภาพ → Lambda log warning แต่ไม่ return error
- [ ] log แสดง original size, output size, และ duration ของ download/process/upload แยกกัน
- [ ] ถ้า record หนึ่งมี object ที่ถูกลบไปแล้ว → skip gracefully ไม่ crash Lambda

## Concepts Involved

- `async-processing` — แยก upload และ processing ออกจากกัน — HTTP handler return ทันที, Lambda ทำงานหลัง event
- `s3-trigger` — S3 Event Notification เป็น mechanism ที่ fire Lambda เมื่อ object ถูกสร้าง
- `image-processing` — resize, thumbnail generation ใน Go ด้วย `image` package
- `s3manager` — AWS SDK uploader ที่รองรับ multipart upload อัตโนมัติ — ดีกว่า `PutObject` สำหรับไฟล์ใหญ่
- `streaming-pipeline` — pipe จาก download → decode → resize → encode → upload โดยไม่ต้องเก็บทั้งหมดใน memory

## Production Reality

- **ใช้จริง:** Instagram, Cloudinary, และ image-heavy platform ทุกเจ้าใช้ async image processing pipeline
- **format support:** production ควรรองรับ WebP output — file size เล็กกว่า JPEG/PNG 25-30% — ต้องใช้ library นอก stdlib
- **fan-out:** หนึ่ง S3 event สามารถ trigger หลาย Lambda function พร้อมกันได้ด้วย SNS fan-out
- **kata สอนว่า:** งาน compute-heavy ต้องออกจาก HTTP handler เสมอ — async trigger ทำให้ scale ได้และ timeout-safe
