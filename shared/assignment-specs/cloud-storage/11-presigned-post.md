---
tier: cloud-storage
difficulty: 2
concepts: [presigned-post, upload-policy, content-type-validation, size-limit, storage-abuse-prevention]
---

# Kata: Presigned POST with Policy

## Context

presigned PUT URL (kata 09) ให้ user upload ไฟล์ตรงไปยัง S3 ได้ แต่ไม่มีข้อจำกัดใดๆ จาก server side
user ที่ได้รับ PUT URL สามารถ upload ไฟล์ขนาดเท่าไหร่ก็ได้ content type อะไรก็ได้ key ชื่ออะไรก็ได้
ปัญหานี้แก้ด้วย presigned POST ที่แนบ policy document — S3 enforce ข้อจำกัดก่อน accept upload
policy ระบุได้ว่า: upload ได้แค่ key ที่ขึ้นต้นด้วย prefix ที่กำหนด, ขนาดไม่เกิน N bytes, content type ต้องเป็น image/*

## Real World Incidents

**Incident 1 — User upload malware ผ่าน bypassed type check (file sharing service)**
frontend validate content type ด้วย JavaScript ก่อน upload
attacker ใช้ curl ส่ง PUT request ตรงไปยัง presigned URL — bypass frontend validation
upload .exe file ขึ้น S3 ได้สำเร็จ
file แจกจ่ายต่อให้ user อื่น — antivirus ตรวจเจอหลังจาก 3 วัน
แก้โดยเปลี่ยนเป็น presigned POST พร้อม policy ที่ S3 enforce content type ไม่ใช่แค่ frontend

**Incident 2 — Storage abuse จากการไม่มี size limit (document platform)**
platform ให้ user upload document โดยไม่มี size limit ใน presigned PUT URL
attacker script upload ไฟล์ 5GB ซ้ำๆ หลายพัน request
S3 bill พุ่ง $8,000 ในคืนเดียว
ต้องปิด upload endpoint ฉุกเฉิน ทำให้ user จริงๆ ก็ใช้งานไม่ได้ไปด้วย

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// presigned PUT ไม่มี policy
url, _ := client.PresignedPutObject(ctx, bucket, key, 15*time.Minute)
// ส่ง url ให้ frontend
// frontend validate content type ด้วย JavaScript ก่อน upload
```

**พังตอนไหน:**
- attacker inspect network request แล้วใช้ curl ส่งตรง — bypass frontend validation ทั้งหมด
- ไม่มี size limit — upload 100GB ด้วย PUT URL เดิม
- key ไม่มี prefix constraint — user upload ทับไฟล์ user อื่นถ้าเดา key ได้
- S3 accept แล้วคิดเงิน — frontend check ไม่มีประโยชน์ถ้า S3 ไม่ enforce

**Root cause:**
Validation ที่ทำแค่ฝั่ง client ไม่มีความหมายด้าน security
S3 ต้องเป็นคน enforce ข้อจำกัด — presigned POST policy คือกลไกที่ S3 ออกแบบมาสำหรับจุดประสงค์นี้โดยตรง

## Explore First

### Go

ก่อนเขียน code ให้เปิด SDK แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `minio.NewPostPolicy()` — return type คืออะไร? `*PostPolicy` มี method อะไรบ้างสำหรับกำหนด constraint?
- hint: `(*PostPolicy).SetBucket(bucket string)` และ `SetKey(key string)` — ต้อง set อะไรบ้าง minimum?
- hint: `(*PostPolicy).SetKeyStartsWith(keyPrefix string)` — ต่างจาก `SetKey` ยังไง? ใช้เมื่อไหร่?
- hint: `(*PostPolicy).SetContentType(contentType string)` — รับ exact type หรือ wildcard เช่น `image/*` ได้ไหม?
- hint: `(*PostPolicy).SetContentLengthRange(min, max int64)` — S3 จะ reject upload ที่ size ไม่อยู่ใน range ยังไง?
- hint: `client.PresignedPostPolicy(ctx, policy *PostPolicy)` — return type คืออะไร? ต่างจาก `PresignedPutObject` ยังไง?
- frontend จะ submit presigned POST ยังไง? ต้องใช้ `FormData` อะไรบ้าง? ทำไมถึงต้องส่ง policy fields ด้วย?
- ถ้า `allowedTypes` มีหลาย content type เช่น `["image/jpeg", "image/png"]` — ทำยังไงเพราะ SetContentType รับแค่ค่าเดียว?

## Task

implement `generateConstrainedUploadPolicy(client, bucket, keyPrefix, maxSizeMB, allowedTypes, expiry)` ที่:

1. สร้าง presigned POST policy ที่ S3 enforce ข้อจำกัดต่อไปนี้:
   - key ต้องขึ้นต้นด้วย `keyPrefix`
   - ขนาดไฟล์ต้องไม่เกิน `maxSizeMB` MB (minimum 1 byte)
   - content type ต้องอยู่ใน `allowedTypes`
2. return `*url.URL` (endpoint ที่ frontend จะ POST ไป) และ `map[string]string` (form fields ที่ต้องแนบไปด้วย)

**หมายเหตุ:** ถ้า minio SDK รับ content type ได้แค่ค่าเดียว ให้ใช้ค่าแรกใน `allowedTypes` และ document limitation นี้ใน comment

## Requirements

- `maxSizeMB <= 0` → return error
- `allowedTypes` เป็น empty slice → return error (ต้อง specify ว่า accept อะไร)
- `keyPrefix` เป็น empty string → return error (ป้องกัน user upload ได้ทุก path)
- size constraint: min = 1 byte, max = maxSizeMB * 1024 * 1024
- expiry ต้องอยู่ใน valid range
- return `map[string]string` ที่รวม policy fields ทั้งหมดที่ frontend ต้องใช้

## Acceptance Criteria

- [ ] S3 reject upload ที่ size เกิน maxSizeMB
- [ ] S3 reject upload ที่ content type ไม่อยู่ใน allowedTypes
- [ ] S3 reject upload ที่ key ไม่ขึ้นต้นด้วย keyPrefix
- [ ] S3 accept upload ที่ผ่าน constraint ทุกข้อ
- [ ] `maxSizeMB <= 0` → return error
- [ ] `allowedTypes` empty → return error
- [ ] `keyPrefix` empty → return error
- [ ] return map มี key ครบที่ frontend ต้องการ (`policy`, `x-amz-signature`, etc.)

## Concepts Involved

- `presigned-post` — ต่างจาก presigned PUT ตรงที่มี policy document ที่ S3 enforce
- `upload-policy` — S3 POST Policy JSON format, condition types: exact match, starts-with, range
- `content-type-validation` — ทำไม frontend validation ไม่พอ, S3-enforced content type
- `size-limit` — `content-length-range` condition, ป้องกัน storage abuse
- `storage-abuse-prevention` — rate limiting, size limits, prefix constraints ทำงานร่วมกัน

## Production Reality

- **ใช้จริง:** presigned POST ใช้บน web app ที่ต้องการ server-enforced upload constraint เช่น avatar upload (max 5MB, image only), document upload (max 20MB, pdf/docx only)
- **ทำ manual เมื่อ:** ต้องการ constraint ที่ซับซ้อนกว่าที่ S3 policy รองรับ เช่น validate magic bytes ของ file (ต้องทำบน backend หลัง upload แล้ว)
- **kata สอนว่า:** security validation ต้องอยู่ที่ server/storage layer — client-side validation เป็น UX improvement ไม่ใช่ security control
