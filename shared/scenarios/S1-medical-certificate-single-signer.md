---
type: scenario
theme: hospital
difficulty: 1
prerequisite-katas: [digital-signature/02, digital-signature/04]
data: synthetic
---

<!-- NOTE: This is the first scenario file — the frontmatter format above is newly established for this directory.
     All patient names, IDs, diagnoses, and amounts below are entirely synthetic (fictional). -->

# Scenario S1 — Medical Certificate: Single Signer

> **ข้อมูลสังเคราะห์ทั้งหมด:** ชื่อผู้ป่วย, HN, การวินิจฉัย, และจำนวนเงินทั้งหมดในสถานการณ์นี้เป็นข้อมูลสมมุติที่ไม่เกี่ยวข้องกับบุคคลจริง

---

## บริบท

โรงพยาบาล Siam General (สมมุติ) ออก **ใบรับรองแพทย์** (discharge summary / medical certificate) ให้ผู้ป่วยหลังจาก discharge แพทย์เซ็นเอกสาร แล้วส่งให้ผู้ป่วยนำไปยื่นกับบริษัทประกัน

บริษัทประกันต้องการ verify ว่า:
1. เอกสารออกโดยแพทย์จริง (authenticity)
2. ชื่อผู้ป่วย, วันที่รักษา, และยอดเงินค่ารักษาไม่ถูกแก้ไขหลังเซ็น (integrity)

ระบบปัจจุบันส่ง PDF ทาง email — ไม่มี signature ใดๆ

---

## สถานการณ์

**ผู้ป่วย (สมมุติ):** นาย ก. นามสกุล ข. HN-2024-00001
**แพทย์:** นพ. ค. ง., ใบอนุญาต 12345 (สมมุติ)
**วันที่ admit:** 2024-03-01
**วันที่ discharge:** 2024-03-05
**การวินิจฉัย:** Appendicitis (ICD-10: K35.9)
**ยอดค่ารักษา:** 45,000 บาท

เอกสารที่ต้องการ sign:
```json
{
  "hn": "HN-2024-00001",
  "patientName": "นาย ก. นามสกุล ข.",
  "diagnosis": "K35.9 Appendicitis",
  "admitDate": "2024-03-01",
  "dischargeDate": "2024-03-05",
  "totalAmount": 45000,
  "currency": "THB",
  "doctorLicense": "12345",
  "issuedAt": "<server timestamp>"
}
```

---

## Task

### Part A: สร้างระบบ sign/verify ฝั่งโรงพยาบาล

1. เขียนฟังก์ชัน `SignCertificate(doc MedicalCertificate, priv ed25519.PrivateKey, keyID string) SignedCertificate`
   - Canonical JSON ของ `MedicalCertificate` (ไม่รวม signature field)
   - `issuedAt` มาจาก server clock — ห้ามรับจาก caller
   - Sign SHA-256 digest ของ canonical JSON

2. เขียนฟังก์ชัน `VerifyCertificate(sc SignedCertificate, pub ed25519.PublicKey) error`
   - Re-compute canonical JSON, hash, verify signature

### Part B: ฝั่งบริษัทประกัน

3. บริษัทประกันได้รับ `SignedCertificate` (JSON) และ public key ของโรงพยาบาล
4. Verify certificate → ถ้าผ่าน อนุมัติ → ถ้าไม่ผ่าน reject

### Part C: แสดง attack scenario

5. แก้ `totalAmount` จาก 45,000 เป็น 145,000 ใน `SignedCertificate` แล้ว verify → ต้อง fail
6. แก้ `patientName` → ต้อง fail
7. เปลี่ยน signature เป็น all-zeros → ต้อง fail

---

## Requirements

- `issuedAt` ต้องมาจาก `time.Now().UTC()` ในฟังก์ชัน — ไม่รับจาก parameter
- Canonical form ต้องใช้ struct marshal (deterministic field order) ไม่ใช่ map
- Signature ต้อง cover ทุก field ใน certificate — ไม่ใช่แค่ `totalAmount`
- เอกสารในระบบ test ต้องระบุชัดว่าเป็นข้อมูลสังเคราะห์

---

## Acceptance Criteria

- [ ] Valid certificate: `VerifyCertificate` return nil
- [ ] `totalAmount` ถูกแก้: fail
- [ ] `patientName` ถูกแก้: fail
- [ ] Signature all-zeros: fail
- [ ] Public key ผิดคู่: fail
- [ ] ไม่มี `issuedAt` parameter ใน `SignCertificate`

---

## Trap ที่แฝงอยู่ (Learner ค้นพบเอง)

หลังทำ Part A-C สำเร็จแล้ว ลองคิดถึงสถานการณ์เหล่านี้:

1. **Same content, different patient**: signature ที่สร้างสำหรับ HN-00001 สามารถนำมาใช้กับ HN-00002 ได้ไหม ถ้า field อื่นๆ เหมือนกันทุกอย่าง?
2. **Replay old certificate**: certificate ที่ออกเมื่อปีที่แล้ว (issuedAt เก่า) สามารถยื่นได้ไหม? มี freshness check ไหม?
3. **Key rotation**: ถ้าโรงพยาบาลเปลี่ยน signing key — บริษัทประกันรู้ได้อย่างไรว่าต้องใช้ public key ไหน?

---

## Prerequisite Katas

- **02-sign-and-verify-bytes**: sign/verify bytes, handle return value
- **04-detached-signature-streaming**: streaming hash pattern สำหรับ file-based certificate
