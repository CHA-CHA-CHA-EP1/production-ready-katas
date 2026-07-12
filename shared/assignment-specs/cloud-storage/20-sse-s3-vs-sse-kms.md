---
tier: cloud-storage
difficulty: 1
concepts: [encryption-at-rest, sse-s3, sse-kms, compliance, aws-kms]
provider: aws-only
---

# Kata: SSE-S3 vs SSE-KMS

> **Provider:** AWS only — ต้องการ AWS account, IAM permissions, และ AWS SDK

## Context

การเก็บ object ใน S3 โดยไม่ระบุ encryption ทำให้ข้อมูลอยู่ในรูปแบบ unencrypted at rest — ซึ่งไม่ผ่าน compliance standard อย่าง GDPR, HIPAA, หรือ PCI-DSS ทันที
AWS มีสองตัวเลือกหลักสำหรับ server-side encryption: SSE-S3 (S3 จัดการ key เอง) และ SSE-KMS (AWS KMS จัดการ key พร้อม audit trail)
ความแตกต่างหลักคือ SSE-KMS ทิ้ง log ทุก decrypt operation ไว้ใน CloudTrail ทำให้ตอบคำถาม auditor ได้ว่า "ใครเข้าถึงข้อมูลนี้เมื่อไหร่" — SSE-S3 ทำไม่ได้

## Real World Incidents

**Incident 1 — GDPR audit fail เพราะไม่มี encryption at rest (E-commerce startup, EU, 2022)**
บริษัท e-commerce ขนาดกลางในยุโรปเก็บข้อมูล order history และ PII ของลูกค้าใน S3 โดยไม่ได้ set encryption flag ใดๆ
ระหว่าง GDPR audit พบว่า object ทั้งหมดใน bucket ไม่มี server-side encryption — auditor ถือว่าเป็น data protection violation ทันที
บริษัทต้องหยุด production ชั่วคราว enable default encryption ที่ bucket level และส่ง report ชี้แจงต่อ DPA ว่าเหตุการณ์นี้ไม่ใช่ data breach
แก้โดยเปิด default bucket encryption เป็น SSE-KMS และ enforce ผ่าน S3 bucket policy ว่าทุก PutObject ต้องมี encryption header

**Incident 2 — Security review พบ unencrypted sensitive data (FinTech company, 2023)**
ทีม security ของบริษัท fintech ทำ quarterly security review และพบว่า bucket ที่เก็บ financial statement PDF ไม่มี encryption at rest
Dev team เคย upload ด้วย SSE-S3 ในตอนแรก แต่ migration script ที่ copy object ข้าม bucket ลืม forward encryption header ทำให้ object ใหม่ไม่มี encryption
ผลคือ object กว่า 50,000 ไฟล์ในช่วง 3 เดือนไม่ได้รับการเข้ารหัส — ต้องทำ re-encryption ทั้งหมดและแจ้ง compliance officer
บทเรียน: enforce encryption ที่ระดับ bucket policy ไม่ใช่แค่ application code เพื่อกัน misconfiguration จาก script หรือ tool อื่น

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
_, err = s3Client.PutObject(ctx, &s3.PutObjectInput{
    Bucket: aws.String(bucket),
    Key:    aws.String(key),
    Body:   r,
})
```

**พังตอนไหน:**
- Compliance audit ถาม "ข้อมูลลูกค้าถูก encrypt at rest ไหม?" — ตอบว่า "ไม่แน่ใจ" ไม่ได้
- GDPR / HIPAA requirement บอกว่า PII ต้องมี encryption at rest — ไม่ผ่านทันที
- Security team ต้องการ audit trail ว่าใครเคย decrypt object นี้บ้าง — SSE-S3 ไม่มีข้อมูลนี้

**Root cause:**
เมื่อไม่ระบุ `ServerSideEncryption` ใน `PutObjectInput` AWS จะใช้ค่า default ของ bucket ซึ่งถ้าไม่ได้ตั้งไว้ก็หมายความว่าไม่มี encryption
แม้แต่เมื่อใช้ SSE-S3 ก็ยังมีช่องโหว่ด้าน auditing — ไม่มีทางรู้ว่า key ถูก use เมื่อไหร่ โดยใคร และเพื่ออะไร

## Explore First

### Go

ก่อนเขียน code ให้เปิด AWS SDK v2 docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `s3.PutObjectInput` field `ServerSideEncryption` — รับ type อะไร? ใช้ค่าคงที่ (constants) ชื่ออะไรจาก package `types`?
- hint: `types.ServerSideEncryptionAwsKms` vs `types.ServerSideEncryptionAes256` — ค่าไหนคือ SSE-KMS? ค่าไหนคือ SSE-S3?
- hint: `s3.PutObjectInput` field `SSEKMSKeyId` — ใช้เมื่อไหร่? ถ้า omit เมื่อใช้ SSE-KMS จะเกิดอะไร? AWS ใช้ key ไหนแทน?
- hint: `s3.HeadObjectOutput` — หลัง upload ดู field อะไรเพื่อ verify ว่า object ถูก encrypt ด้วย algorithm อะไร?
- hint: KMS Key ARN format — `arn:aws:kms:<region>:<account>:key/<key-id>` ทำ validation ได้ยังไง? ต่างจาก key alias (`alias/my-key`) ยังไง?

## Task

เขียนฟังก์ชัน `UploadWithSSE` ที่รองรับทั้ง SSE-S3 และ SSE-KMS:

```go
func UploadWithSSE(
    ctx context.Context,
    client *s3.Client,
    bucket, key string,
    r io.Reader,
    encryptionType string, // "SSE-S3" หรือ "SSE-KMS"
    kmsKeyID string,        // ใช้เฉพาะตอน encryptionType == "SSE-KMS"
) error
```

ฟังก์ชันต้อง:
1. Map `encryptionType` string ไปยัง AWS SDK type ที่ถูกต้อง
2. Set `KMSKeyId` เมื่อใช้ SSE-KMS (ถ้า `kmsKeyID` ไม่ว่าง)
3. Validate KMS Key ARN format เมื่อ `kmsKeyID` ไม่ว่าง
4. Return error ที่ชัดเจนเมื่อ `encryptionType` ไม่รู้จัก

## Requirements

- รองรับ `encryptionType` สองค่า: `"SSE-S3"` และ `"SSE-KMS"` — ค่าอื่น return error ทันที
- เมื่อใช้ SSE-KMS และส่ง `kmsKeyID` ที่ไม่ว่าง ต้อง validate ว่าเป็น KMS Key ARN format ที่ถูกต้อง (`arn:aws:kms:...`) ก่อน call API
- เมื่อใช้ SSE-KMS และ `kmsKeyID` ว่าง ให้ AWS ใช้ AWS managed key (`aws/s3`) โดย omit field นั้น
- หลัง upload ให้ call `HeadObject` เพื่อ verify ว่า `ServerSideEncryption` field ตรงกับที่ร้องขอ
- Error message ต้องระบุ bucket, key, และ encryption type ที่ใช้

## Acceptance Criteria

- [ ] Upload ด้วย SSE-S3 แล้ว `HeadObject` response มี `ServerSideEncryption: "AES256"`
- [ ] Upload ด้วย SSE-KMS แล้ว `HeadObject` response มี `ServerSideEncryption: "aws:kms"`
- [ ] Upload ด้วย SSE-KMS พร้อม explicit KMS Key ARN แล้ว `SSEKMSKeyId` ตรงกับที่ระบุ
- [ ] ส่ง `kmsKeyID` ที่ไม่ใช่ ARN format (เช่น `"my-key"`) ต้อง return validation error ก่อนยิง API
- [ ] ส่ง `encryptionType` ที่ไม่รู้จัก (เช่น `"SSE-C"`) ต้อง return error ทันที

## Concepts Involved

- `SSE-S3` — AWS S3 จัดการ encryption key เอง (AES-256), ไม่มี audit trail per-object
- `SSE-KMS` — AWS KMS จัดการ key, ทุก decrypt/encrypt ถูก log ใน CloudTrail, รองรับ key rotation
- `KMS Key ARN` — identifier ของ KMS key ในรูป `arn:aws:kms:<region>:<account-id>:key/<key-id>`
- `HeadObject` — ดู metadata ของ object (รวม encryption info) โดยไม่ download body

## Production Reality

- **ใช้จริง:** Production ที่ต้องผ่าน compliance มักใช้ SSE-KMS เพราะ CloudTrail audit trail — ทุก `Decrypt` call จะปรากฏใน CloudTrail logs ทำให้ตอบ "ใครเข้าถึงข้อมูลนี้เมื่อไหร่" ได้
- **ทำ manual เมื่อ:** ต้องการ cross-account access ด้วย KMS key sharing, หรือต้องการ fine-grained key policy ต่อ object type
- **kata สอนว่า:** SSE-S3 กับ SSE-KMS ต่างกันมากในแง่ compliance — ไม่ใช่แค่เปลี่ยน constant หนึ่งค่า แต่ต่างกันในเรื่อง audit capability, key rotation control, และ IAM permission model ทั้งหมด
