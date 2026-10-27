# Tiered Review — Matching Design to the Right Review Level

*Fictional process document สำหรับ practice*

---

## Why Tiered Review

ถ้าทุก design ต้องผ่าน ARB:
- ARB overwhelmed — review quality ตกลง
- Delivery teams ชะลอ — รอ ARB slot
- Low-impact change ใช้เวลาเท่ากับ high-impact change

ถ้าไม่มี review เลย:
- Technical debt สะสม
- Security gap ไม่ถูก catch
- Inconsistency ระหว่าง teams

Solution: match level of review to level of impact

---

## Review Tiers

### Tier 1: Delivery Team Self-Review

**Who:** Delivery team เองทำ review ก่อน implement
**When:** Design ที่ impact อยู่ในขอบเขตของ team เดียว ใช้ approved services ตาม standard และไม่มี new compliance scope

**Criteria (ต้องผ่านทั้งหมด):**
- [ ] ใช้เฉพาะ services ที่อยู่ใน tech radar zone "Adopt" หรือ "Trial"
- [ ] ไม่มี cross-team data flow ใหม่
- [ ] ไม่มี PII หรือ sensitive data class ใหม่
- [ ] ไม่เปลี่ยน network boundary หรือ security group ที่กระทบ service อื่น
- [ ] Cost impact ไม่เกิน budget threshold ของ team

**Output:** Design doc ที่ review ด้วย `architecture/checklists/review-checklist.md` + sign-off จาก tech lead

---

### Tier 2: Domain Architect Review

**Who:** Domain Architect หรือ Senior Architect ที่รับผิดชอบ domain นั้น
**When:** Design ที่ impact ข้ามหลาย service หรือ หรือใช้ "Trial" technology หรือมี compliance scope

**Criteria (ถ้าเข้าข่ายข้อใดข้อหนึ่ง → Tier 2):**
- กระทบ API หรือ data contract ที่ shared กับ team อื่น
- ใช้ technology ที่อยู่ใน "Trial" หรือ "Assess" zone
- มี new external dependency (third-party SaaS, external API)
- มี cost impact เกิน X THB/เดือน (TODO: กำหนด threshold ตาม budget จริง)
- มี new data flow ที่เกี่ยวข้องกับ PII หรือ financial data

**Process:**
1. Submit design doc + completed review checklist
2. Domain Architect schedule review session (async OK สำหรับ straightforward case)
3. Document feedback และ resolution
4. Domain Architect sign-off หรือ escalate ไป ARB

**Timeline:** Decision ภายใน 1 สัปดาห์

---

### Tier 3: ARB Review

**Who:** Architecture Review Board
**When:** High-impact design ที่ต้องการ organisation-level oversight

**Criteria (ถ้าเข้าข่ายข้อใดข้อหนึ่ง → ARB):**
- New architectural pattern ที่ยังไม่ได้ standardise
- Cross-domain data sharing ที่ต้องการ policy decision
- New cloud region หรือ account structure change
- Design ที่ต้องการ exception จาก existing standard
- Security หรือ compliance scope ที่กระทบหลาย team
- Technology ที่อยู่ใน "Hold" zone และ team ต้องการ exception
- Vendor / major infrastructure decision (ผูก contract, significant spend)

**Process:** ดู `arb-process.md`

**Timeline:** Decision ภายใน 2 สัปดาห์ (fast-track: 48 ชั่วโมง สำหรับ urgent)

---

## Triage Decision Matrix

| Impact | Compliance Scope | Technology | Review Tier |
|---|---|---|---|
| Team only | None | Adopt/Trial | Tier 1 |
| Multi-service | None | Adopt/Trial | Tier 2 |
| Any | New PII/sensitive | Any | Tier 2+ |
| Cross-domain | Any | Any | Tier 3 |
| Any | Regulatory change | Any | Tier 3 |
| Any | Exception needed | Hold | Tier 3 |

---

## Escalation

- Team สามารถ escalate ขึ้น tier ได้เองถ้าไม่แน่ใจ
- ARB Chair สามารถ de-escalate ลงมาได้ถ้า impact ต่ำกว่าที่คาด
- ถ้า domain architect ไม่พอใจ decision ของ team — escalate ไป ARB
