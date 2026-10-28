---
type: scenario
theme: hospital
difficulty: 3
prerequisite-katas: [digital-signature/07, digital-signature/08, cloud-storage/26]
data: synthetic
---

<!-- ข้อมูลสังเคราะห์ทั้งหมด: ตัวเลขและตัวอย่างทั้งหมดเป็นข้อมูลสมมุติสำหรับการศึกษา -->

# Scenario S5 — Who Holds the Key? (System Design)

> **ข้อมูลสังเคราะห์ทั้งหมด:** ตัวเลขจำนวนแพทย์, ปริมาณ transaction, และรายละเอียดระบบทั้งหมดเป็นข้อมูลสมมุติสำหรับการศึกษา

> **Reviewable with:** `skills/review-system-design-kata.md`

---

## บริบท

โรงพยาบาลเครือข่าย Siam Hospital Group (สมมุติ) มีแพทย์ **10,000 คน** กระจายใน 50 สาขา ต้องการระบบลายเซ็นดิจิทัลสำหรับเอกสารทางการแพทย์ทุกประเภท

**ปริมาณ (สมมุติ):**
- เอกสารต่อวัน: ~50,000 ใบ
- Peak: ~500 เอกสาร/นาที ในช่วง morning round
- เอกสารเฉลี่ย: 200 KB
- เอกสารใหญ่สุด (imaging report): 50 MB

**Constraint ที่ต้องพิจารณา:**
- แพทย์บางคนทำงานที่บ้านหรือ remote clinic
- แพทย์ย้ายสาขาหรือลาออกบ่อย (~15% ต่อปี)
- ระบบต้องมี uptime ≥ 99.9%
- Audit log ต้องเก็บ 10 ปี

---

## สามแนวทาง

### Option A: Per-User Key, User Holds Private Key

แพทย์แต่ละคนมี key pair ของตัวเอง private key เก็บบน device ของแพทย์ (laptop, smart card, YubiKey)

```
Doctor 1: privKey1 (on device) / pubKey1 (in directory)
Doctor 2: privKey2 (on device) / pubKey2 (in directory)
...
Doctor 10,000: privKey10000 (on device) / pubKey10000 (in directory)
```

### Option B: Per-User Key in HSM/KMS with Remote Signing

แพทย์แต่ละคนมี key pair แต่ private key เก็บใน HSM/KMS signing ทำผ่าน API โดย authenticate ด้วย credential ของแพทย์

```
Doctor authenticates → API calls KMS.Sign(doctorKeyARN, digest) → signature
Private key ไม่เคยออกจาก HSM
```

### Option C: Single Org Key + Audit Log

โรงพยาบาลมี key เดียว ระบบ sign ในนามของแพทย์ แต่เก็บ audit log ว่าแพทย์คนไหน authorize signing

```
Org privKey → signs all documents
Payload includes: doctorID, timestamp, document hash
Audit log: doctorID, action, time, IP
```

---

## Task

เลือกแนวทางที่คิดว่าเหมาะสมที่สุด แล้ว **justify การตัดสินใจ** โดยครอบคลุมมิติต่อไปนี้:

### 1. Legal weight (น้ำหนักทางกฎหมาย)

- แต่ละแนวทางให้หลักฐาน non-repudiation ในระดับไหน?
- ถ้ามีข้อพิพาทในศาล — signature ของใครน่าเชื่อถือกว่า?
- (ไม่ต้องระบุตัวเลขกฎหมาย — แค่ reason ว่า option ไหน stronger)

### 2. Blast radius (ความเสียหายถ้า compromise)

- ถ้า private key รั่ว — กระทบกี่เอกสาร? กี่แพทย์?
- ถ้าระบบ central (Option B/C) ถูก compromise — กระทบอะไรบ้าง?
- ถ้าแพทย์คนหนึ่งถูก social engineer — กระทบแค่แพทย์คนนั้นหรือมากกว่า?

### 3. Key rotation (การหมุนเวียน key)

- Rotation ทำได้ง่ายแค่ไหนใน scale 10,000 keys?
- Signature เก่าหลัง rotation ยัง valid ไหม?
- ใครเป็นคน trigger rotation?

### 4. Throughput (ปริมาณ)

- 500 signatures/minute ทำได้ไหมกับแต่ละ option?
- Bottleneck อยู่ที่ไหน?

### 5. SPOF (Single Point of Failure)

- Option ไหนมี SPOF? อยู่ที่ไหน?
- Mitigation ทำได้อย่างไร?

### 6. วาดสถาปัตยกรรม

วาด diagram (ASCII หรือ Mermaid) สำหรับ option ที่เลือก แสดง:
- Doctor → Authentication → Signing Service → Document Store
- Where private key lives
- Audit log flow

---

## Output ที่ต้องการ

เอกสาร design (~1-2 หน้า A4) ที่ประกอบด้วย:

1. **Decision**: เลือก Option อะไร (หรือ hybrid)
2. **Comparison table**: เปรียบเทียบ 3 options ตาม 5 มิติข้างต้น
3. **Architecture diagram**: แสดง happy path ของ option ที่เลือก
4. **Key risks**: 3 ความเสี่ยงหลักของ option ที่เลือก พร้อม mitigation
5. **Open questions**: คำถามที่ยังไม่มีคำตอบ (ถาม legal? ถาม CISO?)

---

## Hints for Design

- Option A ให้ legal weight สูงสุด (private key อยู่กับแพทย์จริงๆ) แต่ key management เป็นฝันร้ายใน scale นี้
- Option C ง่ายที่สุด แต่ non-repudiation อ่อนที่สุด (ระบบ sign แทน แพทย์บอกว่า "ไม่ได้สั่ง" ได้)
- Option B เป็น middle ground ที่ production systems ส่วนใหญ่เลือก แต่ยังมี SPOF ที่ HSM/KMS

---

## Acceptance Criteria

- [ ] Decision ระบุชัดว่าเลือก option ไหน (หรือ hybrid อะไร)
- [ ] Comparison table ครอบคลุมทุก 5 มิติ
- [ ] Architecture diagram แสดง key flow ชัดเจน
- [ ] Key risks ระบุ 3 ข้อ พร้อม mitigation ที่ concrete
- [ ] Open questions ระบุ ≥ 2 ข้อที่ต้องการ input จากฝ่ายอื่น (legal, security, ops)

---

## Prerequisite Katas

- **07-key-id-and-rotation**: key lifecycle, rotation challenges
- **08-mini-ca-x509-chain**: certificate model, trust chain
- **26-kms-sign-api**: KMS-backed signing pattern (ตัวอย่างของ Option B)

---

## หมายเหตุด้านกฎหมาย

> การเลือก key management model สำหรับเอกสารทางการแพทย์มีผลต่อน้ำหนักทางกฎหมายของลายเซ็น — **ต้องให้ legal/compliance และฝ่าย CISO ยืนยันก่อน deploy ใน production** สถานการณ์นี้มีจุดประสงค์ทางการศึกษาเท่านั้น
