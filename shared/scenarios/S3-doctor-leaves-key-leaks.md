---
type: scenario
theme: hospital
difficulty: 3
prerequisite-katas: [digital-signature/07, digital-signature/08]
data: synthetic
---

<!-- ข้อมูลสังเคราะห์ทั้งหมด: ชื่อแพทย์, ผู้ป่วย, และเหตุการณ์ทั้งหมดเป็นข้อมูลสมมุติ -->

# Scenario S3 — Doctor Leaves: Key Revocation and Old Signatures

> **ข้อมูลสังเคราะห์ทั้งหมด:** บุคลากร, ผู้ป่วย, และเหตุการณ์ทั้งหมดเป็นข้อมูลสมมุติ

---

## บริบท

แพทย์ที่ลาออกหรือถูกเพิกถอนใบอนุญาต — signing key ของเขาต้องถูก revoke ทันที

แต่เกิดคำถามที่ยากกว่า: **signature ที่สร้างก่อน revocation ยัง valid ไหม?**

- เอกสารที่เซ็นตอนแพทย์ยังทำงานอยู่ → ควร valid
- เอกสารที่เซ็นหลัง revocation → ไม่ valid
- แต่ถ้า signature ไม่มี trusted timestamp — จะรู้ได้อย่างไรว่า sign เมื่อไหร่?

Kata นี้สำรวจปัญหา **key revocation + trusted timestamp** และ validity ของ signature เก่า

---

## ไทม์ไลน์สถานการณ์ (สมมุติ)

```
2024-01-01  นพ. ค. เริ่มทำงาน; ได้รับ signing key (kid: DOC-001-v1)
2024-03-01  เซ็น discharge summary ของ HN-00042 (ข้อมูลสมมุติ)
2024-06-01  นพ. ค. ลาออก; HR แจ้ง IT
2024-06-02  IT revoke kid: DOC-001-v1 ใน keyring
2024-06-05  บริษัทประกันส่ง discharge summary มาเพื่อ verify
             (เซ็นเมื่อ 2024-03-01 ก่อน revocation)
2024-07-01  พบว่า private key รั่ว (leaked บน flash drive ที่ลืม)
             ต้องพิจารณาว่า signature ที่ sign หลัง 2024-06-01 น่าเชื่อถือไหม
```

---

## Task

### Part A: Revocation model

1. ขยาย `Keyring` จาก kata 07 ให้รองรับ:
   - `RevokedAt time.Time` — เวลาที่ revoke
   - `ValidUntil *time.Time` — signature ที่สร้างก่อนเวลานี้ยังคง valid

2. เขียนฟังก์ชัน `VerifyWithRevocationPolicy`:
   ```go
   func VerifyWithRevocationPolicy(
       keyring *Keyring,
       keyID string,
       message, sig []byte,
       signedAt time.Time,  // timestamp ที่ trusted (ดู Part B)
   ) error
   ```
   - ถ้า key ยัง active → verify signature เท่านั้น
   - ถ้า key revoked และ `signedAt < RevokedAt` → valid (sign ก่อน revocation)
   - ถ้า key revoked และ `signedAt >= RevokedAt` → invalid

### Part B: Trusted timestamp

**ปัญหา**: `signedAt` ใน manifest (kata 05) มาจาก signer's server — ถ้า key รั่วแล้ว attacker backdate `signedAt` ได้

**RFC 3161 Timestamp Authority (TSA)**:
- หลังจาก sign document แล้ว ส่ง hash ไปยัง TSA
- TSA return timestamp token ที่ signed ด้วย TSA's private key
- Timestamp token พิสูจน์ว่า document hash นี้ถูก submit ก่อน timestamp นั้น

สำหรับ Kata นี้ implement **mock TSA**:

```go
type TimestampToken struct {
    DocumentHash string    // hex SHA-256 ของ document
    IssuedAt     time.Time // server time ของ TSA
    TSASig       []byte    // signature ของ TSA บน (documentHash + issuedAt)
    TSAID        string
}

// Mock TSA: sign timestamp token ด้วย TSA private key
func IssueMockTimestamp(docHash []byte, tsaPriv ed25519.PrivateKey, tsaID string) TimestampToken

// Verify timestamp token
func VerifyTimestamp(token TimestampToken, tsaPub ed25519.PublicKey) error
```

3. เขียน `SignWithTimestamp`:
   ```go
   func SignWithTimestamp(
       content []byte,
       signerPriv ed25519.PrivateKey,
       signerKeyID string,
       tsaPriv ed25519.PrivateKey,
       tsaID string,
   ) (sig []byte, token TimestampToken, err error)
   ```

### Part C: End-to-end scenario

4. Simulate ไทม์ไลน์ข้างบน:
   - Sign document ที่ T=2024-03-01 พร้อม timestamp token
   - Revoke key ที่ T=2024-06-02
   - Verify document ที่ T=2024-06-05 → **ต้องผ่าน** (signedAt < revokedAt)
   - Simulate attacker ที่สร้าง fake document หลัง key รั่ว พร้อม backdated timestamp:
     - ถ้า timestamp token ไม่ valid (no TSA sig) → reject
     - ถ้า timestamp token valid แต่ `token.IssuedAt > revokedAt` → reject

---

## Acceptance Criteria

- [ ] Document เซ็นก่อน revocation + valid timestamp: verify ผ่าน
- [ ] Document เซ็นหลัง revocation: verify fail (แม้ signature valid)
- [ ] Document ไม่มี timestamp token: verify fail (policy: require timestamp)
- [ ] Timestamp token ถูก forge (TSA sig ผิด): verify fail
- [ ] Backdated timestamp (issuedAt แก้ย้อนหลัง): fail เพราะ TSA sig cover issuedAt
- [ ] Key active + valid sig: verify ผ่าน (ไม่ต้องการ timestamp ถ้า key ยัง active — configurable)

---

## คำถามที่ไม่มีคำตอบเดียว (Design discussion)

หลังทำเสร็จแล้ว ลองคิดและ document เหตุผลสำหรับแต่ละข้อ:

1. ถ้า TSA ก็ถูก compromise — timestamp token เชื่อถือได้แค่ไหน?
2. Policy ควรเป็น "require timestamp เสมอ" หรือ "require timestamp เฉพาะหลัง revocation"?
3. Certificate expiry (cert หมดอายุ) vs key revocation — ต่างกันอย่างไรในแง่ policy?
4. ระยะเวลา validity window หลัง revocation ควรกำหนดอย่างไร?

---

## Prerequisite Katas

- **07-key-id-and-rotation**: keyring, revocation, key lifecycle
- **08-mini-ca-x509-chain**: trust chain, certificate validity

---

## หมายเหตุด้านกฎหมาย

> ความ valid ทางกฎหมายของลายเซ็นดิจิทัลหลัง revocation/expiry — **ต้องให้ legal/compliance ยืนยัน** สถานการณ์นี้มีจุดประสงค์ทางการศึกษาเท่านั้น
