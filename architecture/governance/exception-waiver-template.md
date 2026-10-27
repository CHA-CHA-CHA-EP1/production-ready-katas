# Exception / Waiver Request Template

ใช้ template นี้เมื่อต้องการ deviate จาก architecture standard หรือ policy
Exception ต้องมี expiry date และ remediation path — ไม่มี permanent exception

---

## Exception Request

**Reference:** EXC-[YYYY]-[NNN]
**Date submitted:** YYYY-MM-DD
**Submitted by:** [Name, Role, Team]
**Reviewed by:** [Domain Architect / ARB Chair]
**Status:** Pending / Approved / Rejected / Expired

---

## Standard Being Deviated

**Standard ID / Name:** [ชื่อ standard หรือ policy ที่ต้องการ exception]
**Standard requirement:** [อธิบายว่า standard กำหนดอะไรไว้]

---

## Deviation Requested

**What we want to do instead:** [อธิบาย solution ที่ต้องการ ซึ่ง deviate จาก standard]

**Scope:** [ระบุ service, environment, team ที่ exception นี้ apply — ยิ่ง narrow ยิ่งดี]

---

## Justification

**Why we cannot comply with the standard today:**
[เหตุผลที่ทำให้ conform ไม่ได้ตอนนี้ — technical constraint, timeline, third-party dependency, etc.]

**Risk of not getting this exception:**
[ถ้าไม่ approve exception จะเกิดอะไร — delay delivery, บล็อก critical function, etc.]

---

## Risk Assessment

**Risk introduced by this exception:**

| Risk | Likelihood | Impact | Mitigations in place |
|---|---|---|---|
| [risk 1] | High/Med/Low | High/Med/Low | [mitigation] |
| [risk 2] | High/Med/Low | High/Med/Low | [mitigation] |

**Residual risk level:** High / Medium / Low

---

## Remediation Plan

**Target compliance date:** YYYY-MM-DD *(ห้ามเกิน 12 เดือนจาก approval date)*

**Remediation steps:**
1. [step 1 — ทำอะไร ภายใน deadline ไหน]
2. [step 2]
3. ...

**Owner of remediation:** [Name, Role]

**How we will confirm compliance:** [วิธีที่จะ evidence ว่า remediation เสร็จ]

---

## Conditions of Approval (กรอกโดย Reviewer)

*ส่วนนี้กรอกโดย Domain Architect หรือ ARB Chair เมื่อ approve*

- [ ] Exception approve สำหรับ scope ที่ระบุเท่านั้น
- [ ] Expiry date: YYYY-MM-DD
- [ ] Conditions: [เงื่อนไขเพิ่มเติม ถ้ามี]
- [ ] Review checkpoint: [ถ้ามี interim review ก่อน expiry]

**Approved by:** [Name, Role]
**Approval date:** YYYY-MM-DD

---

## Renewal Process

ถ้าต้องการ extend exception:
- ยื่น renewal request ล่วงหน้าอย่างน้อย 30 วัน
- ต้องแสดง evidence ว่า remediation เป็นไปตาม plan (หรืออธิบายว่าทำไมไม่ได้)
- Exception ที่ expire โดยไม่ renew = standard apply ทันที

Renewal ต้องได้รับ explicit re-approval — ไม่ auto-renew
