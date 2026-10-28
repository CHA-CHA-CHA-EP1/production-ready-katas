---
type: scenario
theme: hospital
difficulty: 2
prerequisite-katas: [digital-signature/05, digital-signature/06, digital-signature/07]
data: synthetic
---

<!-- ข้อมูลสังเคราะห์ทั้งหมด: ชื่อแพทย์, ผู้ป่วย, ยา, และจำนวนเงินทั้งหมดเป็นข้อมูลสมมุติ -->

# Scenario S2 — Three-Tier Drug Approval (Non-Formulary)

> **ข้อมูลสังเคราะห์ทั้งหมด:** ชื่อแพทย์, ผู้ป่วย HN, ชื่อยา, และราคาทั้งหมดเป็นข้อมูลสมมุติที่ไม่เกี่ยวข้องกับบุคคลจริง

---

## บริบท

โรงพยาบาล Siam General (สมมุติ) มีนโยบาย: ยานอก formulary ราคาสูงกว่า 50,000 บาทต้องผ่านการอนุมัติสามชั้นก่อนสั่งจ่าย:

```
Tier 1: แพทย์ผู้ดูแล (Attending Physician)
Tier 2: หัวหน้าแผนก (Department Head)
Tier 3: ผู้อำนวยการฝ่ายการแพทย์ (Medical Director)
```

ระบบเดิม: email approval chain + manual PDF signing (ไม่ auditable, ไม่ tamper-evident)
ระบบใหม่: cryptographic multi-signer chain พร้อม audit log

---

## ข้อมูลสถานการณ์ (สมมุติ)

**ผู้ป่วย:** นาย ก. HN-2024-00042
**ยาที่ขอ:** Pembrolizumab (immunotherapy) - ไม่อยู่ใน formulary
**ราคา:** 85,000 บาท/dose
**เหตุผล:** NSCLC stage III, second-line treatment

**บุคลากร (สมมุติ):**
- Tier 1: นพ. ค. รหัส DOC-001 (attending)
- Tier 2: นพ. ง. รหัส DOC-050 (hematology dept head)
- Tier 3: นพ. จ. รหัส DOC-100 (medical director)

---

## Business Rules

ระบบต้องบังคับกฎต่อไปนี้:

1. **ลำดับการเซ็น**: ต้องเซ็น Tier 1 → 2 → 3 ตามลำดับเท่านั้น; ข้ามลำดับไม่ได้
2. **Role ต้องตรงกับ Tier**: role ของ signer มาจาก **server-side directory** เท่านั้น; ห้ามรับ role จาก request body
3. **ไม่เซ็นสองชั้น**: คนเดียวเซ็นไม่ได้เกินหนึ่ง tier
4. **แก้ document หลังเซ็นแล้ว**: ทุก signature ที่มีอยู่ต้อง invalidate ทันที
5. **Document/Patient binding**: signature set ของผู้ป่วย A ต้อง verify fail กับ document ของผู้ป่วย B
6. **Signing time**: มาจาก server clock เสมอ; ห้ามรับ timestamp จาก signer
7. **Reject → DRAFT**: ถ้าชั้นใดปฏิเสธ document กลับสู่ DRAFT และ signature ทั้งหมดเป็นโมฆะ

---

## Task

### Part A: Data model และ State machine

```go
type ApprovalStatus string
const (
    StatusDraft     ApprovalStatus = "DRAFT"
    StatusPendingT2 ApprovalStatus = "PENDING_TIER2"
    StatusPendingT3 ApprovalStatus = "PENDING_TIER3"
    StatusApproved  ApprovalStatus = "APPROVED"
    StatusRejected  ApprovalStatus = "REJECTED"
)

type DrugApprovalRequest struct {
    RequestID  string         // UUID — เป็นส่วนหนึ่งของ signed payload
    PatientHN  string         // HN ของผู้ป่วย — เป็นส่วนหนึ่งของ signed payload
    DrugCode   string
    DrugName   string
    Amount     float64
    Reason     string
    Status     ApprovalStatus
    Signatures []SignatureEntry // chain จาก kata 06
    AuditLog   []AuditEntry
}

type AuditEntry struct {
    Who        string // signer ID
    Tier       int
    Action     string // "signed", "rejected"
    ServerTime time.Time
    VerifyResult bool
}
```

### Part B: Approval flow

1. `SubmitForApproval(req *DrugApprovalRequest, doctorID string, priv ed25519.PrivateKey) error`
   - ตรวจว่า `doctorID` มี role "attending" จาก server-side directory
   - Sign payload (Tier 1) ด้วย chain จาก kata 06
   - Status → PENDING_TIER2

2. `ApproveTier2(req *DrugApprovalRequest, deptHeadID string, priv ed25519.PrivateKey) error`
   - ตรวจว่า `deptHeadID` มี role "dept-head"
   - ตรวจว่า `deptHeadID` ไม่ใช่คนเดียวกับ Tier 1 signer
   - Sign payload (Tier 2) — covers document + sig1
   - Status → PENDING_TIER3

3. `ApproveTier3(req *DrugApprovalRequest, directorID string, priv ed25519.PrivateKey) error`

4. `Reject(req *DrugApprovalRequest, signerID string, tier int) error`
   - Status → REJECTED
   - Clear signatures
   - Log rejection

5. `VerifyApprovalChain(req *DrugApprovalRequest, keyring *Keyring) error`
   - Verify ทุก signature ตาม chain จาก kata 06
   - ตรวจ patient binding (RequestID + PatientHN ใน payload)

### Part C: Stretch goal (optional)

Implement ด้วย real PDF สร้างด้วย library เช่น `github.com/pdfcpu/pdfcpu` หรือ plain HTML→PDF แล้วใช้ incremental signature append แล้วเปิดใน Adobe Acrobat เพื่อดู 3 signature layers เปรียบเทียบกับ JSON manifest approach

---

## Acceptance Criteria

- [ ] **Happy path**: Tier 1 → 2 → 3 chain verify ผ่าน; status = APPROVED
- [ ] **Skip tier**: Tier 2 approve ก่อน Tier 1 → error
- [ ] **Same person two tiers**: คนเดียว approve Tier 1 และ Tier 2 → error
- [ ] **Tamper after Tier 2**: แก้ document 1 byte → Tier 1 และ Tier 2 verification fail
- [ ] **Patient binding**: signature chain ของ HN-00042 verify fail กับ HN-00043 document
- [ ] **Server timestamp**: Tier 1 approval timestamp มาจาก server (ไม่มี timestamp parameter)
- [ ] **Rejection → DRAFT**: reject ที่ Tier 2 → status = REJECTED, signatures cleared
- [ ] **Audit log**: มี entry สำหรับแต่ละ action (who, tier, server time, verify result)
- [ ] **Role from server**: ระบบปฏิเสธถ้า caller อ้าง role ใน request body (ตรวจว่าไม่มี role parameter)

---

## Reviewer Notes

> **ส่วนนี้สำหรับ reviewer/instructor — ไม่แสดงให้ learner อ่านก่อน implement**

กับดักที่ซ่อนอยู่ซึ่ง learner มักเจอ:

1. **Version swap between tiers**: ถ้า Tier 1 sign document version A แล้วมีคนแก้เป็น version B ก่อน Tier 2 sign — ระบบที่ดีต้องตรวจจับ (chain signature ป้องกันโดยธรรมชาติ ถ้า implement ถูกต้อง)

2. **No document/patient binding**: chain signature ที่ไม่ bind `RequestID` และ `PatientHN` ใน payload — สามารถนำ chain ทั้งหมดไปแนบกับ drug request ของผู้ป่วยอื่นได้

3. **Trusting role from request**: ถ้า approval function รับ `role` จาก parameter แทนที่จะ lookup จาก directory — attacker escalate privilege ได้โดยแค่ส่ง `role: "medical-director"`

4. **Later signer not covering earlier signatures**: ถ้า Tier 2 sign เฉพาะ document (ไม่ include sig1) — ลบ sig1 ออกได้โดยที่ sig2 ยังคง valid

---

## Prerequisite Katas

- **05-context-binding-anti-rollback**: canonical manifest, patient/document binding
- **06-multi-signer-chain**: append-only chain, later signature covers earlier
- **07-key-id-and-rotation**: keyring, role-to-key mapping

---

## หมายเหตุด้านกฎหมาย

> ลายเซ็นดิจิทัลในเอกสารทางการแพทย์อาจอยู่ภายใต้ พ.ร.บ. ว่าด้วยธุรกรรมทางอิเล็กทรอนิกส์ พ.ศ. 2544 และระเบียบของสภาวิชาชีพ — **ต้องให้ legal/compliance ยืนยันก่อนใช้ในระบบจริง** สถานการณ์นี้มีจุดประสงค์ทางการศึกษาเท่านั้น
