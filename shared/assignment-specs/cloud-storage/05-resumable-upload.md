---
tier: cloud-storage
difficulty: 3
concepts: [resumable-upload, checkpoint, io.ReadSeeker, ListParts, uploadID-persistence, flaky-network]
---

# Kata: Resumable Upload

## Context

Multipart Upload แก้ปัญหา timeout สำหรับไฟล์ขนาดใหญ่ แต่ถ้า process crash หรือ network หาย ทุก part ที่ upload ไปแล้วต้อง re-upload ตั้งแต่ต้น
Resumable Upload ขยาย multipart ด้วยการ persist `uploadID` และ completed parts ลง checkpoint file — ทำให้ restart ได้จาก part สุดท้ายที่สำเร็จ ไม่ใช่ byte 0
Pattern นี้สำคัญมากสำหรับ mobile client, poor network environments, และ large file transfer ที่ใช้เวลาหลายชั่วโมง

## Real World Incidents

**Incident 1 — Mobile app upload ที่ไม่เคยสำเร็จบน 3G (Backup app startup, Southeast Asia)**
บริษัท startup ออก mobile backup app สำหรับตลาด SEA ที่ 3G เป็น network หลัก
user พยายาม backup ไฟล์ 500MB แต่ network drop ทุก 20–30 นาที
เพราะ code retry ตั้งแต่ byte 0 ทุกครั้ง — 500MB ไม่เคยสำเร็จเลยในช่วง 3G เพราะ connection ไม่คงที่พอ
หลังเพิ่ม checkpoint resume: user ที่เคยใช้ 3 ชั่วโมงโดยไม่สำเร็จ กลับ upload เสร็จใน 45 นาที (แม้ reconnect หลายครั้ง)

**Incident 2 — Batch genomics upload พังซ้ำซาก (Research institute)**
ทีม bioinformatics upload sequencing data ขนาด 200–800GB ต่อไฟล์ ผ่าน script กลางคืน
มีบางคืนที่ instance ถูก spot-interrupt กลางทาง — script วันถัดไปต้อง re-upload ทั้งหมด
cost เพิ่มขึ้นจาก data transfer ซ้ำ + researcher ต้องรอ data อีกหลายชั่วโมง
แก้โดยใช้ `aws s3 cp` ที่มี built-in multipart checkpoint — หรือเขียน custom resumable logic พร้อม checkpoint JSON

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
func UploadWithRetry(client *minio.Client, bucket, key string, r io.Reader, partSize int64) error {
    for attempt := 0; attempt < 3; attempt++ {
        err := MultipartUpload(client, bucket, key, r, partSize)
        if err == nil { return nil }
        log.Printf("attempt %d failed: %v", attempt+1, err)
        // r อ่านไปแล้ว — seek กลับไม่ได้ → retry ไม่มีประโยชน์
    }
    return errors.New("all attempts failed")
}
```

**พังตอนไหน:**
- `io.Reader` ไม่สามารถ rewind ได้ — retry ครั้งที่ 2 จะอ่านได้ 0 bytes เพราะ pointer อยู่ท้ายไฟล์แล้ว
- ถ้า rewind ได้ (ใช้ `ReadSeeker`) — ก็ยัง re-upload ทุก part ตั้งแต่ต้น ทำซ้ำงานที่สำเร็จไปแล้ว
- ถ้า process ถูก kill (ไม่ใช่แค่ network หาย) — `uploadID` หายไปกับ memory — ไม่มีทาง resume
- Part ที่ upload สำเร็จแล้วใน S3 ค้างอยู่โดยไม่มี complete — สะสมเป็น billing cost

**Root cause:**
Resume ต้องรู้ว่า "ทำไปถึงไหนแล้ว" — ข้อมูลนี้ต้องอยู่ใน durable storage (disk) ไม่ใช่ memory
ไม่งั้น process restart = ข้อมูล progress หายทุกครั้ง

## Explore First

### Go

ก่อนเขียน code ให้เปิด MinIO SDK และ stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `minio.Client.ListObjectParts(ctx, bucket, object, uploadID, partNumberMarker, maxParts)` — return อะไร? ใช้ดูว่า part ไหน upload สำเร็จแล้วได้ไหม?
- hint: `io.ReadSeeker` — method อะไรที่เพิ่มมาจาก `io.Reader`? `Seek(offset int64, whence int)` คำนวณ byte offset ยังไง? `whence` มีค่าอะไรบ้าง?
- hint: `os.File` implements `io.ReadSeeker` — ถ้า `r` เป็น `*os.File` จะ seek ไปยัง byte offset ที่ต้องการได้ยังไง? ถ้า part ขนาด 5MB และจะข้าม 3 parts แรก ต้อง seek ไปที่ offset เท่าไหร่?
- hint: `encoding/json` — ใช้ marshal/unmarshal checkpoint struct ยังไง? ควร `os.WriteFile` หรือ atomic write สำหรับ checkpoint?
- `minio.ListPartsResult` — fields อะไรที่บอก part number และ ETag ของ completed parts?
- ถ้า `uploadID` ใน checkpoint ไม่มีอยู่ใน S3 อีกแล้ว (expired หรือถูก abort) → `ListObjectParts` return error อะไร? จะจัดการยังไง?

### Concepts to understand first

- `io.ReadSeeker vs io.Reader`: Reader อ่านได้ทิศเดียว (forward-only) — Seeker เพิ่ม ability ในการ jump ไปยัง byte offset ใดก็ได้ ซึ่งจำเป็นสำหรับ resume
- `checkpoint file`: คิดเป็น "progress snapshot" — ต้องมีข้อมูลทุกอย่างที่จำเป็นสำหรับ resume: `uploadID`, `bucket`, `key`, และ list ของ completed parts (partNumber + ETag)
- `stale checkpoint`: checkpoint ที่ uploadID หมดอายุหรือถูก abort แล้ว — ต้องตรวจสอบและเริ่มใหม่ได้

## Task

เขียนฟังก์ชัน `ResumableUpload(client *minio.Client, bucket, key, checkpointPath string, r io.ReadSeeker, partSize int64) error` ที่:

1. ถ้า checkpoint file มีอยู่และ valid → โหลด `uploadID` และ completed parts
2. ถ้าไม่มี checkpoint → initiate multipart upload ใหม่ และสร้าง checkpoint file
3. ข้าม parts ที่ complete แล้ว (ตาม checkpoint) — seek `r` ไปยัง byte offset ที่ถูกต้อง
4. Upload parts ที่ยังขาด ทีละ part — อัปเดต checkpoint หลังแต่ละ part สำเร็จ
5. เมื่อทุก part เสร็จ → complete multipart upload และลบ checkpoint file
6. ถ้าเกิด error ระหว่างทาง → checkpoint ยังอยู่ให้ resume ครั้งต่อไป (ไม่ abort)

## Requirements

- Checkpoint file ต้องเก็บ: `uploadID`, `bucket`, `key`, และ list ของ `{partNumber, etag}` ที่ complete แล้ว
- ถ้า checkpoint มีอยู่แต่ `uploadID` ไม่มีใน S3 (expired) → ลบ checkpoint เก่าและเริ่ม upload ใหม่
- ต้อง seek `r` ไปยัง `partNumber * partSize` ก่อน upload แต่ละ part ที่ยังขาด (ไม่ใช่อ่านแบบ sequential แล้วทิ้ง)
- อัปเดต checkpoint ทุกครั้งที่ part upload สำเร็จ — ใช้ atomic write เพื่อ checkpoint ไม่ corrupt
- ลบ checkpoint file เมื่อ upload complete แล้ว — ไม่ทิ้งค้างไว้
- Part size ต้องไม่ต่ำกว่า 5MB

## Acceptance Criteria

- [ ] Upload ครั้งแรก (ไม่มี checkpoint): สำเร็จ object อยู่ใน S3 ครบถ้วน, checkpoint ถูกลบแล้ว
- [ ] จำลอง crash หลัง part 2: checkpoint มี `uploadID` และ 2 completed parts
- [ ] Resume จาก checkpoint: อ่านแค่ parts ที่ยังขาด ไม่ re-upload parts ที่ complete แล้ว (ตรวจจาก S3 call count)
- [ ] Object ใน S3 หลัง complete เหมือนกับ upload ครั้งเดียวทั้งหมด byte-for-byte
- [ ] Checkpoint ที่มี uploadID หมดอายุ → ลบ checkpoint เก่าและเริ่มใหม่ได้โดยไม่ error
- [ ] Checkpoint file ถูกลบหลัง upload สำเร็จ — ไม่มีค้างบน disk
- [ ] Seek ไปยัง correct byte offset: part 3 ด้วย partSize 5MB → seek ไปที่ byte 10485760

## Concepts Involved

- `io.ReadSeeker` — extends `io.Reader` ด้วย `Seek` method — จำเป็นสำหรับ random access ใน file
- `checkpoint` — durable progress snapshot ที่ช่วยให้ resume ได้หลัง crash/restart
- `ListObjectParts` — S3 API สำหรับ query parts ที่ upload ไปแล้วใน existing multipart session
- `uploadID-persistence` — uploadID ต้องอยู่ใน disk ไม่ใช่ memory เพราะ process อาจ restart ได้ทุกเมื่อ
- `atomic-write` — checkpoint file ต้องเขียนแบบ atomic เพื่อไม่ corrupt ระหว่าง crash

## Production Reality

- **ใช้จริง:** `aws s3 cp` มี built-in multipart resumable — `tus` protocol (tus.io) เป็น open standard สำหรับ resumable upload ที่ใช้กันอย่างแพร่หลาย
- **uploadID expiry:** S3 multipart upload ไม่มี built-in expiry แต่ lifecycle policy สามารถ abort incomplete uploads ได้ — checkpoint อาจอ้าง uploadID ที่ถูก lifecycle abort แล้ว ต้องรับมือกรณีนี้
- **ทำ manual เมื่อ:** upload large file จาก unstable network, background upload ใน mobile app, หรือ pipeline ที่อาจถูก interrupt บ่อย
- **kata สอนว่า:** "retry from scratch" กับ "resume from checkpoint" เป็นคนละ pattern โดยสิ้นเชิง — retry ง่ายกว่าแต่ช่วยไม่ได้กับ flaky long-running operation ที่ข้อมูล progress หายทุก restart
