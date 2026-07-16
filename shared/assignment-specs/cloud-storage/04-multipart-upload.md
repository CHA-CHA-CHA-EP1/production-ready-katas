---
tier: cloud-storage
difficulty: 2
concepts: [multipart-upload, S3-protocol, part-management, cleanup-on-error, chunking]
---

# Kata: Multipart Upload

## Context

S3 single PUT request มี limit ที่ 5GB และ single TCP connection สำหรับ request ขนาดใหญ่มี timeout risk สูง
Multipart Upload แก้ปัญหานี้โดยแบ่งไฟล์ออกเป็น part เล็กๆ (5MB–5GB ต่อ part) upload แยกกัน แล้ว assemble กันที่ server side
Pattern นี้ใช้ได้แม้กับไฟล์ขนาด 5TB และยังช่วยให้ retry เฉพาะ part ที่ fail ได้โดยไม่ต้อง re-upload ทั้งหมด

## Real World Incidents

**Incident 1 — Upload 4 ชั่วโมงพังที่ 99% (AWS case study, documented in AWS blog)**
บริษัทด้าน genomics upload ไฟล์ข้อมูล DNA sequencing ขนาด 80GB ผ่าน single PUT request
connection เปิดค้างนาน 4 ชั่วโมง — intermediate load balancer มี idle connection timeout ที่ 3600 วินาที
ผลคือ connection ถูกตัดที่ 99% ของการ upload — ต้องเริ่มใหม่ตั้งแต่ต้น
แก้โดยเปลี่ยนมาใช้ multipart upload: แต่ละ part ขนาด 100MB เสร็จใน 2–3 นาที ไม่มี connection ที่เปิดนานเกิน timeout

**Incident 2 — Incomplete multipart upload สะสม ทำให้ cost พุ่ง (SaaS startup)**
ทีม implement multipart upload แต่ไม่ได้ handle error path ที่ต้อง abort upload
ทุกครั้งที่ upload fail กลางคัน ส่วนของ part ที่ upload ไปแล้วค้างอยู่ใน S3 bucket โดยไม่มี complete object
หลัง 6 เดือน พบว่า S3 bill มีค่า incomplete multipart upload สะสมสูงกว่า 40% ของ storage cost ทั้งหมด
แก้โดยเพิ่ม `AbortMultipartUpload` ใน error path และตั้ง S3 lifecycle policy ลบ incomplete upload อัตโนมัติหลัง 7 วัน

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// พยายาม upload ทั้งไฟล์ใน single PutObject
_, err = client.PutObject(ctx, bucket, key, reader, totalSize,
    minio.PutObjectOptions{})
```

**พังตอนไหน:**
- File ขนาด 8GB → single PUT เกิน S3 limit 5GB → error ทันที
- Connection timeout ที่ load balancer หรือ NAT gateway ระหว่าง upload นาน → ต้องเริ่มใหม่ทั้งหมด
- Network unstable: upload 90% แล้ว packet loss → retry ทั้งหมดตั้งแต่ byte 0

**Root cause:**
Single PUT ถือ TCP connection เดียวเปิดค้างไว้ตลอด duration ของ upload ทั้งหมด — ยิ่งไฟล์ใหญ่ยิ่ง fragile
Multipart แบ่งเป็น HTTP request สั้นๆ หลายอัน — แต่ละ part มี chance ของตัวเองในการ retry

## Explore First

### Go

ก่อนเขียน code ให้เปิด MinIO SDK แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `minio.Client.InitiateMultipartUpload(ctx, bucket, object, opts)` — return ค่าอะไร? ค่านี้ต้องใช้ในทุก subsequent call ยังไง?
- hint: `minio.Client.PutObjectPart(ctx, bucket, object, uploadID, partNumber, reader, size, opts)` — `partNumber` เริ่มที่เท่าไหร่? มี range ไหม? ถ้าใส่ผิดจะเกิดอะไร?
- hint: `minio.Client.CompleteMultipartUpload(ctx, bucket, object, uploadID, parts, opts)` — `parts []minio.CompletePart` ต้องการข้อมูลอะไรบ้าง? ต้อง sort ก่อนไหม?
- hint: `minio.Client.AbortMultipartUpload(ctx, bucket, object, uploadID)` — ต้องเรียกตอนไหน? ถ้าไม่เรียกจะเกิดอะไร?
- `io.LimitReader(r io.Reader, n int64)` — ใช้อ่าน bytes จำนวนจำกัดจาก reader ได้ยังไง? เหมาะกับการแบ่ง part ไหม?
- S3 multipart upload มี constraint อะไรบ้าง? part size minimum เท่าไหร่? maximum กี่ parts?

### Concepts to understand first

- `uploadID`: S3 identifier สำหรับ multipart upload session — ถ้าหายไปก็ไม่สามารถ complete หรือ abort ได้
- `CompletePart`: ต้องมีทั้ง `PartNumber` และ `ETag` — ETag มาจากไหน? (hint: return value ของ `PutObjectPart`)
- `part numbering`: S3 ใช้ 1-based part number — ผิดพลาดได้ง่ายสำหรับคนที่คิดแบบ 0-based

## Task

implement `multipartUpload(client, bucket, key, r, partSize)` ที่:

1. Initiate multipart upload เพื่อรับ `uploadID`
2. อ่าน content จาก `r` ทีละ `partSize` bytes และ upload แต่ละ part
3. เก็บ part info (`PartNumber` + `ETag`) ครบทุก part
4. Complete multipart upload เมื่อ upload ทุก part เสร็จ
5. **Abort** multipart upload ถ้าเกิด error ระหว่างทาง — ห้ามทิ้ง incomplete upload ค้างใน S3

## Requirements

- `partSize` ต้องไม่ต่ำกว่า 5MB (5 * 1024 * 1024) — ถ้าต่ำกว่าให้ return error ทันที (S3 spec)
- Part สุดท้ายอาจเล็กกว่า `partSize` — ต้องรองรับกรณีนี้
- ถ้า upload part ใด fail → ต้อง `AbortMultipartUpload` ก่อน return error
- ถ้า `CompleteMultipartUpload` fail → ต้อง abort ก็ต้องพยายาม
- Error message ต้องบอก context: bucket, key, และ part ที่ fail (ถ้ามี)
- Part number เริ่มที่ 1 (S3 spec กำหนด 1-based)

## Acceptance Criteria

- [ ] Upload file ขนาด 15MB ด้วย partSize 5MB → object ใน S3 ครบถ้วน byte-for-byte (3 parts)
- [ ] Upload file ขนาด 11MB ด้วย partSize 5MB → parts เป็น [5MB, 5MB, 1MB] ไม่ error เรื่อง part size
- [ ] ถ้า upload part 2 fail → abort upload → ไม่มี incomplete multipart upload ค้างใน bucket
- [ ] ถ้า `partSize` น้อยกว่า 5MB → return error ก่อนเริ่ม initiate
- [ ] Parts ถูกส่งใน `CompleteMultipartUpload` เรียงตาม part number ถูกต้อง
- [ ] Upload ไฟล์ขนาด 0 bytes → handle gracefully (อาจเป็น single empty part หรือ error ตาม policy)

## Concepts Involved

- `multipart-upload` — S3 protocol สำหรับ large file upload แบ่งเป็น parts
- `uploadID` — session identifier ที่ต้องใช้ในทุก call ของ multipart sequence
- `cleanup-on-error` — ถ้าไม่ abort, incomplete parts สะสมใน S3 และ billing เดินต่อ
- `CompletePart` — struct ที่ต้องรวบรวมจาก response ของแต่ละ `PutObjectPart`

## Production Reality

- **ใช้จริง:** MinIO SDK มี `PutObject` ที่ auto-detect ขนาดและใช้ multipart อัตโนมัติเมื่อ content > 128MB — ในหลายกรณีไม่ต้องเขียน manual
- **ทำ manual เมื่อ:** ต้องการ parallel part upload, progress tracking ต่อ part, หรือ resumable upload (ต้องรู้ uploadID)
- **S3 Lifecycle Policy:** ควร set lifecycle rule ลบ incomplete multipart uploads ทุก 7 วัน เป็น safety net ในกรณีที่ abort fail
- **kata สอนว่า:** S3 Multipart Upload เป็น 3-step protocol (Initiate → Upload Parts → Complete/Abort) — ขาดขั้นตอนใดขั้นตอนหนึ่งทำให้เกิด resource leak ที่เห็นได้ใน bill แต่ไม่เห็นได้ใน code
