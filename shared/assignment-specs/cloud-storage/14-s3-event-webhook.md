---
tier: cloud-storage
difficulty: 2
concepts: [s3-event-notifications, webhook-handler, idempotency, source-of-truth, event-driven]
provider: aws-only
---

# Kata: S3 Event Notification + Webhook Handler

> **Provider:** AWS only — ต้องการ AWS account, IAM permissions, S3 bucket, และ AWS SDK

## Context

pattern ที่พบบ่อยใน file upload workflow คือ:
1. client อัปโหลดไฟล์ไปยัง S3
2. client บอก backend ว่า "อัปโหลดเสร็จแล้ว"
3. backend ทำ post-processing

ปัญหาของ pattern นี้คือ **client เป็น source of truth** — ซึ่งไม่ควรเป็น

Client อาจ crash หลังอัปโหลด, อาจส่ง notification ซ้ำ, หรือแม้แต่โกหกเกี่ยวกับ file ที่อัปโหลด
(เช่น บอกว่าอัปโหลดไฟล์ขนาด 1MB แต่จริงๆ อัปโหลด 100MB)

วิธีที่ถูกต้องคือให้ **S3 เป็น source of truth** — ใช้ S3 Event Notification ให้ S3 notify backend
เองตอนที่ object ถูกสร้าง แทนที่จะรอ client บอก

## Real World Incidents

**Incident 1 — Ghost uploads ทำให้ process ไฟล์ที่ไม่มีอยู่จริง (SaaS File Platform, 2020)**
ระบบรับ notification จาก client ว่า "อัปโหลดเสร็จ" แล้วเริ่ม pipeline ทันที
บาง client crash ระหว่างอัปโหลด แต่ thread แยกต่างหากยังส่ง "upload done" notification ได้
backend เริ่ม pipeline ไปดึงไฟล์จาก S3 แต่ไม่เจอ — 404
ระบบ retry ซ้ำ 3 ครั้งแล้ว fail เงียบ — user ไม่รู้ว่าไฟล์ไม่ขึ้นระบบ
แก้โดยเปลี่ยนมาใช้ S3 Event Notification และ verify object existence ก่อนทุกครั้ง

**Incident 2 — Client รายงานขนาดไฟล์ผิด ทำให้ billing คำนวณผิด (Storage Service, 2021)**
ระบบ billing คิดค่า storage ตาม file size ที่ client report ใน API call
ตรวจพบว่า client บางรายส่ง size เป็น 0 ทุกครั้ง (bug ใน mobile app)
ทำให้ storage ฟรีสำหรับ user กลุ่มนั้น นานหลายเดือนก่อนตรวจพบ
แก้โดยให้ S3 Event บอก actual object size จาก `s3:ObjectCreated` event แทน client report

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// client เรียก API นี้หลังอัปโหลดเสร็จ
func (h *Handler) NotifyUploadDone(w http.ResponseWriter, r *http.Request) {
    var req struct {
        Bucket   string `json:"bucket"`
        Key      string `json:"key"`
        FileSize int64  `json:"file_size"`
    }
    json.NewDecoder(r.Body).Decode(&req)
    // เชื่อ client ไปเลย
    processFile(req.Bucket, req.Key, req.FileSize)
}
```

**พังตอนไหน:**
- Client crash หลังอัปโหลดแต่ก่อน notify → backend ไม่รู้ว่ามีไฟล์ใหม่
- Client notify ซ้ำ 2 ครั้ง (retry) → process ไฟล์เดิม 2 ครั้ง
- Client ส่ง key ผิด → backend ไป process ไฟล์คนอื่น
- Client โกหก file_size → billing/quota ผิด

**Root cause:**
Client ไม่ใช่ source of truth สำหรับ file storage
S3 รู้ดีที่สุดว่า object ไหน exists, ขนาดเท่าไหร่, เมื่อกี่โมง — ควรให้ S3 drive event

## Explore First

### AWS SDK (Go)
ก่อนเขียน code ให้เปิด AWS SDK docs แล้วตอบคำถามเหล่านี้ก่อน

- hint: `s3.PutBucketNotificationConfiguration` — input struct มี field อะไรบ้าง? `NotificationConfiguration` configure อะไรได้บ้าง?
- hint: `types.LambdaFunctionConfiguration` vs `types.QueueConfiguration` vs `types.TopicConfiguration` — เลือกใช้อันไหนเมื่อไหร่?
- hint: `events.S3Event` จาก `github.com/aws/aws-lambda-go/events` — struct มี field อะไร? `S3Entity.Object.Size` มาจากไหน? เชื่อได้ไหม?
- hint: `s3.HeadObject` — ใช้ทำอะไร? ต่างจาก `GetObject` ยังไงในแง่ cost และ performance?
- S3 Event มี event type อะไรบ้างในกลุ่ม `s3:ObjectCreated`? ต่างกันยังไง?
- ถ้า Lambda timeout ระหว่าง process event — S3 จะ retry ไหม? retry กี่ครั้ง? ทำให้เกิดปัญหาอะไร?

## Task

**ส่วนที่ 1 — Setup Notification:**
เขียนฟังก์ชัน `SetupBucketNotification` ที่ configure S3 bucket ให้ส่ง event ไปยัง Lambda:

```go
func SetupBucketNotification(
    ctx context.Context,
    s3Client *s3.Client,
    bucket string,
    lambdaARN string,
    prefix string, // filter เฉพาะ prefix นี้ เช่น "uploads/"
) error
```

**ส่วนที่ 2 — Event Handler:**
เขียน Lambda handler ที่รับ S3 event แล้วทำ post-processing:

```go
func HandleS3Event(ctx context.Context, event events.S3Event) error
```

handler ต้อง:
1. วน loop ผ่านทุก record ใน event
2. ดึง object metadata จาก S3 ด้วย `HeadObject` (verify ว่า object จริงๆ exists)
3. log actual size จาก S3 (ไม่ใช่จาก event) เพื่อ audit
4. ทำงานแบบ idempotent — ถ้า event เดิมมาซ้ำต้องไม่ process ซ้ำ

## Requirements

- `SetupBucketNotification` ต้อง configure filter ตาม prefix — ไม่ trigger ทุก object ใน bucket
- `HandleS3Event` ต้อง verify object existence ด้วย `HeadObject` ก่อนทุกครั้ง — ไม่เชื่อ event อย่างเดียว
- ต้องทนต่อ event ซ้ำ (idempotent) — ถ้า Lambda ถูก invoke ด้วย event เดิมสองครั้ง ผลต้องเหมือนกัน
- error ใน record หนึ่งต้องไม่หยุด processing ของ record อื่น — log error แล้ว continue
- ต้อง log `ETag`, `Size`, และ `LastModified` จาก `HeadObject` response — ไม่ใช่จาก event

## Acceptance Criteria

- [ ] `SetupBucketNotification` configure notification ที่ filter เฉพาะ prefix ที่กำหนดได้
- [ ] อัปโหลดไฟล์ไปยัง prefix ที่กำหนด → Lambda ถูก invoke อัตโนมัติ
- [ ] อัปโหลดไฟล์นอก prefix → Lambda ไม่ถูก invoke
- [ ] `HandleS3Event` เรียก `HeadObject` เพื่อ verify ก่อนทุกครั้ง — ไม่ trust event payload อย่างเดียว
- [ ] ถ้า `HeadObject` return 404 (object ถูกลบก่อน Lambda ทำงาน) → log warning แล้ว skip — ไม่ panic
- [ ] invoke event เดิม 2 ครั้ง → ไม่ error, ผลลัพธ์เหมือนกัน (idempotent)
- [ ] log แสดง actual size จาก S3 ไม่ใช่จาก event payload

## Concepts Involved

- `s3-event-notifications` — S3 สามารถ publish event ไปยัง Lambda, SQS, หรือ SNS เมื่อ object state เปลี่ยน
- `source-of-truth` — S3 รู้ข้อมูล object ที่ถูกต้องที่สุด — ควรอ่านจาก S3 ไม่ใช่เชื่อ client
- `idempotency` — Lambda อาจถูก invoke ซ้ำเพราะ at-least-once delivery — handler ต้องทนต่อ duplicate
- `event-driven` — ระบบ react ต่อ event จาก S3 แทนที่จะ poll หรือรอ client — decoupled และ reliable มากกว่า
- `head-object` — lightweight operation ที่ดึงแค่ metadata ไม่ดึง body — ใช้สำหรับ verify existence และขนาด

## Production Reality

- **ใช้จริง:** ระบบ document processing, image pipeline, และ ETL ส่วนใหญ่ใช้ S3 Event เป็น trigger
- **at-least-once:** S3 Event Notification มี at-least-once delivery — ออกแบบ handler ให้ idempotent เสมอ
- **ordering:** S3 ไม่รับประกัน event ordering — ถ้า process ต้องการ order ต้องใช้ SQS FIFO แทน
- **kata สอนว่า:** อย่าให้ client เป็น source of truth สำหรับ storage events — S3 รู้ดีกว่าเสมอ
