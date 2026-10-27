# Architecture Practice Track

คอลเลกชัน kata และ exercise สำหรับฝึก Solution Architecture และ Enterprise Architecture — เน้น scenario problems ไม่ใช่ quiz

---

## For whom

Engineers ที่ก้าวเข้าสู่ SA / EA role หรืออยากเข้าใจว่า architect คิดยังไงเวลา review design ของ app team:

- คุณเคย design systems ในระดับ service / application แล้ว
- คุณอยากเรียนรู้ว่า design decision ระดับ account, network, และ organization มีผลยังไง
- คุณเรียนรู้ได้ดีจาก scenario จริง — ไม่ใช่จาก slide หรือ quiz

---

## How to practice

**รูปแบบหลัก: Kata**

1. อ่าน kata spec ใน `katas/` — อ่าน Context และ Naive Design ให้เข้าใจก่อน
2. ทำ Explore First — เปิด AWS docs ที่ระบุไว้ อ่านด้วยตัวเอง (อย่า skip)
3. วาด diagram ก่อนอ่านเฉลยใดๆ — ความผิดพลาดในขั้นนี้คือส่วนที่เรียนรู้ได้มากที่สุด
4. กรอก `templates/key-decisions-template.md` อธิบายว่าเลือกอะไรและทำไม
5. Submit ไว้ที่ `submissions/YYYY-MM-DD-<kata-name>/`
6. Review ด้วย `skills/review-system-design-kata.md` หรือ `skills/reviewer-mode.md`

**รูปแบบเสริม: Post-mortem Reading**

อ่าน incident ใน `post-mortems/` แล้วตอบคำถามว่า:
- design review ก่อน incident ควรถามอะไร
- จะออกแบบยังไงให้ blast radius เล็กลง

**รูปแบบเสริม: Design Review**

ใช้ `review-bank/` — AI จะ present design ของ "app team" ให้คุณ review ก่อนที่ answer key จะถูกเปิดเผย (ดู `skills/reviewer-mode.md`)

---

## How to submit

```
architecture/submissions/
└── YYYY-MM-DD-<kata-name>/
    ├── diagram.png          # หรือ .svg / .drawio
    ├── decisions.md         # กรอกจาก templates/key-decisions-template.md
    └── notes.md             # (optional) ข้อสังเกต คำถาม สิ่งที่ยังไม่แน่ใจ
```

`submissions/` อยู่ใน `.gitignore` — งาน practice ของคุณเป็น private โดย default
ถ้าอยากเก็บไว้ใน repo ให้ลบ `submissions/` ออกจาก `.gitignore` ด้วยตัวเอง

---

## How to review a submission

```
"Read skills/review-system-design-kata.md first,
 then review this design [image/diagram] + [decisions.md text]
 against kata spec [spec-path]"
```

---

## Track structure

```
architecture/
├── README.md              # ไฟล์นี้
├── ROADMAP.md             # topic ทั้งหมดพร้อม level และ priority
├── concepts/              # concept docs สั้นๆ — สร้างตามต้องการ
├── katas/
│   ├── 01-cloud-foundation/
│   ├── 02-design-review/
│   ├── 03-resilience-dr/
│   ├── 04-security-iam/
│   ├── 05-observability-cost/
│   ├── 06-async-messaging/
│   ├── 07-adr/
│   └── 08-compliance-mapping/
├── governance/            # EA governance practice
├── post-mortems/          # incident reading exercises
├── review-bank/
│   ├── cases/             # designs with planted flaws
│   └── answer-keys/       # เปิดดูหลัง review เท่านั้น
├── checklists/
├── labs/                  # Terraform labs (coming later)
├── submissions/           # งาน practice ของคุณ (gitignored by default)
└── log/                   # practice log
```

---

## Relationship to engineering katas

Track นี้ independent จาก `go/`, `rust/`, `zig/` — ไม่มี Makefile sync
Engineering katas อยู่ใน `shared/assignment-specs/` ตามเดิม ไม่ถูกแตะ
