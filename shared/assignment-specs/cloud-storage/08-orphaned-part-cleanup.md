---
tier: cloud-storage
difficulty: 2
concepts: [multipart-upload, lifecycle-management, s3-billing, pagination, dry-run-pattern]
---

# Kata: Orphaned Part Cleanup

## Context

S3 multipart upload เป็น mechanism สำหรับ upload ไฟล์ขนาดใหญ่โดยแบ่งเป็น chunk แล้ว upload แยกกัน
ปัญหาคือถ้า upload fail กลางคัน — เช่น crash, timeout, หรือ network drop — parts ที่ upload ไปแล้วจะยังอยู่ใน S3 ในสถานะ "incomplete"
S3 คิดเงินทุก byte ของ incomplete parts เหมือน object จริง — แต่ object เหล่านี้ไม่สามารถอ่านได้เลย เป็นแค่ขยะที่เสียเงิน
ใน production ที่มี upload หลายพันครั้งต่อวัน orphaned parts สะสมได้เร็วมากถ้าไม่มีกระบวนการ cleanup

## Real World Incidents

**Incident 1 — S3 bill พุ่ง $47,000/เดือนจาก orphaned parts (media startup)**
บริษัท media startup มี user upload video ผ่าน multipart upload
upload ล้มเหลว ~5% เพราะ mobile network ไม่เสถียร
ไม่มี cleanup job — orphaned parts สะสมนาน 18 เดือน
วันที่ finance review AWS bill พบว่า S3 storage บวม 8TB ทั้งๆ ที่ actual content มีแค่ 500GB
ต้นทุน orphaned parts: $47,000 ต่อเดือน — ค้นพบโดยบังเอิญตอน audit ก่อน Series A

**Incident 2 — Compliance audit fail เพราะ stale incomplete uploads (fintech company)**
บริษัท fintech ต้องผ่าน SOC2 audit
auditor ตรวจพบ incomplete multipart uploads อายุเกิน 90 วันใน S3 bucket ที่ควรเก็บข้อมูลลูกค้า
incomplete parts มีข้อมูลส่วนตัว (PII) อยู่ใน parts ที่ upload ไปแล้ว ซึ่งนับเป็น data retention violation
ต้องรีบเขียน cleanup script ฉุกเฉินและ abort incomplete uploads ทั้งหมดก่อน audit รอบถัดไป

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
ไม่ทำอะไรเลย — multipart upload API เป็นเรื่องของ SDK จัดการ เพราะ SDK "น่าจะ" cleanup ให้

**พังตอนไหน:**
- upload fail กลางคัน → parts ค้างอยู่ใน S3 ตลอดไป จนกว่าจะ abort manually
- สร้าง S3 Lifecycle Policy ผ่าน console แต่ลืม apply กับ bucket ใหม่ → ทุก bucket ใหม่สะสม orphan parts
- เขียน cleanup แต่ list objects แทน list incomplete uploads → ไม่เห็น incomplete parts เลย

**Root cause:**
Incomplete multipart uploads ไม่ปรากฏใน `ListObjects` — ต้องใช้ `ListIncompleteUploads` API แยกต่างหาก
AWS SDK และ S3-compatible storage ไม่มี auto-cleanup — ต้องทำเองหรือตั้ง Lifecycle Policy
ถ้า abort ไม่ถูกต้อง (บาง upload ID) parts บาง chunk ยังค้างอยู่

## Explore First

### Go

ก่อนเขียน code ให้เปิด SDK แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `client.ListIncompleteUploads(ctx, bucket, prefix, recursive)` — return type คืออะไร? มัน paginate อัตโนมัติไหม? หรือต้องทำเอง?
- hint: `minio.ObjectMultipartInfo` — field อะไรที่บอกว่า upload เริ่มเมื่อไหร่? ชื่อ field ว่าอะไร?
- hint: `client.RemoveIncompleteUpload(ctx, bucket, key)` — abort upload นั้นด้วย upload ID ไหน? หรือ abort ทุก incomplete upload ของ key นั้น?
- `time.Since(t)` vs `time.Now().Sub(t)` — ต่างกันยังไง? อันไหนเหมาะกับการ check อายุ?
- ถ้า bucket มี incomplete uploads ล้านรายการ — การ list ทั้งหมดพร้อมกันจะเกิดอะไรขึ้น? ควร limit หรือ stream?
- dry-run pattern: จะรู้ว่า "จะลบกี่รายการ" โดยไม่ลบจริงได้ยังไง? ควร design API ยังไง?

## Task

เขียนฟังก์ชัน `CleanupOrphanedParts(client *minio.Client, bucket string, olderThan time.Duration) (int, error)` ที่:

1. list incomplete multipart uploads ทั้งหมดใน bucket
2. abort uploads ที่มีอายุเกิน `olderThan`
3. return จำนวน uploads ที่ถูก abort
4. ไม่แตะ uploads ที่ยังไม่เกิน threshold — อาจเป็น upload ที่กำลัง active อยู่

รวมถึง dry-run variant:
```go
func CleanupOrphanedPartsDryRun(client *minio.Client, bucket string, olderThan time.Duration) ([]minio.ObjectMultipartInfo, error)
```
ที่ return รายการ uploads ที่ "จะถูกลบ" โดยไม่ลบจริง

## Requirements

- ต้องใช้ `ListIncompleteUploads` ไม่ใช่ `ListObjects` — incomplete parts ไม่ปรากฏใน ListObjects
- threshold เทียบกับ `Initiated` time ของ upload ไม่ใช่ last modified
- abort ทีละ upload — ไม่ batch เพราะแต่ละ abort อาจ fail แยกกัน
- ถ้า abort หนึ่งรายการ fail ให้ continue รายการถัดไป แล้ว return error ที่รวม count ของสิ่งที่สำเร็จและ fail
- context cancel ต้อง stop การ iterate ทันที — ไม่ทำงานต่อหลัง context done

## Acceptance Criteria

- [ ] detect incomplete uploads ที่เก่ากว่า threshold ได้ครบ
- [ ] ไม่แตะ incomplete upload ที่เพิ่ง initiated (อายุน้อยกว่า threshold)
- [ ] ถ้า 2 ใน 5 uploads abort fail → return count=3, error บอก context ว่า 2 fail
- [ ] dry-run return รายการเดียวกับที่ cleanup จะลบ
- [ ] context cancel ระหว่าง cleanup → หยุดทันที return สิ่งที่ abort ไปแล้ว
- [ ] empty bucket → return 0, nil (ไม่ error)

## Concepts Involved

- `multipart-upload` — lifecycle ของ multipart upload, parts vs object, completed vs incomplete
- `s3-billing` — S3 คิดเงิน incomplete parts เต็มราคา, ทำไม abort ถึงสำคัญ
- `lifecycle-management` — S3 Lifecycle Policy เป็น alternative, ข้อดี/ข้อเสียเทียบกับ cleanup job
- `pagination` — ListIncompleteUploads return channel ใน minio SDK, วิธีอ่านแบบ stream
- `dry-run-pattern` — pattern สำหรับ destructive operation ที่ต้องการ preview ก่อน run จริง

## Production Reality

- **ใช้จริง:** ตั้ง S3 Lifecycle Policy `AbortIncompleteMultipartUpload` ที่ expire หลัง 7 วัน — ทำผ่าน AWS Console หรือ Terraform
- **ทำ manual เมื่อ:** ต้องการ cleanup ฉุกเฉินก่อน Lifecycle Policy kick in, หรือใช้กับ storage ที่ไม่ support Lifecycle (เช่น self-hosted MinIO)
- **kata สอนว่า:** incomplete multipart uploads เป็น invisible cost — ไม่เห็นใน ListObjects, ไม่เห็นใน dashboard ชัดๆ แต่เสียเงินจริง
