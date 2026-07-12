---
tier: cloud-storage
difficulty: 3
concepts: [pipeline-status-tracking, dynamodb-status, sns-notification, event-chain, observability]
provider: aws-only
---

# Kata: Multi-Step Pipeline with Status Tracking

> **Provider:** AWS only — ต้องการ AWS account, IAM permissions, S3, Lambda, DynamoDB, SNS, และ AWS SDK

## Context

ระบบ upload หลายชั้น (validate → transform → store → notify) มีปัญหาที่พบบ่อยคือ:
user รู้แค่ว่า "อัปโหลดสำเร็จ" แต่ไม่รู้ว่าขั้นตอนหลังจากนั้นเป็นอย่างไร

ถ้าไม่มี status tracking:
- user ไม่รู้ว่าไฟล์กำลัง process, process เสร็จแล้ว, หรือ process fail
- support ต้องไปเช็ค log ด้วยมือทุกครั้งที่มี ticket
- engineer ไม่รู้ว่า pipeline ติดอยู่ที่ step ไหน

pattern ที่ดีคือแต่ละ step ใน pipeline เขียน status ลง DynamoDB และ publish event ไปยัง SNS
ทำให้ทั้ง user และ engineer รู้สถานะแบบ real-time

## Real World Incidents

**Incident 1 — Users ไม่รู้ว่า upload "ค้าง" อยู่ที่ step ไหน (Document Platform, 2021)**
ระบบรับ upload PDF แล้วส่งผ่าน 3 step: OCR → extract metadata → index for search
pipeline ใช้เวลา 2-5 นาทีต่อไฟล์
user เห็น "Upload Complete" แต่ search ยังไม่เจอไฟล์
support ticket ท่วม: "ทำไม upload แล้วหาไม่เจอ?"
engineer ต้องเปิด CloudWatch log ทีละ step เพื่อหาว่าไฟล์ติดอยู่ที่ไหน
แก้โดยเพิ่ม DynamoDB status table และ UI แสดง progress แบบ real-time

**Incident 2 — Pipeline fail เงียบ ไม่มี alert (Media Processing, 2022)**
ขั้นตอน video transcode เกิด OOM crash เพราะไฟล์ใหญ่เกินไป
Lambda crash โดยไม่เขียน status ใดๆ ลง DB
ผล: status ยังค้างอยู่ที่ "processing" ตลอดไป — ไม่มีใครรู้ว่า fail
user รอนานหลายชั่วโมงก่อนจะ raise ticket
แก้โดยเพิ่ม `defer` ใน Lambda handler ที่เขียน `failed` status ถ้า function panic

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// user ถาม status โดย poll S3 ตรงๆ
func (h *Handler) CheckStatus(w http.ResponseWriter, r *http.Request) {
    key := r.URL.Query().Get("key")
    // เช็คว่าไฟล์ exist ใน S3 ไหม
    _, err := s3Client.HeadObject(ctx, &s3.HeadObjectInput{
        Bucket: &bucket,
        Key:    &key,
    })
    if err != nil {
        json.NewEncoder(w).Encode(map[string]string{"status": "processing"})
        return
    }
    json.NewEncoder(w).Encode(map[string]string{"status": "done"})
}
```

**พังตอนไหน:**
- ไม่รู้ว่า "processing" หมายถึงกำลังทำ step ไหน หรือ fail ไปแล้วแต่ยังไม่รู้
- S3 object exists ≠ pipeline เสร็จ — อาจแค่ผ่าน step แรก
- ไม่มีทางรู้ว่า fail ที่ step ไหน หรือ error อะไร
- ถ้า pipeline มี 5 step — user เห็นแค่ "ยังไม่เสร็จ" ตลอด

**Root cause:**
S3 object existence เป็น binary state (exists/not exists) — ไม่มี "กำลัง process step 3/5"
ต้องการ dedicated status store ที่แต่ละ step เขียนสถานะของตัวเอง

## Explore First

### AWS SDK (Go)
ก่อนเขียน code ให้เปิด AWS SDK docs แล้วตอบคำถามเหล่านี้ก่อน

- hint: `dynamodb.PutItem` — เขียน item ลง DynamoDB — `AttributeValue` type มีอะไรบ้าง? ใช้ `attributevalue.MarshalMap` แทน manual marshal ได้ไหม?
- hint: `dynamodb.UpdateItem` — update แบบ partial — `UpdateExpression` เขียนยังไง? ต่างจาก `PutItem` (ที่ overwrite ทั้งหมด) ยังไง?
- hint: `sns.Publish` — publish message ไปยัง topic — `Message` field รับ JSON string ได้ไหม? `Subject` ใช้ทำอะไร?
- hint: `dynamodb.GetItem` — ใช้ query status — `ConsistentRead` option ทำอะไร? ทำไม eventually consistent อาจพอสำหรับ status query?
- DynamoDB TTL คืออะไร? ใช้ auto-delete status record เก่าได้ยังไง? ตั้ง TTL ที่ field ไหน?
- ถ้าต้องการ query status ทุก job ของ user คนหนึ่ง (ไม่ใช่แค่ jobID เดียว) — DynamoDB schema ควรออกแบบยังไง? GSI ช่วยได้ไหม?

## Task

**ส่วนที่ 1 — Status updater:**
```go
func UpdateStatus(
    ctx context.Context,
    client *dynamodb.Client,
    jobID string,
    status string, // "pending", "validating", "transforming", "completed", "failed"
    meta map[string]string, // additional info เช่น error message, output key
) error
```

**ส่วนที่ 2 — S3 trigger handler พร้อม status tracking:**
```go
func ProcessWithStatus(ctx context.Context, event events.S3Event) error
```

handler ต้อง:
1. เขียน status `validating` ลง DynamoDB ตั้งแต่ต้น
2. validate object (ตรวจ file type, size)
3. เขียน status `transforming`
4. ทำ transform (สำหรับ kata ให้ copy file ไปยัง `processed/` prefix พร้อม metadata)
5. เขียน status `completed` พร้อม output key ใน meta
6. publish SNS notification ว่า job เสร็จ
7. ถ้าเกิด error ทุก step → เขียน status `failed` พร้อม error message ใน meta

**ส่วนที่ 3 — Status reader:**
```go
func GetJobStatus(
    ctx context.Context,
    client *dynamodb.Client,
    jobID string,
) (*JobStatus, error)

type JobStatus struct {
    JobID     string
    Status    string
    Meta      map[string]string
    UpdatedAt time.Time
}
```

## Requirements

- DynamoDB table schema: partition key = `jobID` (string)
- ทุก `UpdateStatus` call ต้อง set `updatedAt` timestamp ด้วย
- `failed` status ต้องมี `errorMessage` ใน meta — ไม่ใช่แค่ status string
- SNS notification ต้อง publish เฉพาะตอน `completed` หรือ `failed` — ไม่ publish ทุก status change
- ใช้ `defer` เพื่อ catch panic และเขียน `failed` status — Lambda panic ต้องไม่ทำให้ status ค้างที่ `validating`
- TTL ของ status record ควรตั้งที่ 7 วัน — เขียน TTL ลงใน DynamoDB record ด้วย

## Acceptance Criteria

- [ ] อัปโหลดไฟล์ → DynamoDB มี record ที่มี status ตาม sequence: `pending` → `validating` → `transforming` → `completed`
- [ ] `GetJobStatus` return status ล่าสุดพร้อม `updatedAt` timestamp
- [ ] pipeline ที่ fail → status เป็น `failed` พร้อม `errorMessage` ใน meta — ไม่ค้างที่ `validating`
- [ ] SNS notification ถูก publish เมื่อ status เป็น `completed` หรือ `failed`
- [ ] Lambda panic → `defer` catch และเขียน `failed` status ได้
- [ ] DynamoDB record มี TTL attribute ที่ตั้งค่าถูกต้อง (7 วันจากเวลา create)

## Concepts Involved

- `pipeline-status-tracking` — แต่ละ step ใน pipeline เขียน status ของตัวเอง — ทำให้ observe ได้ทุก step
- `dynamodb-status` — DynamoDB เหมาะสำหรับ status store เพราะ low latency, schemaless, และ TTL support
- `sns-notification` — publish completion event ให้ subscriber หลายอัน (email, webhook, mobile push) จาก event เดียว
- `event-chain` — S3 event → Lambda → DynamoDB + SNS — แต่ละ step produce event สำหรับ step ถัดไป
- `observability` — status tracking ทำให้ทั้ง user และ engineer รู้ว่าเกิดอะไรขึ้นใน pipeline — ลด support ticket

## Production Reality

- **ใช้จริง:** AWS Step Functions เป็น managed service สำหรับ pattern นี้ — handle retry, error state, และ visual workflow ให้
- **Step Functions vs custom:** ใช้ Step Functions ถ้า workflow ซับซ้อนมีหลาย branch — ใช้ Lambda + DynamoDB ถ้า workflow ตรงไปตรงมาและต้องการ control เต็มที่
- **status polling vs websocket:** user check status ได้ทั้ง polling API และ WebSocket push — DynamoDB stream + API Gateway WebSocket เป็น pattern ยอดนิยม
- **kata สอนว่า:** "upload สำเร็จ" ไม่ใช่ end state ของ pipeline — status tracking ทำให้ pipeline observable และ debuggable จากภายนอก
