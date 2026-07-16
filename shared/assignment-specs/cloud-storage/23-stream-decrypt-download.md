---
tier: cloud-storage
difficulty: 2
concepts: [streaming-decrypt, io.Reader, aes-gcm, memory-efficiency, pipe, s3-compatible]
provider: s3-compatible
---

# Kata: Stream Decrypt Download

## Context

เมื่อ client-side encryption ถูก pair กับการ serve file ไปยัง user ปัญหาใหม่เกิดขึ้น: ถ้า decrypt ทั้งไฟล์ก่อนแล้วค่อย stream ออกไป ต้องโหลด plaintext ทั้งหมดใน memory ก่อน
ไฟล์ขนาด 2GB จะต้องการ memory 2GB+ เพียงแค่ serve request เดียว — บน pod ที่มี memory limit 512MB นั่นหมายถึง OOM crash ทุกครั้ง
kata นี้สอนวิธี wrap S3 download stream ด้วย decryption reader ที่ decrypt on-the-fly ขณะที่ bytes ไหลจาก S3 ไปยัง HTTP response writer โดยตรง

## Real World Incidents

**Incident 1 — OOM crash เมื่อ serve encrypted video file (Video streaming platform, 2022)**
ทีม backend เพิ่ม client-side encryption สำหรับ video content ที่เก็บใน MinIO เพื่อผ่าน DRM compliance
download handler เขียนแบบ: download จาก MinIO ทั้งไฟล์ → decrypt ใน memory → write ไปยัง response
เมื่อ user เริ่ม stream วิดีโอ 1.8GB พร้อมกัน 10 คน server OOM และ Kubernetes restart pod ทิ้ง
ทีมคำนวณว่า concurrent stream 10 ไฟล์ × 1.8GB = 18GB RAM ที่ต้องการ — pod มีแค่ 2GB
แก้โดยสร้าง custom `decryptReader` ที่ wrap S3 object reader และ decrypt chunks ขณะ HTTP response writer ดึงข้อมูลออกไป

**Incident 2 — Latency สูงผิดปกติจาก double-buffering (Document portal, 2023)**
ระบบ document portal เก็บ PDF เข้ารหัสใน S3 และ decrypt ก่อน serve ไปยัง browser
ผู้ใช้ complaint ว่า PDF ขนาด 50MB ใช้เวลา 8-12 วินาทีกว่าจะเริ่ม render ใน browser — ทั้งที่ internet เร็ว
Debug พบว่า server ต้อง download ทั้งไฟล์จาก S3 (2-3 วิ) แล้ว decrypt ในหน่วยความจำ (1-2 วิ) ก่อนที่จะส่ง byte แรกออกไป
เปลี่ยนมาใช้ streaming decrypt ทำให้ browser ได้รับ byte แรกใน ~300ms — ลดลง 25x เพราะ S3 download กับ decrypt เกิดพร้อมกันและ response ถูก write ทันทีที่ decrypt แต่ละ chunk เสร็จ

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// download ทั้งไฟล์ก่อน
obj, err := minioClient.GetObject(ctx, bucket, key, minio.GetObjectOptions{})
if err != nil { return err }
defer obj.Close()

ciphertext, err := io.ReadAll(obj)  // โหลดทั้งไฟล์เข้า memory
if err != nil { return err }

// อ่าน nonce จาก 12 bytes แรก
nonce := ciphertext[:12]
// decrypt ทั้งหมดใน memory
plaintext, err := gcm.Open(nil, nonce, ciphertext[12:], nil)
if err != nil { return err }

// แล้วค่อย write ออกไป
w.Write(plaintext)
```

**พังตอนไหน:**
- ไฟล์ 2GB → ต้องการ memory 2GB+ เพียง request เดียว (ciphertext + plaintext อยู่ใน memory พร้อมกัน)
- 10 concurrent request × 500MB = 5GB RAM หาย ทั้งที่ pod มีแค่ 1GB
- User ต้องรอให้ download และ decrypt เสร็จทั้งหมดก่อนได้รับ byte แรก — latency สูงมาก
- `io.ReadAll` block จนกว่าจะได้ทุก byte — ถ้า S3 ช้า request ค้างนาน ทั้งที่ user เริ่มรับ data ได้เลย

**Root cause:**
Decryption ถูก treat เป็น "transform ทั้ง buffer" แทนที่จะเป็น "transform แต่ละ chunk"
GCM จริงๆ ต้องการ ciphertext ทั้งหมดก่อน verify authentication tag — แต่มีวิธีจัดการได้โดยอ่าน nonce ก่อน แล้ว pipe ที่เหลือผ่าน `gcm.Open` เมื่อมี data ครบ หรือใช้ chunked AEAD สำหรับ streaming จริงๆ

## Explore First

### Go

ก่อนเขียน code ให้ตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `gcm.Open(dst, nonce, ciphertext, additionalData []byte)` — ต้องการ ciphertext ทั้งหมดก่อนถึง verify tag ได้ — kata นี้จัดการยังไง? ต้อง buffer ทั้งไฟล์อยู่ดีหรือมีทางหลีกเลี่ยง?
- hint: `io.ReadFull(r, buf)` vs `r.Read(buf)` — เมื่อต้องการอ่านให้ครบ N bytes จาก stream ใช้อันไหน? ทำไม?
- hint: สร้าง custom `io.Reader` ที่ wrap reader อื่น — struct มี field อะไรบ้าง? `Read` method ต้องทำอะไรบ้าง?
- hint: `io.Pipe()` — return `PipeReader` และ `PipeWriter` — ใช้ยังไงในการ connect goroutine ที่ decrypt กับ goroutine ที่ write HTTP response?
- hint: `minio.Object` implements `io.Reader` — สามารถส่งโดยตรงไปยัง `io.ReadFull` หรือ custom reader ได้เลยโดยไม่ต้อง buffer ไหม?
- hint: Error propagation ผ่าน pipe — ถ้า decrypt fail กลางคัน `PipeWriter.CloseWithError(err)` ทำอะไร? ฝั่ง reader จะได้รับ error นั้นยังไง?

## Task

implement `StreamDecryptDownload` ที่ pipe S3 download ผ่าน AES-GCM decryption ไปยัง writer โดยตรง:

```
// StreamDecryptDownload download object จาก S3/MinIO แล้ว decrypt streaming ไปยัง writer
// - อ่าน nonce จาก 12 bytes แรกของ S3 stream
// - decrypt ส่วนที่เหลือและ write ไปยัง w
// - ไม่ buffer ทั้งไฟล์ใน memory
// - รองรับไฟล์ขนาดใดก็ได้
//
// เป็น pair กับ ClientSideEncryptUpload (kata 22)
// format ใน S3: [nonce (12 bytes)][ciphertext + GCM tag (16 bytes)]
func treamDecryptDownload(
    ctx cancellation context,
    s3Client ,
    bucket, key string,
    aesKey list,
    w writable stream,
) error
```

**คำใบ้สำหรับการ implement:**

เพราะ AES-GCM ต้องการ ciphertext ทั้งหมดก่อน verify authentication tag มีสองแนวทาง:

**แนวทาง A (ง่ายกว่า แต่ยังดีกว่า naive):** อ่านทั้งไฟล์จาก S3 stream แต่ decrypt และ write ไปยัง `w` โดยตรง — ยัง buffer ciphertext แต่ไม่ buffer plaintext ซ้อนกัน

**แนวทาง B (ขั้นสูง):** ใช้ `io.Pipe()` — goroutine หนึ่ง download จาก S3 เขียนลง PipeWriter, อีก goroutine อ่านจาก PipeReader decrypt แล้วเขียนลง `w` — concurrent pipeline ที่ไม่ buffer เลย

ให้ implement อย่างน้อย แนวทาง A ก่อน แล้วลองเปรียบเทียบกับ B

## Requirements

- อ่าน nonce จาก 12 bytes แรกของ S3 object stream ด้วย `io.ReadFull` — ไม่ใช่ `Read`
- หลังอ่าน nonce แล้วต้อง decrypt และ write ไปยัง `w` — ห้าม hold plaintext ใน memory ทั้งไฟล์
- ถ้า GCM authentication fail (ไฟล์ถูก tamper) ต้อง return error ชัดเจน และ **ไม่** write bytes ที่ decrypt ได้บางส่วนออกไปก่อน
- รองรับ `aesKey` เฉพาะ 32 bytes — ถ้าไม่ใช่ return error ก่อน call MinIO API
- รองรับไฟล์ทุกขนาด โดยที่ Go heap ไม่เติบโตตามขนาดไฟล์ (สำหรับ แนวทาง B)
- Error ต้องระบุ bucket และ key ที่ fail

## Acceptance Criteria

- [ ] file ที่ encrypt ด้วย `ClientSideEncryptUpload` (kata 22) สามารถ decrypt ได้ถูกต้องด้วย `StreamDecryptDownload`
- [ ] decrypt ไฟล์ข้อความธรรมดา และ output ตรงกับ original byte-for-byte
- [ ] decrypt ไฟล์ 100MB โดยที่ heap ไม่เกิน 50MB ตลอดกระบวนการ (สำหรับ แนวทาง B)
- [ ] object ที่ถูก tamper (แก้ byte ใดๆ) ต้อง return authentication error — ห้าม write partial output
- [ ] ถ้า S3 object สั้นกว่า 12 bytes (ไม่มี nonce) ต้อง return error ที่อธิบายว่า object format ผิด
- [ ] ส่ง `aesKey` ขนาดผิดต้อง return error ก่อน download

## Concepts Involved

- `Streaming decrypt` — decrypt data ขณะ read จาก source โดยไม่ buffer ทั้งไฟล์
- `io.ReadFull` — อ่านให้ครบ N bytes จาก stream โดยไม่ว่า Read จะ return กี่ bytes ต่อครั้ง
- `io.Pipe` — synchronous in-memory pipe ที่ connect goroutine สองตัวโดยไม่ allocate buffer
- `GCM Authentication` — ต้องมี ciphertext ทั้งหมดก่อน verify — ผิดต่างจาก stream cipher ที่ decrypt ทีละ byte ได้
- `Memory footprint` — ขนาด heap ไม่ควรขึ้นกับขนาดไฟล์ใน streaming pipeline

## Production Reality

- **ใช้จริง:** AEAD streaming จริงๆ ใน production มักใช้ chunked encryption (แบ่งไฟล์เป็น chunk ขนาด 4MB แต่ละ chunk มี tag ของตัวเอง) เพื่อให้ decrypt แต่ละ chunk ได้ทันทีโดยไม่ต้องรอทั้งไฟล์ — เช่น AWS S3 Encryption Client ใช้ วิธีนี้
- **ทำ manual เมื่อ:** ต้องการ streaming decrypt บน S3-compatible storage ที่ไม่มี SDK encryption client, หรือต้องการ protocol เฉพาะ
- **pair กับ:** kata 22 (client-side encrypt upload) — format nonce+ciphertext ต้องตรงกัน
- **kata สอนว่า:** GCM ไม่ใช่ streaming cipher แต่ pipeline architecture ที่ดีทำให้ "streaming decrypt to writer" เป็นไปได้ด้วย memory footprint ต่ำ — ความแตกต่างอยู่ที่ architecture ไม่ใช่ algorithm
