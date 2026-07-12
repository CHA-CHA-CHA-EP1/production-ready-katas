---
name: review-system-design-kata
description: Review guide for system design kata submissions — reads diagram image + decisions text and evaluates design quality
---

# System Design Kata Review Guide

## How to use

**Required inputs:**
1. **Kata spec path** — e.g. `shared/assignment-specs/cloud-storage/01-object-upload.md`
2. **Diagram image** — screenshot หรือรูปที่วาด architecture (PNG/JPG)
3. **Key Decisions** — text อธิบายว่า *ทำไม* ถึงเลือก design นั้น (required — image อย่างเดียวไม่พอ)

**Key Decisions template (learner ต้อง fill ก่อน submit):**
```
## Key Decisions
- เลือก [component X] เพราะ: ...
- ไม่ใช้ [alternative Y] เพราะ: ...
- จุดที่ยังไม่แน่ใจ: ...

## Assumptions
- traffic: ...
- data size: ...
- consistency requirement: ...
```

**Usage:**
```
"Read skills/review-system-design-kata.md first,
 then review this design [image] + [key decisions text]
 against kata spec [spec-path]"
```

---

## Review Dimensions

### 1. Constraint Satisfaction
- Design ตอบ requirements ที่ kata spec กำหนดได้ไหม (scale, latency, budget, consistency)?
- มี assumption ที่ขัดกับ constraints ที่กำหนดไหม?
- **Acceptance Criteria check:** ไล่ทีละ criterion ว่า design ตอบได้ไหม และ *ยังไง*

### 2. Bottleneck Identification
- Learner ระบุ bottleneck ของ naive design ได้ถูกต้องไหม?
- Design ใหม่แก้ bottleneck นั้นจริงๆ หรือแค่ย้ายไปที่อื่น?
- มี bottleneck ใหม่ที่เกิดจาก design นี้เองไหม?

### 3. Failure Modes
- ถ้า component หลักแต่ละตัว down ระบบทำอะไร?
- มี single point of failure ไหม?
- Data loss scenario: เกิดขึ้นได้ไหม ภายใต้เงื่อนไขอะไร?
- Learner คิดถึง failure ใน Key Decisions หรือ assume ว่าทุกอย่าง happy path?

### 4. Trade-off Articulation
- Learner อธิบายได้ว่า *ทำไม* ถึงเลือก component/pattern นั้นไหม?
- มีการพูดถึง alternative ที่ reject ไปพร้อม reason ไหม?
- Trade-off ที่เลือกสมเหตุสมผลกับ constraints ที่กำหนดไหม?

### 5. Scalability Ceiling
- Design นี้รับได้ถึงแค่ไหน ก่อนที่จะต้อง redesign?
- สิ่งแรกที่จะพังเมื่อ load เพิ่มขึ้น 10x คืออะไร?
- Learner รู้ ceiling นี้ไหม หรือ assume ว่า scale ได้ไม่จำกัด?

### 6. Operability
- ถ้า system พังตอนตี 2 จะรู้ได้ยังไงว่าพังที่ไหน?
- มี observability ใน design ไหม (logging, metrics, tracing)?
- Deploy / rollback ทำได้ยากแค่ไหน?

### 7. Production Gap
- มี assumption ที่ hold ใน whiteboard แต่พังใน real system ไหม? เช่น:
  - network ไม่ reliable
  - clock drift ระหว่าง nodes
  - partial failure (บาง node down บางตัว)
- Design นี้ใกล้เคียงกับ pattern ที่ production systems ใช้จริงไหม?

### 8. Kata Quality
- Kata spec ยังสมเหตุสมผลไหม หรือ constraints ขัดแย้งกันเอง?
- มี acceptance criteria ที่ควรเพิ่มไหม จาก design ที่เห็น?

---

## Output Format

```
## Design Review: [kata name]

### [Dimension] [✅ / ⚠️ / ❌]
[Short summary]
[ถ้ามีปัญหา — อธิบายว่าเกิดอะไรใน production + ควรแก้ยังไง]

### Acceptance Criteria
- [x] criterion 1 — ตอบได้เพราะ [reason]
- [ ] criterion 2 — FAILED: design ยังไม่ address [what]

---
Must address before prod: [N] items
Worth discussing: [N] items
Kata spec suggestions: [yes / none]
```

**Legend:**
- ✅ Pass
- ⚠️ Should discuss — ไม่ blocking แต่มี risk
- ❌ Must address — จะพังใน production ภายใต้ scenario ที่ realistic

---

## After Review: Reinforce Understanding

### Explain It Back
Pick 1-2 findings ที่สำคัญสุด แล้วถามให้ learner อธิบายกลับในแบบของตัวเอง

ตัวอย่าง:
- "ทำไม queue ถึงช่วยแก้ bottleneck ได้ — อธิบาย mechanism จริงๆ ว่ามันย้าย pressure ไปที่ไหน"
- "ถ้า Kafka down ตอน event กำลัง in-flight จะเกิดอะไรขึ้น — design ของคุณจัดการยังไง"
- "Single point of failure ที่เจอใน design คืออะไร และ tradeoff ของการแก้มันคืออะไร"

ถ้าอธิบายถูก → ยืนยันและไปต่อ
ถ้าอธิบายผิดหรือ incomplete → clarify ก่อน link concept doc ที่เกี่ยว

### Pattern Connections
ถ้า finding นี้คล้ายกับ kata อื่นหรือ concept doc ที่มี → call it out:
- "นี่คือ TOCTOU class เดียวกับที่เจอใน `01-whole-file-read` — check แล้ว act มีช่องโหว่ระหว่างกัน"
- "Single writer bottleneck นี้คือ root cause เดียวกับ incident ใน kata spec"

---

## Design Stress Test

หลังจาก Explain It Back เสร็จ ให้ถามว่า:

> "อยากลอง Design Stress Test ไหม? จะเอา design ของคุณไป throw scenarios ที่ระบบจริงเจอ แล้วดูว่าตอบได้ไหม"

ถ้าตอบใช่ → throw 3 scenarios ทีละข้อ รอ learner ตอบก่อนเฉลย:

**Scenario format:**
```
## Stress Test [N/3]

Scenario: [สถานการณ์ที่เป็น realistic production scenario]
ใน design ของคุณ — เกิดอะไรขึ้น?
- ระบบ handle ได้ไหม?
- ถ้าได้ — mechanism คืออะไร?
- ถ้าไม่ได้ — พังที่ไหนก่อน?

(ตอบก่อน ยังไม่เฉลย)
```

**ตัวอย่าง scenarios:**
- Traffic spike 10x ในเวลา 30 วินาที
- Database node หนึ่งตัว down กลางการ write
- Consumer lag เพิ่มขึ้นเรื่อยๆ จนถึง 1 ชั่วโมง
- Network partition ระหว่าง region
- Disk full บน worker node

เลือก scenarios ที่ตรงกับ failure modes ที่ design ยังไม่ได้ address

หลัง learner ตอบ:
- ถ้าถูก → ยืนยัน + อธิบายว่าทำไม scenario นี้ถึงเจอบ่อยใน production
- ถ้าผิด → ถามให้คิดใหม่ก่อน 1 ครั้ง แล้วค่อยเฉลย + เชื่อมกลับไปที่ finding ใน review
