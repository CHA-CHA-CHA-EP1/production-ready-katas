---
tier: cloud-storage
difficulty: 1
concepts: [presigned-url, direct-upload, bandwidth-cost, oom-prevention, s3-compatible]
---

# Kata: Presigned Upload URL

## Context

เมื่อ user ต้องการ upload ไฟล์ (รูปภาพ, เอกสาร, วิดีโอ) วิธีง่ายที่สุดคือส่งมาที่ backend แล้ว backend relay ไปยัง S3
แต่ pattern นี้มีปัญหาใหญ่: backend กลายเป็น bottleneck ที่ต้อง buffer ทุก byte ของไฟล์ใน memory ก่อนส่งต่อ
แนวทางที่ถูกต้องคือให้ frontend upload ตรงไปยัง S3 โดยใช้ presigned URL — backend แค่ออก URL, ไม่แตะ file content เลย
pattern นี้ทำให้ backend รับ concurrent uploads ได้ไม่จำกัดโดยไม่ OOM

## Real World Incidents

**Incident 1 — Backend OOM จาก image upload (e-commerce platform)**
platform รับ upload product image ผ่าน `multipart/form-data` ที่ backend
ช่วงเปิดตัว seller จำนวนมาก upload รูปพร้อมกัน
Go HTTP server buffer request body ไว้ใน memory ก่อน stream ไปยัง S3
memory พุ่งจาก 200MB เป็น 8GB ใน 3 นาที → OOM kill → service down
แก้โดยเปลี่ยนเป็น presigned URL — backend เหลือใช้ memory แค่ 180MB แม้ upload พร้อมกัน 500 ราย

**Incident 2 — Bandwidth bill พุ่งเพราะ proxy upload (video hosting startup)**
startup proxy upload video ผ่าน backend เพราะง่ายกว่า
เดือนแรกที่ user เพิ่ม bandwidth cost พุ่ง 10x
traffic ผ่าน EC2 ซึ่งคิดเงิน egress — ทั้งๆ ที่ S3-to-S3 transfer ฟรี
เสีย $23,000 ใน 1 เดือนก่อนค้นพบ — presigned URL แก้ปัญหาเพราะ frontend upload ตรง ไม่ผ่าน EC2

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// backend รับ file แล้ว relay ไปยัง S3
func uploadHandler(w http.ResponseWriter, r *http.Request) {
    file, _, _ := r.FormFile("file")
    defer file.Close()
    // buffer ทั้งไฟล์ใน memory ก่อน upload
    data, _ := io.ReadAll(file)
    client.PutObject(ctx, bucket, key, bytes.NewReader(data), int64(len(data)), opts)
}
```

**พังตอนไหน:**
- user 100 คน upload พร้อมกัน แต่ละคน upload ไฟล์ 50MB → backend ใช้ RAM 5GB แค่สำหรับ buffer
- video upload 2GB บน connection ช้า → request ค้างอยู่ใน HTTP handler 10+ นาที กิน goroutine
- เสียค่า EC2 bandwidth สองเท่า — ขาเข้าจาก user + ขาออกไปยัง S3

**Root cause:**
Backend ไม่ควรเป็นคนกลางสำหรับ file content — มันเพิ่ม latency, เพิ่ม cost, และกิน memory โดยไม่จำเป็น
S3 ออกแบบมาให้รับ upload โดยตรงจาก client ได้อยู่แล้ว ผ่าน presigned URL ที่มี temporary credentials ฝังอยู่

## Explore First

### Go

ก่อนเขียน code ให้เปิด SDK แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `client.PresignedPutObject(ctx, bucket, key string, expiry time.Duration)` — return type คืออะไร? `*url.URL` มี field อะไรที่เกี่ยวข้อง?
- hint: `url.URL.String()` — ทำอะไร? เมื่อไหร่ที่ควร return string แทน `*url.URL`?
- expiry duration — ค่า min/max ของ S3 presigned URL คือเท่าไหร่? ถ้าส่ง expiry เกิน 7 วันจะเกิดอะไร?
- presigned URL มี credentials ฝังอยู่ใน query string — ถ้า URL หลุดออกไปจะเกิดอะไร? ทำไม expiry ถึงสำคัญ?
- frontend จะ upload ด้วย presigned URL ยังไง? HTTP method อะไร? header อะไรที่ต้องใส่?
- ถ้า client ส่ง PUT request ไปยัง presigned URL หลัง expiry จะได้รับ HTTP status อะไร?

## Task

เขียนฟังก์ชัน `GenerateUploadURL(client *minio.Client, bucket, key string, expiry time.Duration) (string, error)` ที่:

1. generate presigned PUT URL สำหรับ upload object ไปยัง S3-compatible storage
2. URL ต้องใช้งานได้โดยตรงจาก frontend โดยไม่ต้องผ่าน backend อีกครั้ง
3. return URL เป็น string พร้อมใช้

## Requirements

- ใช้ `PresignedPutObject` ไม่ใช่ `PutObject` — ต่างกันตรงที่อันนึง sign URL, อีกอันทำ upload จริง
- validate `expiry` ต้องอยู่ในช่วงที่ S3 รองรับ (1 วินาที ถึง 7 วัน) — return error ถ้าอยู่นอกช่วง
- validate `bucket` และ `key` ต้องไม่เป็น empty string
- return error ที่บอก context ได้ว่าพังตรงไหน

## Acceptance Criteria

- [ ] return URL ที่ frontend ใช้ PUT request upload ไฟล์ได้สำเร็จ
- [ ] URL expire หลังจาก expiry duration ที่กำหนด
- [ ] expiry = 0 หรือ expiry เกิน 7 วัน → return error
- [ ] bucket หรือ key เป็น empty string → return error
- [ ] URL ที่ return มี scheme, host, path, และ query string ที่มี signature

## Concepts Involved

- `presigned-url` — temporary URL ที่มี credential ฝังอยู่, signature algorithm, expiry
- `direct-upload` — client-to-S3 upload pattern, ทำไมถึงดีกว่า proxy
- `bandwidth-cost` — EC2 egress pricing vs S3 direct upload, cost model ต่างกันยังไง
- `oom-prevention` — ทำไม backend ที่ proxy upload ถึง OOM ง่าย, memory amplification

## Production Reality

- **ใช้จริง:** pattern นี้เป็น standard สำหรับทุก web app ที่รับ file upload — React/Vue frontend ขอ URL จาก backend, แล้ว fetch/axios PUT ตรงไปยัง URL นั้น
- **ทำ manual เมื่อ:** ต้องการ validate metadata ก่อน generate URL, หรือต้องการ log ทุก upload attempt
- **kata สอนว่า:** presigned URL ย้าย bandwidth และ compute load ออกจาก backend ไปยัง S3 — backend แค่ออก permission, ไม่แตะ data
