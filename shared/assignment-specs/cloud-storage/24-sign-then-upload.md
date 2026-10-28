---
tier: cloud-storage
difficulty: 2
concepts: [digital-signature, detached-signature, s3-object-metadata, upload, ed25519, non-repudiation]
provider: s3-compatible
---

# Kata 24 — Sign Then Upload

## Context

Kata 22 สอนการ encrypt ก่อน upload เพื่อให้ storage provider ไม่เห็น plaintext — แต่ encryption คุ้มครองแค่ **confidentiality** ไม่ใช่ **authenticity**

ถ้า bucket ถูก compromise หรือมีคนแอบแทนที่ object — downloader จะไม่รู้ว่าไฟล์ถูกเปลี่ยน เว้นแต่จะมี signature ที่ verifiable

Kata นี้ implement pattern "sign then upload" — sign object ก่อน upload แล้วเก็บ detached signature เป็น S3 object แยก (หรือ user-defined metadata บน object เดิม)

เป้าหมาย: ทุก object ใน bucket มี detached signature ที่ verifiable โดยไม่ต้อง download ทั้ง object ก่อน

## Real World Incidents

### Object Substitution บน S3 Bucket ที่มี Public ACL (Plausible scenario)

ระบบ CI/CD ของบริษัทหนึ่ง upload build artifact ขึ้น S3 bucket ที่เปิด public read โดยไม่ได้ sign ใครก็ได้ที่รู้ key naming pattern สามารถ upload object ที่ชื่อเดิมมาแทน (ถ้า bucket policy อนุญาต) และ pipeline ก็จะ deploy artifact นั้นโดยไม่รู้

การ sign artifact ก่อน upload และ verify ก่อน deploy จะตรวจจับ substitution นี้ได้ทันที

### Insider Threat บน Shared Storage (Plausible scenario)

พนักงานที่มีสิทธิ์เขียน S3 สามารถแทนที่ไฟล์สำคัญได้โดย overwrite object — S3 versioning ช่วยเรื่อง audit แต่ถ้าไม่ enable ก็ไม่มี history ถ้ามี signature ที่ผูกกับ original content และ uploader identity ก็จะตรวจจับ unauthorized replacement ได้

## The Naive Way

```go
// naive: upload แล้วเก็บ checksum ใน metadata — ไม่มี authentication
func uploadObject(mc *minio.Client, bucket, key string, data []byte) error {
    opts := minio.PutObjectOptions{
        UserMetadata: map[string]string{
            "content-sha256": fmt.Sprintf("%x", sha256.Sum256(data)),
        },
    }
    _, err := mc.PutObject(ctx, bucket, key, bytes.NewReader(data), int64(len(data)), opts)
    return err
    // ปัญหา: ใครแก้ object ก็ update metadata ได้ด้วย — hash ใน metadata ไม่มี authentication
}
```

## Explore First

อ่าน documentation ก่อน:

- `github.com/minio/minio-go/v7` — `PutObject()`, `PutObjectOptions.UserMetadata`
  - Object metadata สามารถเก็บข้อมูลอะไรได้บ้าง? มี size limit ไหม?
  - ถ้าเก็บ signature ใน metadata กับเก็บเป็น S3 object แยก (`.sig`) — trade-off คืออะไร?
- `io` — `io.TeeReader()`, `bytes.NewReader()`
- Kata 04 — detached signature streaming pattern

คำถามชี้นำ:
- Signature ควรเก็บที่ไหน: S3 user-defined metadata หรือ separate `.sig` object? ข้อดี/เสียของแต่ละ?
- ถ้า metadata มี size limit — signature 64 bytes ใส่ได้ไหม? base64 ของ 64 bytes มีขนาดเท่าไร?
- Key ของ `.sig` object ควรตั้งชื่ออย่างไร? เช่น `{key}.sig` หรือ `signatures/{key}`?
- ถ้า upload object สำเร็จแต่ upload signature fail — ควรทำอะไร?
- Signature ควร cover อะไรบ้าง? แค่ content bytes หรือรวม object key และ bucket ด้วย?

ห้ามดู example ก่อนลองคิดเอง

## Task

เขียนฟังก์ชัน:

```go
// Sign content stream แล้ว upload object + signature
// signature เก็บเป็น object แยก: objectKey + ".sig"
// contentSize = -1 ได้ (unknown size)
func SignAndUpload(
    ctx context.Context,
    mc *minio.Client,
    bucket, objectKey string,
    content io.Reader,
    contentSize int64,
    priv ed25519.PrivateKey,
    keyID string,
) error

// Download signature object แล้ว return เป็น bytes
// helper สำหรับ kata 25
func DownloadSignature(
    ctx context.Context,
    mc *minio.Client,
    bucket, objectKey string,
) (sigBytes []byte, keyID string, err error)
```

Format ของ `.sig` object:
```json
{
  "kid": "...",
  "contentSha256": "...",
  "objectKey": "...",
  "bucket": "...",
  "sig": "<base64-encoded 64-byte signature>"
}
```

Signature covers: `sha256(contentBytes || objectKey || bucket)` — binding ที่ป้องกัน move attack

## Requirements

- `SignAndUpload` ต้องอ่าน content **สองรอบ** หรือ buffer ชัดเจน: รอบแรกเพื่อ hash, รอบสองเพื่อ upload — หรือใช้ `io.TeeReader` ที่ buffer ใน temp file ถ้า content ไม่ rewindable
- Signature ต้อง cover ทั้ง content hash, object key, และ bucket name — ป้องกัน object ถูก copy ไป bucket อื่นแล้ว reuse signature
- ถ้า upload `.sig` object fail → function ต้อง return error (ไม่ silent fail)
- `.sig` object ต้องเป็น JSON ที่ parse ได้ — ไม่ใช่ raw binary

## Acceptance Criteria

- [ ] `SignAndUpload` สำเร็จ: object และ `.sig` object ถูก create ทั้งคู่
- [ ] `.sig` object เป็น valid JSON ที่มี field `kid`, `contentSha256`, `objectKey`, `bucket`, `sig`
- [ ] Signature covers content + objectKey + bucket (ทดสอบโดยเปลี่ยน bucket แล้ว verify ด้วย kata 25 → fail)
- [ ] `contentSize = -1` ทำงานได้ (unknown size upload)
- [ ] Upload `.sig` fail → `SignAndUpload` return error
- [ ] ไม่มี silent error ที่ทำให้ object upload สำเร็จแต่ `.sig` ไม่ถูกสร้าง

## Concepts Involved

- **Detached signature**: signature เป็น object แยก — object ต้นฉบับไม่ถูกแก้ไข
- **Object key binding**: รวม object key และ bucket ใน signed payload — ป้องกัน copy attack
- **Non-repudiation**: uploader ไม่สามารถปฏิเสธว่าไม่ได้ upload object นี้ (ถ้า private key ไม่รั่ว)
- **Atomicity limitation**: S3 ไม่มี transaction — upload object และ `.sig` เป็น two separate operations

## Production Reality

ในระบบจริง:

- **Object Lock**: S3 Object Lock (WORM) ร่วมกับ signature ให้ทั้ง immutability และ authenticity
- **S3 Event + Lambda**: verify signature หลัง upload ด้วย S3 Event notification (ดู kata 14 pattern) — ไม่เชื่อว่า uploader verify เอง
- **Envelope encryption + signing**: รวม kata 21, 22, และ 24 — encrypt ก่อน sign (หรือ sign ก่อน encrypt ตามต้องการ)
- **KMS signing**: แทนที่จะใช้ private key ใน application ใช้ KMS sign API (ดู kata 26) — private key ไม่ออกจาก KMS

สิ่งที่ Kata นี้สอน: **sign → upload, ไม่ใช่ upload → sign** — signature ต้อง cover content ที่ verifiable ก่อน object ถูก consider "trusted"
