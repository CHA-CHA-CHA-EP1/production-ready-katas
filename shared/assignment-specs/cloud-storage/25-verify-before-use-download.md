---
tier: cloud-storage
difficulty: 2
concepts: [digital-signature, fail-closed, verify-before-use, streaming-verification, s3-compatible]
provider: s3-compatible
---

# Kata 25 — Verify Before Use (Download)

## Context

Kata 23 สอนการ stream decrypt download — content ถูก decrypt เป็น stream ส่งต่อให้ caller ทันทีระหว่าง download

Kata นี้เพิ่ม signature verification เข้าไปใน download path — แต่มี **กับดักสำคัญ**:

> **ห้ามส่ง stream ให้ caller ก่อน verification ผ่าน**

ถ้า stream content ออกไประหว่าง verify (เพื่อ performance) และ verification fail ที่ byte สุดท้าย — caller ได้รับ content tampered ไปแล้ว และทำ rollback ไม่ได้

การออกแบบที่ถูกต้องต้อง **fail closed**: ถ้า verify ไม่ผ่าน caller ไม่ได้รับ byte เดียว

## Real World Incidents

### Streaming Verification Bypass (Plausible scenario)

ระบบ download firmware สำหรับ embedded device stream content ออกไปพร้อม verify signature ไปด้วย เพื่อ performance ระบบเริ่ม write ลง flash memory ระหว่าง download เมื่อ signature fail ที่ท้ายไฟล์ partial content ถูก write ลง flash ไปแล้ว — device boot ด้วย corrupted firmware และ brick

หลักการ: verification ต้อง complete ก่อน ถ้า operation นั้น irreversible หรือ downstream effect ไม่สามารถ rollback ได้

### TOCTOU ใน File Processing Pipeline (Plausible scenario)

Pipeline: download → verify → process โดยที่ "download" เขียนลง temp file แล้ว "verify" อ่าน temp file นั้น ปัญหา: ถ้า attacker แทนที่ temp file ระหว่าง verify และ process (TOCTOU) — verify ผ่านกับ version ดี แต่ process ใช้ version ร้าย วิธีแก้: verify stream ที่เดียวกับที่ process จะใช้ ไม่ใช่ verify สำเนา

## The Naive Way

```go
// naive: stream content ออกไปก่อน verify — fail closed ไม่ถูกต้อง
func downloadAndStream(ctx context.Context, mc *minio.Client, bucket, key string, w io.Writer) error {
    obj, _ := mc.GetObject(ctx, bucket, key, minio.GetObjectOptions{})
    defer obj.Close()

    sigBytes, _, _ := downloadSignature(ctx, mc, bucket, key)
    // คิดว่า verify ได้ระหว่าง stream...

    // ปัญหา: ถ้า copy ไปยัง w ก่อน verify เสร็จ — caller อาจได้ content ที่ tampered
    io.Copy(w, obj) // ← ส่ง stream ออกไปก่อน!
    return verifyAfter(sigBytes, ...) // ← verify ทีหลัง: สายไปแล้ว
}
```

## Explore First

อ่าน documentation ก่อน:

- `github.com/minio/minio-go/v7` — `GetObject()`, `Object` เป็น `io.ReadCloser`
- `io` — `io.TeeReader()`, `io.Pipe()`, `io.ReadAll()`
  - `io.TeeReader(r, w)` อ่านจาก r แล้ว copy ทุก byte ไป w ด้วย — ใช้ประโยชน์ได้อย่างไร?
  - `io.Pipe()` สร้าง synchronous in-memory pipe — useful สำหรับ pattern อะไร?
- `bytes` — `bytes.Buffer`
- Kata 04 — streaming hash pattern

คำถามชี้นำ:
- "Fail closed" หมายความว่าอะไรใน context นี้? ตรงข้ามกับ "fail open" อย่างไร?
- ถ้าต้องการ verify ก่อน stream แต่ไม่อยากใช้ RAM มากเกินไป — strategy คืออะไร?
- `io.TeeReader` + temp buffer อาจจะ stream hash ไปพร้อม download ได้ — แล้วค่อย verify ก่อนส่ง; แต่ถ้าไฟล์ใหญ่มาก temp buffer อาจใหญ่เกิน — ควรทำอย่างไร?
- ถ้า signature cover ทั้ง content + objectKey + bucket — ต้องรู้ bucket และ objectKey ก่อน verify ด้วย

ห้ามดู example ก่อนลองคิดเอง

## Task

เขียนฟังก์ชัน:

```go
// Download object จาก S3, verify signature, แล้วส่ง content ให้ dst
// CRITICAL: dst ไม่ได้รับ byte ใดๆ จนกว่า verification จะผ่าน
// ถ้า verify fail → return error, dst ไม่ได้รับ content
func VerifyAndDownload(
    ctx context.Context,
    mc *minio.Client,
    bucket, objectKey string,
    dst io.Writer,
    pub ed25519.PublicKey,
) error
```

Strategy ที่ยอมรับ (เลือกได้):
1. **Buffer then verify**: download ทั้งหมดลง buffer, verify, แล้วค่อย copy ไป dst — simple แต่ใช้ memory O(filesize)
2. **Download twice**: download ครั้งแรกเพื่อ hash, verify, download ครั้งสองเพื่อ stream ไป dst — ใช้ memory O(1) แต่ 2 network round-trips

เลือก strategy ที่เหมาะสมกับ use case และ document เหตุผลใน comment

## Requirements

- **Fail closed**: ถ้า verification fail ไม่ว่าด้วยเหตุผลใด — `dst` ต้องไม่ได้รับ byte ใดๆ
- `VerifyAndDownload` ต้อง download `.sig` object ก่อนหรือระหว่าง download content
- Signature verification ต้องใช้ public key ที่ caller ให้มา — ห้าม fetch public key จาก object metadata (untrusted)
- ถ้า `.sig` object ไม่มีอยู่ → return error ที่ชัดเจน (ไม่ใช่ "object not found" generic)
- Error ต้องบอกสาเหตุที่เข้าใจได้: "signature object not found", "signature verification failed", "content hash mismatch"

## Acceptance Criteria

- [ ] Valid object + valid `.sig`: content stream ไปยัง dst สำเร็จ
- [ ] Object ถูกแก้ 1 byte หลัง upload: `VerifyAndDownload` fail, dst ไม่ได้รับ content
- [ ] `.sig` ไม่มี: fail ด้วย error ที่ mention signature
- [ ] `.sig` ถูกแก้: fail
- [ ] `.sig` จาก object อื่น (key binding): fail
- [ ] ทดสอบ fail-closed: ใช้ `bytes.Buffer` เป็น dst แล้วตรวจว่า `buf.Len() == 0` หลัง fail
- [ ] Strategy ที่เลือกถูก document ใน comment พร้อมเหตุผล

## Concepts Involved

- **Fail closed**: operation ที่ security check fail ต้อง deny/block — ไม่ใช่ proceed แล้วค่อย log
- **Verify before use**: หลักการสำคัญของ cryptographic security — trust แล้วค่อย process ไม่ใช่ process แล้วค่อย trust
- **Buffer vs streaming tradeoff**: memory ใช้น้อย vs latency ต่ำ — ต้องเลือกตาม use case
- **TOCTOU**: verify สำเนาหนึ่ง แต่ use อีกสำเนาหนึ่ง — หลีกเลี่ยงโดย verify stream เดียวกัน

## Production Reality

ในระบบจริง:

- **File size matters**: ถ้าไฟล์เล็ก (< 100 MB) buffer แล้ว verify ก็ OK แต่ถ้าไฟล์ใหญ่ (GB) ต้องคิดถึง streaming strategy หรือ checksum-as-you-go
- **Download-twice strategy**: เหมาะสำหรับ pipeline ที่ object size ไม่แน่นอน และ bandwidth ถูก — แต่ไม่เหมาะถ้า egress cost สูง
- **Pre-signed URL**: ถ้าต้องการให้ browser download โดยตรงแต่ยังต้องการ verification — ต้องมี proxy verification layer (ดู kata 10 pattern)
- **S3 Object Integrity**: S3 SDK มี built-in checksum verification (CRC32, SHA-256) แต่นั่นคือ transfer integrity ไม่ใช่ digital signature — ไม่พิสูจน์ว่า uploader เป็นใคร

สิ่งที่ Kata นี้สอน: **verify before use, fail closed** — ไม่มีข้อยกเว้น ถ้า verification fail caller ไม่ได้รับ byte เดียว
