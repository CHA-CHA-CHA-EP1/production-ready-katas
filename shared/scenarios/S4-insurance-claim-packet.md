---
type: scenario
theme: hospital
difficulty: 3
prerequisite-katas: [digital-signature/04, digital-signature/05, cloud-storage/24, cloud-storage/25]
data: synthetic
---

<!-- ข้อมูลสังเคราะห์ทั้งหมด: ชื่อผู้ป่วย, HN, จำนวนเงิน, และรายละเอียดทั้งหมดเป็นข้อมูลสมมุติ -->

# Scenario S4 — Insurance Claim Packet via S3

> **ข้อมูลสังเคราะห์ทั้งหมด:** ชื่อผู้ป่วย, HN, รหัสการวินิจฉัย, และจำนวนเงินทั้งหมดเป็นข้อมูลสมมุติ

---

## บริบท

โรงพยาบาล Siam General ส่ง **claim packet** ให้บริษัทประกัน Siamlife Insurance (สมมุติ) ผ่าน S3 bucket ที่ใช้ร่วมกัน

Claim packet ประกอบด้วย:
- `claim.json` — ข้อมูล claim หลัก (ผู้ป่วย, วันที่, ยอดเงิน)
- `discharge-summary.pdf` — เอกสาร discharge (อาจขนาดใหญ่)
- `lab-results.pdf` — ผลแล็บ (optional)
- `manifest.json` — รายการไฟล์ทั้งหมดพร้อม hash และ metadata

โรงพยาบาลต้องการ **non-repudiation**: พิสูจน์ได้ว่าโรงพยาบาลส่ง packet นี้จริง และข้อมูลไม่ถูกแก้ไขระหว่างทาง

บริษัทประกันต้องการ **dispute resolution**: ถ้ามีข้อพิพาทเรื่องยอดเงิน มีหลักฐานว่า claim ไม่ถูกแก้ไขหลังจากโรงพยาบาลส่ง

---

## ข้อมูลสถานการณ์ (สมมุติ)

**Claim ID:** CLM-2024-00099
**ผู้ป่วย:** นาง ข. HN-2024-00099
**การวินิจฉัย:** DM type 2 with complications (E11.6)
**ยอดเรียกร้อง:** 128,500 บาท
**S3 Bucket:** `hospital-claims-bucket` (shared bucket, hospital มีสิทธิ์ write, insurer มีสิทธิ์ read)

---

## Task

### Part A: สร้าง signed claim manifest

```go
type ClaimFile struct {
    Name          string // ชื่อไฟล์
    S3Key         string // object key ใน bucket
    SHA256        string // hex SHA-256 ของ content
    SizeBytes     int64
    ContentType   string
}

type ClaimManifest struct {
    ClaimID      string
    PatientHN    string
    TotalAmount  float64
    Currency     string
    IssuedAt     int64  // Unix milliseconds, server clock
    Files        []ClaimFile
    // ไม่มี signature field ที่นี่ — sign JSON ของ struct นี้แล้วเก็บ sig แยก
}
```

1. `CreateClaimManifest(claimID, patientHN string, amount float64, files []ClaimFile) *ClaimManifest`
2. `SignManifest(manifest *ClaimManifest, priv ed25519.PrivateKey, keyID string) ([]byte, error)`
   - Return signature bytes
   - `IssuedAt` มาจาก `time.Now()` ในฟังก์ชัน

### Part B: Upload claim packet ไปยัง S3

3. `UploadClaimPacket`:
   - Upload แต่ละไฟล์ใน packet ด้วย pattern จาก kata 24 (`SignAndUpload`)
   - Upload `manifest.json` + signature (`manifest.json.sig`)
   - ทุก object ต้องมี `.sig` pair

4. ลำดับการ upload:
   - Upload ไฟล์ content ก่อน (parallel ได้)
   - Upload manifest สุดท้าย (หลังจากมี hash ของทุกไฟล์แล้ว)

### Part C: Verify โดยบริษัทประกัน

5. `VerifyClaimPacket`:
   - Download manifest และ signature
   - Verify signature ของ manifest
   - Download และ verify แต่ละไฟล์ใน manifest ด้วย pattern จาก kata 25
   - ตรวจว่า SHA256 ของแต่ละไฟล์ตรงกับที่ manifest ระบุ
   - Fail closed: ถ้าไฟล์ใดๆ fail → reject ทั้ง packet

### Part D: Dispute simulation

6. Simulate กรณีพิพาท:
   - โรงพยาบาล upload packet ปกติ
   - บุคคลที่สาม (ผู้โจมตี) แก้ `claim.json` เพื่อเพิ่ม `TotalAmount`
   - บริษัทประกัน verify → ต้องตรวจจับการแก้ไขได้

---

## Requirements

- ทุก object ใน S3 ต้องมี `.sig` pair
- Manifest ต้อง sign หลังจาก hash ทุกไฟล์แล้ว (ไม่ sign manifest ที่ยังไม่มี file hashes)
- `VerifyClaimPacket` ต้อง fail closed: ถ้าไฟล์ใดไม่ผ่าน verify → reject ทั้ง packet โดยไม่ process ไฟล์อื่น
- Error ต้องระบุว่าไฟล์ไหน fail และเหตุผล
- ทุก upload/download ต้อง streaming (ไม่ load ทั้งไฟล์เข้า RAM)

---

## Acceptance Criteria

- [ ] Upload และ verify packet ปกติ: ผ่านทุกขั้นตอน
- [ ] แก้ไฟล์ content หลัง upload: `VerifyClaimPacket` fail ที่ไฟล์นั้น
- [ ] แก้ manifest หลัง upload: manifest signature fail
- [ ] แก้ manifest signature (ไม่แก้ manifest): fail
- [ ] ไฟล์ใดๆ ไม่มี `.sig` pair: fail ด้วย error ที่ระบุชัดเจน
- [ ] ลำดับ upload: manifest ถูก upload หลัง content ทุกไฟล์
- [ ] `VerifyClaimPacket` fail ที่ไฟล์ใดๆ → reject ทั้ง packet

---

## Dispute Resolution Note

หลัง implement เสร็จแล้ว ตอบคำถามและ document เหตุผล:

1. ถ้ามีข้อพิพาทเรื่อง `TotalAmount` — หลักฐานอะไรที่พิสูจน์ว่าโรงพยาบาลส่ง amount ไหนมาจริงๆ?
2. Signature ของโรงพยาบาล + timestamp token (S3) เพียงพอสำหรับ legal dispute ไหม?
3. ถ้าบริษัทประกัน claim ว่า "ไม่ได้รับ packet" — มีหลักฐานอะไรบ้าง?

---

## Prerequisite Katas

- **04-detached-signature-streaming**: sign large file streaming
- **05-context-binding-anti-rollback**: manifest canonical form
- **24-sign-then-upload**: upload ด้วย detached signature
- **25-verify-before-use-download**: verify ก่อน process, fail closed

---

## หมายเหตุด้านกฎหมาย

> Non-repudiation ในบริบทของการเคลมประกันสุขภาพ — **ต้องให้ legal/compliance ยืนยัน** ว่าวิธีการ implement ตรงกับข้อกำหนดทางกฎหมาย สถานการณ์นี้มีจุดประสงค์ทางการศึกษาเท่านั้น
