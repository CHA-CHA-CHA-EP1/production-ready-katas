---
tier: cloud-storage
difficulty: 2
concepts: [client-side-encryption, aes-gcm, nonce, streaming-crypto, s3-compatible]
provider: s3-compatible
---

# Kata: Client-Side Encrypt Upload

## Context

SSE-S3 และ SSE-KMS เข้ารหัสข้อมูลหลังจาก data ถึง S3 แล้ว — ระหว่างทางจาก application ไปยัง S3 endpoint ข้อมูลอาจยังอยู่ใน plaintext บน network ภายใน datacenter
Compliance requirement บางอย่าง เช่น ระเบียบของ healthcare หรือ government cloud โดยเฉพาะ on-premise deployment กำหนดว่า "ข้อมูลต้องถูกเข้ารหัสก่อนออกจากระบบต้นทาง" — ซึ่งหมายความว่า encrypt บน client ก่อน upload
Client-side encryption ทำให้ S3/MinIO เห็นแค่ ciphertext ตลอด — แม้ storage provider เอง หรือ network administrator ก็ไม่สามารถอ่านข้อมูลได้

## Real World Incidents

**Incident 1 — Compliance audit ล้มเหลวเพราะ "encrypted in transit แต่ไม่ encrypted ที่ source" (Healthcare SaaS, 2022)**
ระบบ healthcare SaaS ใช้ HTTPS ในการ upload และ SSE-KMS บน S3 — ดูเหมือนจะปลอดภัยครบ
แต่ระหว่าง HIPAA compliance audit ผู้ตรวจพบว่า application server กับ S3 อยู่ใน VPC เดียวกัน และ traffic ผ่าน internal network โดยไม่มี end-to-end encryption จาก application ถึง storage
Auditor ตีความว่าเป็นการ transmit PHI โดยไม่มี encryption ที่ครอบคลุม "from point of origination" ตาม HIPAA Security Rule
ทีมต้องเพิ่ม client-side encryption ก่อน upload ทุกครั้ง และ update BAA (Business Associate Agreement) กับ AWS ใหม่

**Incident 2 — Internal network sniffing พบ plaintext medical image (Hospital IT, 2023)**
โรงพยาบาลแห่งหนึ่งใช้ MinIO on-premise สำหรับเก็บ DICOM image จากเครื่อง MRI
ทีม IT ตรวจพบว่า legacy network switch บน hospital floor ถูก misconfigure และ mirror traffic บางส่วนออกไป
Network capture ที่ทำในภายหลังพิสูจน์ว่า DICOM image ถูก upload โดยไม่มี client-side encryption — plaintext patient image ผ่าน hospital network ในรูปแบบที่อ่านได้
แม้ MinIO จะมี TLS แต่ TLS certificate ของ internal endpoint ไม่ได้รับการ verify อย่างถูกต้อง ทำให้ยิ่งแย่ขึ้น — client-side encryption จะป้องกันได้แม้ TLS ถูก bypass

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// "S3 มี SSE แล้ว ก็น่าจะพอ"
_, err = minioClient.PutObject(ctx, bucket, key, plaintext, -1,
    minio.PutObjectOptions{ContentType: "application/octet-stream"})
```

**พังตอนไหน:**
- Compliance requirement กำหนดว่า data ต้องเข้ารหัส "before leaving the originating system" — SSE ทำหลังจาก data ถึง S3 แล้ว
- Network packet capture ระหว่าง application กับ S3 endpoint บน internal network สามารถอ่านข้อมูลได้ถ้า TLS มีปัญหา
- On-premise MinIO ที่ใช้ self-signed cert ที่ไม่ verify — TLS ไม่ได้ protect จริง
- Multi-tenant S3 compatible storage — ไม่ไว้วางใจ storage provider ได้ 100%

**Root cause:**
SSE (Server-Side Encryption) เป็น "trust the provider" model — ถ้าต้องการ "zero trust" ต่อ storage layer ต้อง encrypt ก่อนที่ bytes จะออกจาก application process

## Explore First

### Go

ก่อนเขียน code ให้เปิด `crypto/aes`, `crypto/cipher`, และ MinIO SDK docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `aes.NewCipher(key []byte)` — key ต้องมีขนาดกี่ bytes สำหรับ AES-256? ถ้า key สั้นหรือยาวกว่านั้นจะเกิดอะไร?
- hint: `cipher.NewGCM(block)` — GCM ต้องการ `block.BlockSize()` เป็นอะไร? `NonceSize()` คืนค่าอะไร?
- hint: `gcm.Seal(dst, nonce, plaintext, additionalData []byte) []byte` — output มีขนาดเท่าไหร่เมื่อเทียบกับ plaintext? authentication tag อยู่ที่ไหนใน output?
- hint: `io.MultiReader` — ใช้ prepend nonce ไว้หน้า ciphertext ได้ยังไง? ทำไม MultiReader ถึงดีกว่า append bytes?
- hint: `minio.Client.PutObject` parameter `objectSize int64` — ถ้า encrypt แล้ว size จะเปลี่ยนไปเท่าไหร่? ต้อง calculate ล่วงหน้าหรือส่ง `-1`?
- hint: `crypto/rand.Read` vs `math/rand` — ทำไม nonce ต้องใช้ `crypto/rand`? ถ้าใช้ `math/rand` จะเกิดอะไรขึ้นในทาง cryptographic?

## Task

implement สองฟังก์ชันสำหรับ client-side encryption workflow:

```
// ClientSideEncryptUpload เข้ารหัส plaintext ด้วย AES-256-GCM แล้ว upload ไปยัง S3/MinIO
// format ที่เก็บใน S3: [12 bytes nonce][ciphertext + 16 bytes GCM tag]
func lientSideEncryptUpload(
    ctx cancellation context,
    s3Client ,
    bucket, key string,
    plaintext readable stream,
    aesKey list, // ต้องเป็น 32 bytes สำหรับ AES-256
) error

// ClientSideDecryptDownload download object จาก S3/MinIO แล้ว decrypt
// อ่าน nonce จาก 12 bytes แรก แล้ว decrypt ส่วนที่เหลือ
func lientSideDecryptDownload(
    ctx cancellation context,
    s3Client ,
    bucket, key string,
    aesKey list,
) (readable stream, error)
```

**หมายเหตุเรื่อง key management:** kata นี้รับ `aesKey` จาก caller โดยตรง — ใน production จริง key นี้ควรมาจาก envelope encryption (kata 21) ไม่ใช่ hardcode หรือ env var

## Requirements

- ใช้ AES-256-GCM เท่านั้น — key ต้องเป็น 32 bytes พอดี ถ้าไม่ใช่ return error ทันที
- สร้าง nonce ใหม่ด้วย `crypto/rand` ทุกครั้งที่ encrypt — ห้าม reuse nonce
- Format ใน S3: prepend nonce (12 bytes) ไว้หน้า ciphertext — `[nonce (12B)][ciphertext+tag]`
- ใช้ `io.MultiReader` เพื่อ prepend nonce โดยไม่ต้อง copy bytes ทั้งหมดเข้า memory ก่อน
- `ClientSideDecryptDownload` ต้องอ่าน nonce จาก 12 bytes แรกของ stream ก่อน แล้วค่อย decrypt ส่วนที่เหลือ
- ถ้า `aesKey` ไม่ใช่ 32 bytes ให้ return error พร้อมบอก length ที่ได้รับ

## Acceptance Criteria

- [ ] `ClientSideEncryptUpload` upload สำเร็จ และ bytes ที่เก็บใน S3 ไม่ตรงกับ plaintext
- [ ] `ClientSideDecryptDownload` return bytes ที่ตรงกับ original plaintext byte-for-byte
- [ ] encrypt/decrypt ข้อความ "hello world" ได้ถูกต้อง
- [ ] encrypt/decrypt ไฟล์ 10MB ได้ถูกต้อง
- [ ] encrypt ไฟล์เดียวกันสองครั้ง — ciphertext ต่างกัน (เพราะ nonce ต่างกัน)
- [ ] ส่ง `aesKey` ที่มีขนาดผิด (เช่น 16 bytes, 64 bytes) ต้อง return error ก่อน call MinIO API
- [ ] ดึง object ที่ถูก tamper (เปลี่ยน byte กลางๆ) แล้ว `ClientSideDecryptDownload` ต้อง return GCM authentication error

## Concepts Involved

- `AES-256-GCM` — Authenticated Encryption with Associated Data: ให้ทั้ง confidentiality และ integrity verification
- `Nonce` — ต้อง unique ต่อทุก (key, nonce) pair — collision ทำให้ cryptographic security พัง
- `GCM Authentication Tag` — 16 bytes ท้าย ciphertext ที่ใช้ detect tampering — `Open` return error ถ้า tag ไม่ตรง
- `io.MultiReader` — compose multiple readers เป็น stream เดียว โดยไม่ต้อง allocate buffer ใหม่
- `Client-side encryption` — encryption เกิดก่อน bytes ออกจาก process — storage provider ไม่เห็น plaintext เลย

## Production Reality

- **ใช้จริง:** AWS SDK v1 มี `s3crypto.NewEncryptionClient` ที่ implement client-side encryption อัตโนมัติ (ใช้ร่วมกับ KMS) — ใน production ใช้ตัวนี้แทนเขียนเอง
- **ทำ manual เมื่อ:** ใช้ MinIO หรือ S3-compatible storage ที่ไม่มี SDK encryption client, หรือต้องการ encrypt ด้วย algorithm เฉพาะ
- **pair กับ:** kata 21 (envelope encryption) เพื่อ key management ที่ถูกต้อง — `aesKey` ใน kata นี้ควรเป็น DEK ที่ได้จาก KMS GenerateDataKey
- **kata สอนว่า:** Client-side encryption เปลี่ยน trust model — จาก "trust the storage provider" เป็น "storage provider เห็นแค่ ciphertext" ซึ่งสำคัญมากใน regulated industries
