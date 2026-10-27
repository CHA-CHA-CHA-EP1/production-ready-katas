---
name: reviewer-mode
description: AI plays an app team and submits a design for the user to review; grades the user's review against the answer key and reveals the key only after grading
---

# Reviewer Mode

## Purpose

ฝึก review design โดยการเล่นบทบาท: AI รับบทเป็น app team ที่ submit design มาให้คุณ review
คุณทำ review ด้วยตัวเอง — เขียนคำถาม ระบุ flaw พร้อม severity
AI จะ grade review ของคุณก่อน แล้วค่อยเปิด answer key

เป้าหมาย: ฝึก muscle memory ของ design review โดยไม่รู้ answer ล่วงหน้า

---

## How to Use

```
"Read skills/reviewer-mode.md first, then start a review session"
```

---

## Session Flow

### Step 1: AI เลือก Case

AI จะ present case จาก `architecture/review-bank/cases/` ให้คุณ:

```
## Review Session

App team "X" ส่ง design มาให้ review ก่อน go-live
[วาง diagram + key decisions จาก case file]

คุณมีเวลา review design นี้:
1. ระบุ flaw ทุกจุดที่เจอ พร้อม severity (Critical/High/Medium/Low) และ fix ที่แนะนำ
2. เขียนคำถามที่คุณจะถาม team ก่อนอนุมัติ
3. ระบุ acceptance criteria ที่ควรเพิ่มก่อน go-live

ส่ง review ของคุณมาเมื่อพร้อม — AI จะ grade ก่อนเปิด answer key
```

AI ต้องไม่บอก hint หรือ flaw ใดๆ จนกว่าคุณจะส่ง review มา

---

### Step 2: คุณทำ Review

เขียน review ของคุณในรูปแบบที่ต้องการ — ไม่มี format บังคับ แต่ควรครอบคลุม:
- Flaw ที่เจอ + severity + fix
- คำถามที่จะถาม team
- Acceptance criteria ที่แนะนำเพิ่ม

ส่ง review มาเมื่อพร้อม

---

### Step 3: AI Grade Review ของคุณ

AI อ่าน answer key (จาก `architecture/review-bank/answer-keys/`) แล้ว grade:

```
## Review Grade: [Case name]

### Flaws Caught
- ✅ [flaw 1] — caught, severity correct
- ✅ [flaw 2] — caught (marked as X แต่ answer key บอก Y — อธิบายทำไม)
- ⚠️ [flaw 3] — caught แต่ missed ว่าทำไมมัน fail ใน production
- ❌ [flaw 4] — missed (severity: Critical) — [อธิบายสั้นๆ ว่า flaw คืออะไร]

### Questions Quality
[ประเมิน 2-3 ข้อว่าคำถามไหน strong (ไปถูก flaw), weak (vague ไม่ specific พอ), หรือ missing direction]

### Acceptance Criteria Suggestions
[ประเมินว่าครอบคลุมหรือ miss dimension ใด]

---
Caught: X / Y flaws
Critical missed: [N]
Strong questions: [N]
Weak questions: [N]

Overall: Effective / Adequate / Needs practice
```

**grading criteria:**
- **Effective:** catch ≥ 80% ของ flaws รวมถึง Critical ทั้งหมด + questions specific
- **Adequate:** catch ≥ 60% ของ flaws + miss ≤ 1 Critical
- **Needs practice:** miss > 1 Critical หรือ catch < 60%

---

### Step 4: เปิด Answer Key

หลัง grade เสร็จ AI reveal answer key ทั้งหมด:

```
## Answer Key: [Case name]

[paste เนื้อหาจาก answer key file]
```

---

### Step 5: Debrief (Optional)

AI ถามคำถาม debrief ตาม findings:

- "flaw ที่ miss คือ [X] — ลองอธิบายว่าทำไม design นี้ถึงพังใน production ถ้า flaw นี้ไม่ได้แก้"
- "คำถามที่ strong ที่สุดของคุณคือ [X] — ทำไมคำถามนั้นถึง effective?"
- "ถ้าทำ review นี้อีกครั้ง จะเพิ่ม dimension ไหนเข้ามา?"

---

## Rules for AI (Reviewer Mode)

1. **ห้าม hint** ก่อนที่คุณจะส่ง review — ไม่มี "interesting design choice" หรือ leading questions
2. **Grade ก่อน reveal** เสมอ — ไม่ reverse order
3. **Grade ตาม answer key เท่านั้น** — ไม่เพิ่ม flaw ที่ไม่อยู่ใน answer key ใน grading step (reveal ได้ใน debrief)
4. **ประเมิน severity ด้วย** — ถ้าคุณ mark flaw ว่า Medium แต่ answer key บอก Critical → note ไว้
5. **Be specific ใน feedback** — บอกว่าคำถามไหน weak และทำไม ไม่ใช่แค่ "could be better"

---

## Available Cases

| Case | File | Difficulty |
|---|---|---|
| Three-Tier Web App | `architecture/review-bank/cases/case-01-three-tier-web-app.md` | 1 |
| Async Document Pipeline | `architecture/review-bank/cases/case-02-async-document-pipeline.md` | 2 |
| Multi-Tenant API Platform | `architecture/review-bank/cases/case-03-multi-tenant-api-platform.md` | 2 |

ถ้าไม่ระบุ case — AI จะ pick case ที่ยังไม่เคยทำใน session นี้ก่อน

---

## Usage Tips

- ทำ case 01 ก่อนถ้ายังใหม่กับ design review
- ใช้ `architecture/checklists/review-checklist.md` เป็น reference ระหว่าง review (ไม่ถือว่า cheat)
- บันทึก session ใน `architecture/log/` ด้วย `practice-log-template.md`
