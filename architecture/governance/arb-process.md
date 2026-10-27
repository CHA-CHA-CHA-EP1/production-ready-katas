# ARB Process — Architecture Review Board

*Fictional process document สำหรับ practice — ปรับใช้กับ context จริงได้*

---

## Purpose

Architecture Review Board (ARB) ทำหน้าที่ review และ approve design ที่มี impact สูงพอที่ need oversight ระดับ organisation เป้าหมายคือ:

1. ป้องกัน technical debt ที่จะกลายเป็น constraint ในอนาคต
2. ให้ second opinion ที่ challenge assumption
3. เป็น checkpoint สำหรับ security, compliance, และ architectural standard
4. ไม่ใช่ gatekeeping เพื่อชะลอ delivery

---

## Who Submits to ARB

ดู `tiered-review.md` สำหรับ decision matrix ว่า review ไหนต้อง escalate มา ARB
โดยทั่วไป: design ที่มี cross-team impact, ใช้ new technology, หรือมี compliance scope

---

## Intake Process

### Step 1: ยื่น Intake Form (ก่อน detailed design)

ยื่น Intake Form ภายใน 2 สัปดาห์ก่อนต้องการ decision
Intake Form ประกอบด้วย:
- Problem statement — ทำไมถึงต้อง build นี้?
- High-level approach — ทิศทาง solution คืออะไร?
- Impact assessment — กระทบ team ไหน, service ไหน, user กี่คน?
- Compliance flag — มี data sensitivity, regulatory scope, หรือ security impact ไหม?
- Requested decision date

ARB Chair จะ acknowledge ภายใน 2 working days และ assign reviewer

### Step 2: Triage

ARB Chair triages ทุก submission:

| Criteria | Action |
|---|---|
| Impact ต่ำ, conform กับ standard | Route ไป Delivery Team self-review |
| Impact ปานกลาง | Route ไป Domain Architect review |
| Impact สูง หรือ cross-domain | Schedule ARB session |
| Urgent (security, compliance) | Fast-track — ARB session ภายใน 48 ชั่วโมง |

### Step 3: Design Submission

หลัง triage confirm ว่าต้อง ARB:
- ส่ง detailed design อย่างน้อย 5 working days ก่อน ARB session
- รูปแบบ: Architecture diagram + ADR (ใช้ `templates/adr-template.md`) + Key Decisions
- ระบุ assumption, constraint, และ alternative ที่ reject ไปแล้ว

### Step 4: ARB Session

- Duration: 30-60 นาที
- Format: Presenter walk through design (15 นาที) → Q&A และ challenge (30 นาที) → deliberation (15 นาที)
- Quorum: ARB Chair + อย่างน้อย 2 domain architects

### Step 5: Decision

ARB ออก decision ใน 3 รูปแบบ:

**Approved** — design proceed ได้ตามที่ submit
- ระบุ conditions หรือ recommendations ที่ non-blocking

**Conditional Approval** — proceed ได้ แต่ต้องทำตาม conditions ก่อน go-live
- conditions ต้องชัดเจน measurable และมี owner
- ต้องกลับมา confirm ว่า conditions ทำแล้วก่อน launch

**Rejected** — design ไม่ผ่าน ต้อง revise
- ต้องระบุ reason ที่ชัดเจน ไม่ใช่แค่ "ไม่ดีพอ"
- ให้ feedback เชิง constructive และ suggest path forward
- team สามารถ revise แล้ว resubmit ได้

---

## Decision Record

ทุก ARB decision ต้องถูกบันทึกใน:
- ADR ที่ decision เป็น "Accepted" / "Rejected by ARB"
- ARB decision log (date, submitter, brief summary, outcome, conditions ถ้ามี)

---

## Anti-patterns ที่ ARB ควรหลีกเลี่ยง

- **Rubber stamping** — approve ทุกอย่างโดยไม่ challenge = ARB ไม่มีคุณค่า
- **Nitpicking implementation** — ARB review architecture ไม่ใช่ code
- **Moving goalposts** — require สิ่งที่ไม่ได้ระบุใน standard → teams หลีกเลี่ยง ARB
- **Slow decisions** — ถ้า decision ใช้เวลานานกว่า 2 สัปดาห์ team จะ bypass
