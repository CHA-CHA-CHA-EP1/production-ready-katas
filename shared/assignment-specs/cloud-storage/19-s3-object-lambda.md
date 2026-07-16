---
tier: cloud-storage
difficulty: 3
concepts: [s3-object-lambda, on-demand-transform, write-get-object-response, streaming-transform, pii-redaction]
provider: aws-only
---

# Kata: S3 Object Lambda — Transform on GET

> **Provider:** AWS only — ต้องการ AWS account, IAM permissions, S3 bucket, S3 Object Lambda Access Point, Lambda, และ AWS SDK

## Context

ปัญหาของการ pre-process ไฟล์ทุกอันตอน upload คือ:
- **Wasted work:** ถ้า 70% ของไฟล์ไม่เคยถูกเปิดดู — process ไปทำไม?
- **Rule change:** ถ้าอยากเปลี่ยน watermark หรือ resize dimension — ต้อง reprocess ไฟล์เก่าทุกอัน
- **Multiple variants:** ถ้าต้องการ 5 ขนาด — เก็บ 5 copy ต่อไฟล์หนึ่งอัน = storage ขยาย 5x

S3 Object Lambda แก้ปัญหานี้โดยให้ Lambda intercept `GetObject` request และ transform content แบบ on-demand
ก่อนส่งกลับให้ requester — ไฟล์ต้นฉบับเก็บครั้งเดียว transform เมื่อ request เท่านั้น

use case จริง:
- watermark รูปภาพก่อนส่งให้ user ที่ไม่ได้ subscribe premium
- blur หรือ redact PII ใน document ตาม permission ของ requester
- resize on-demand ตาม device type (mobile/desktop/retina)
- filter log ก่อนส่งให้ partner ที่มี data access จำกัด

## Real World Incidents

**Incident 1 — Pre-process ทุกไฟล์ทำให้ 70% ของ compute เปล่าประโยชน์ (Photo Storage Service, 2021)**
ระบบ generate thumbnail 5 ขนาดทันทีที่ user อัปโหลดรูป
วิเคราะห์พบว่า 70% ของรูปที่อัปโหลดไม่ถูกเปิดดูภายใน 30 วัน
แต่ Lambda ทำ resize 5 ครั้งต่อรูปทุกอัน → เสีย compute + storage ไปกับไฟล์ที่ไม่มีคนดู
เปลี่ยนมาใช้ S3 Object Lambda — resize เมื่อ request จริงเท่านั้น
ลด Lambda invocation 70%, ลด S3 storage 80% (เพราะไม่เก็บ 5 copy)

**Incident 2 — PII รั่วใน log เพราะไม่มี filter บน GET (Log Analytics Platform, 2022)**
ระบบ log aggregation เก็บ application log ใน S3 โดยไม่ redact PII ก่อน
developer บางคนต้องการ access log เพื่อ debug — แต่ log มีทั้ง email, phone number, และ credit card number
ออก access ให้ developer โดยไม่มี filter → PII ออกไปยัง laptop developer
แก้โดยใช้ S3 Object Lambda ที่ intercept GET request และ redact PII pattern ออกก่อนส่งกลับ
developer ยังอ่าน log ได้ แต่ PII ถูก mask เป็น `***`

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// Pre-process ทุกไฟล์ตอน upload
func HandleUpload(ctx context.Context, event events.S3Event) error {
    for _, record := range event.Records {
        original := downloadOriginal(record.S3.Object.Key)

        // generate ทุก variant ทันที (ทำทิ้งไว้แม้ไม่มีคนดู)
        thumbnail := resize(original, 200, 200)
        medium := resize(original, 800, 600)
        large := resize(original, 1920, 1080)
        withWatermark := addWatermark(original, "© MyService")

        // เก็บทุก variant
        upload("thumb/" + key, thumbnail)
        upload("medium/" + key, medium)
        upload("large/" + key, large)
        upload("watermarked/" + key, withWatermark)
    }
}
```

**พังตอนไหน:**
- 70% ของไฟล์ไม่ถูกเปิดดู — compute + storage เปล่าประโยชน์
- อยากเปลี่ยน watermark text → ต้อง reprocess ไฟล์เก่าหลายล้านไฟล์
- เพิ่ม variant ใหม่ (เช่น WebP) → ต้อง backfill ไฟล์ทั้งหมด
- storage ขยาย 4-5x ของ original

**Root cause:**
Eager pre-processing ทำทุกอย่างล่วงหน้า โดยไม่รู้ว่า requester ต้องการอะไรจริงๆ
Lazy on-demand transform คิดค่าใช้จ่ายเฉพาะสิ่งที่ถูกขอ

## Explore First

### AWS SDK (Go)
ก่อนเขียน code ให้เปิด AWS SDK docs แล้วตอบคำถามเหล่านี้ก่อน

- hint: `s3.WriteGetObjectResponse` — นี่คือ API ที่ unique กับ S3 Object Lambda เท่านั้น — รับ parameters อะไรบ้าง? `RequestRoute` และ `RequestToken` มาจากไหน?
- hint: `events.S3ObjectLambdaEvent` จาก `github.com/aws/aws-lambda-go/events` — field อะไรบอก presigned URL ของ original object? ใช้ URL นี้ทำอะไร?
- hint: `GetObjectContext.InputS3URL` — คือ presigned URL ของ original — ต้อง fetch ด้วย standard HTTP client ไม่ใช่ S3 client
- `WriteGetObjectResponse` รับ `Body io.Reader` — สามารถ stream ผลลัพธ์ออกไปโดยไม่ buffer ใน memory ได้ไหม?
- ถ้า Lambda error ระหว่าง `WriteGetObjectResponse` — S3 requester จะเห็น error อะไร? behavior ต่างจาก Lambda ที่ไม่เรียก `WriteGetObjectResponse` เลยยังไง?
- S3 Object Lambda Access Point ต่างจาก S3 Access Point ปกติยังไง? ต้อง configure อะไรเพิ่ม?

## Task

เขียน Lambda function สำหรับ on-demand image watermarking ผ่าน S3 Object Lambda:

```
transformOnGet(ctx, event) → error
```

ฟังก์ชันต้องทำตามขั้นตอน:
1. อ่าน presigned URL ของ original object จาก event (`GetObjectContext.InputS3URL`)
2. fetch original image จาก URL นั้นด้วย HTTP client
3. เพิ่ม watermark text ที่มุมล่างขวาของรูป (ข้อความ: `© MyService` สีขาวพร้อม shadow สีดำ)
4. ส่ง transformed image กลับด้วย `WriteGetObjectResponse`

เพิ่มเติม — เขียน helper:

```
// addWatermark เพิ่ม text watermark ที่มุมล่างขวา
addWatermark(src, text) → readable stream, , error
// return: watermarked image reader, content-type, error

// fetchOriginal fetch image จาก presigned URL
fetchOriginal(ctx, presignedURL) → io.ReadCloser, error
```

## Requirements

- ต้อง fetch original ผ่าน presigned URL โดยใช้ standard HTTP client — ไม่ใช่ S3 SDK client
- watermark ต้องปรากฏชัดเจนและอ่านได้บน background ทั้งสว่างและมืด (ใช้ shadow หรือ outline)
- ถ้า original ไม่ใช่รูปภาพ → เรียก `WriteGetObjectResponse` พร้อม error status code 415 Unsupported Media Type
- ต้องเรียก `WriteGetObjectResponse` เสมอ แม้เกิด error — Lambda ที่ไม่เรียกจะทำให้ requester ค้างตลอด
- log แสดง original size, output size, processing duration
- ห้าม buffer ทั้งไฟล์ใน memory ถ้าเป็นไปได้ — ใช้ streaming pipeline

## Acceptance Criteria

- [ ] GET object ผ่าน S3 Object Lambda Access Point → ได้รูปที่มี watermark "© MyService"
- [ ] GET object ตรงผ่าน S3 bucket ปกติ → ได้รูป original ไม่มี watermark
- [ ] watermark ปรากฏที่มุมล่างขวา อ่านได้ชัดเจนบน background สีต่างๆ
- [ ] ส่ง non-image file → Lambda return 415 error ผ่าน `WriteGetObjectResponse` — requester ได้ error response ไม่ใช่ hang
- [ ] Lambda ไม่เก็บ intermediate file ใน S3 — transform เกิดใน-memory pipeline เท่านั้น
- [ ] log แสดง original size และ output size ทุก invocation

## Concepts Involved

- `s3-object-lambda` — intercept S3 `GetObject` request ด้วย Lambda — transform on-demand แทน pre-compute
- `on-demand-transform` — คิดค่าใช้จ่ายเฉพาะสิ่งที่ถูกขอ — lazy evaluation สำหรับ object storage
- `write-get-object-response` — API เฉพาะของ Object Lambda — Lambda ส่ง response กลับผ่าน S3 infrastructure ไม่ใช่ API Gateway
- `streaming-transform` — pipe จาก HTTP fetch → decode → transform → encode → response โดยไม่ buffer ใน memory ทั้งหมด
- `pii-redaction` — use case สำคัญของ Object Lambda — filter sensitive data ก่อนส่งให้ requester ที่มี permission จำกัด

## Production Reality

- **ใช้จริง:** Canva ใช้ concept คล้ายกันสำหรับ on-demand image resize — Cloudflare Images และ imgix ให้ service ระดับ CDN
- **caching:** S3 Object Lambda ไม่ cache ผลลัพธ์อัตโนมัติ — ถ้า transform แพงควรใช้ CloudFront cache response ก่อนถึง Object Lambda
- **cost model:** ถ้า cache hit rate สูง (เช่น thumbnail ถูก request ซ้ำบ่อย) → pre-compute อาจถูกกว่า on-demand
- **kata สอนว่า:** เลือกระหว่าง eager vs lazy transform โดยดูที่ access pattern — รูปที่ 70% ไม่เคยถูกดู = lazy ดีกว่า, รูปที่ทุกคนดูทุกวัน = pre-compute ดีกว่า
