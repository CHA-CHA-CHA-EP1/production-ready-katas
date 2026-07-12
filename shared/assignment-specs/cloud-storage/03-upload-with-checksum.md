---
tier: cloud-storage
difficulty: 2
concepts: [data-integrity, checksum, ETag, MD5, crypto/md5, io.TeeReader]
---

# Kata: Upload with Checksum

## Context

Network เป็น unreliable medium — bit สามารถ flip ระหว่างทางได้ (cosmic ray, hardware fault, NIC bug) โดยที่ TCP checksum ไม่จับได้เสมอไป
S3-compatible storage ใช้ ETag (ซึ่งมักจะเป็น MD5 ของ content) เพื่อ verify integrity หลัง upload
ถ้าไม่ verify ETag หลัง upload — คุณอาจเก็บ corrupted file ไว้ใน bucket โดยไม่รู้ตัว และ user จะได้รับไฟล์ที่เสียหาย

## Real World Incidents

**Incident 1 — Corrupted files served to users (Dropbox, ~2014)**
Dropbox พบว่า file บางส่วนที่ sync ไปยัง server มี corruption เล็กน้อย — บาง block มี bytes ผิด
สาเหตุ: network hardware bug ทำให้ TCP payload เปลี่ยนแปลงได้ในบางกรณีที่ TCP checksum ยังผ่าน (checksum collision)
เพราะ client ไม่ verify end-to-end checksum หลัง upload — corrupted version ถูกเก็บไว้และ sync กลับไปให้ device อื่น
Dropbox แก้โดยเพิ่ม content hash verification ในทุก upload และ download path

**Incident 2 — Silent bit rot ใน backup system (Financial services firm)**
ระบบ backup เขียนไฟล์ขึ้น S3 ทุกคืน — แต่ไม่เคย verify ETag หรือ checksum
หลัง 18 เดือน ทีมทำ restore drill แล้วพบว่า backup บางส่วน corrupted — restore ไม่ได้
ตรวจพบว่า S3 request บางอันส่งข้อมูลผิดเพราะ memory corruption ใน application server
เพราะไม่มี checksum verification จึงไม่เคยรู้ว่า backup เสีย — จนถึงวันที่ต้องใช้จริง

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
_, err = client.PutObject(ctx, bucket, key, reader, size, minio.PutObjectOptions{})
if err == nil {
    log.Println("upload success")  // เชื่อว่าสำเร็จโดยไม่ verify
}
```

**พังตอนไหน:**
- Network glitch ระหว่าง upload ทำให้ bytes บางส่วนเปลี่ยน — PutObject return success แต่ file corrupted
- S3-compatible storage บางตัว (MinIO, Ceph) อาจเก็บ partial upload ในบางกรณีที่ server side error
- Memory corruption ใน Go process (เช่น unsafe code) ทำให้ buffer มี bytes ผิด — upload ไปเลยโดยไม่รู้

**Root cause:**
`PutObject` return `error = nil` หมายความแค่ว่า HTTP request สำเร็จ — ไม่ได้ guarantee ว่า bytes ที่ S3 เก็บตรงกับที่ส่งไป
การ verify ต้องเปรียบเทียบ checksum ที่คำนวณ locally กับ ETag ที่ S3 return กลับมา

## Explore First

### Go

ก่อนเขียน code ให้เปิด MinIO SDK และ stdlib แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `minio.UploadInfo` ที่ return มาจาก `PutObject` — field `ETag` คืออะไร? format เป็นอะไร (hex string? มี quote ไหม?)
- hint: `crypto/md5` package — `md5.New()` return อะไร? implements interface อะไรบ้าง? เอา hash ออกมาเป็น `[]byte` ยังไง?
- hint: `encoding/hex` — `hex.EncodeToString([]byte)` ใช้แปลง `[]byte` hash เป็น hex string ยังไง?
- hint: `io.TeeReader(r io.Reader, w io.Writer)` — ทำงานยังไง? ใช้คำนวณ checksum ระหว่าง stream โดยไม่ต้อง buffer ทั้งไฟล์ได้ยังไง?
- S3 ETag สำหรับ single-part upload มักจะเป็น MD5 ของ content — แต่มีกรณีที่ ETag ไม่ใช่ MD5 ไหม? (hint: multipart upload)
- `minio.PutObjectOptions` — field `SendContentMd5` มีผลอะไร? ต่างจากการ verify ETag หลัง upload ยังไง?

### Concepts to understand first

- `ETag format`: S3 ETag มักอยู่ในรูป `"d8e8fca2dc0f896fd7cb4cb0031ba249"` (มี double quotes ครอบ) — ต้อง strip ออกก่อน compare
- `io.TeeReader`: แนวคิด — ขณะที่อ่าน bytes ผ่าน TeeReader ก็เขียน bytes เดียวกันไปยัง hash พร้อมกัน ไม่ต้อง buffer

## Task

เขียนฟังก์ชัน `UploadWithChecksum(client *minio.Client, bucket, key string, r io.Reader, size int64) error` ที่:

1. คำนวณ MD5 checksum ของ content ระหว่าง stream (ไม่ใช่ buffer ทั้งหมดก่อน)
2. Upload ไปยัง MinIO/S3
3. เปรียบเทียบ ETag จาก server กับ checksum ที่คำนวณ
4. Return error ถ้า ETag ไม่ตรง — พร้อม message ที่บอกว่า checksum เป็นอะไร expect อะไร

## Requirements

- ต้องใช้ `io.TeeReader` หรือ equivalent เพื่อคำนวณ checksum ระหว่าง stream — ห้าม read ทั้งหมดเข้า memory แล้วค่อย hash
- ต้อง strip double quotes ออกจาก ETag ก่อน compare (S3 return ETag ในรูป `"abc123"`)
- ถ้า ETag ไม่ตรง ต้อง return error ที่บอก: expected checksum, actual ETag, bucket, key
- รองรับ `size = -1` (unknown size) — ใช้ `minio.PutObjectOptions` ที่เหมาะสม
- Error ต้อง wrap context ครบ: `"UploadWithChecksum: checksum mismatch: got abc123, want def456"`

## Acceptance Criteria

- [ ] Upload file ปกติ และ ETag ตรง → return `nil`
- [ ] จำลอง corruption: แก้ไข expected checksum ให้ผิด → return error ที่มี checksum ทั้งสองค่า
- [ ] Checksum คำนวณระหว่าง stream — heap ไม่โตตามขนาดไฟล์
- [ ] ETag ที่มี double quotes (เช่น `"d8e8fca2dc0f896fd7cb4cb0031ba249"`) ถูก handle ถูกต้อง ไม่ fail compare
- [ ] ถ้า upload ตัวเอง fail → return upload error ไม่ใช่ checksum error
- [ ] ทำงานกับ file ขนาด 0 bytes ได้ถูกต้อง (MD5 ของ empty string คือ `d41d8cd98f00b204e9800998ecf8427e`)

## Concepts Involved

- `ETag` — S3 object identifier ที่ใช้ verify integrity — format และ limitation → (concept doc ยังไม่มี)
- `io.TeeReader` — ช่วย compute hash ระหว่าง stream โดยไม่ต้อง read สองรอบ
- `crypto/md5` — Go standard library สำหรับ MD5 hash
- `data-integrity` — แนวคิดการ verify ว่า data ที่รับมาตรงกับที่ส่งไป

## Production Reality

- **ใช้จริง:** AWS SDK v2 รองรับ `ChecksumAlgorithm` (SHA256, CRC32) ใน PutObject โดยตรง — ไม่ต้องทำ manual
- **ETag limitation:** สำหรับ multipart upload, ETag ไม่ใช่ MD5 ของ content ทั้งหมด — เป็น MD5 ของ MD5s ของแต่ละ part — ห้าม compare โดยตรง
- **ทำ manual เมื่อ:** ใช้ SDK เก่าที่ไม่รองรับ checksum, ต้องการ algorithm อื่น (SHA256, BLAKE3), หรือ end-to-end verification ข้ามหลาย storage tier
- **kata สอนว่า:** "upload success" ไม่ได้แปลว่า "data intact" — การ verify integrity เป็น step ที่แยกออกมา ต้องทำ explicitly
