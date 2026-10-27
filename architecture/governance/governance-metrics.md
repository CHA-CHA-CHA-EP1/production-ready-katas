# Governance Metrics

*Fictional metrics framework สำหรับ practice*

วัด EA governance effectiveness ด้วย metrics ที่ leading indicator ไม่ใช่แค่ lagging indicator

---

## Why Measure Governance

ถ้าวัดไม่ได้ก็ปรับปรุงไม่ได้ metrics ช่วย:
- ระบุ bottleneck ใน review process
- แสดงให้ stakeholders เห็นว่า governance ทำงาน (หรือไม่ทำงาน)
- Drive continuous improvement
- เป็น leading indicator ของ risk ก่อนที่ incident จะเกิด

---

## Tier 1: Process Health Metrics

### Review Lead Time

**What:** เวลาตั้งแต่ submit design จนได้รับ decision

| Zone | Target |
|---|---|
| Tier 1 (self-review) | < 2 working days |
| Tier 2 (domain architect) | < 5 working days |
| Tier 3 (ARB) | < 10 working days |
| Fast-track (security/compliance) | < 48 hours |

**Why it matters:** ถ้า lead time นาน teams จะ bypass review process เพื่อ meet deadline

**How to track:** Log submission date และ decision date ทุก review

---

### Review Completion Rate

**What:** % ของ design ที่ผ่าน required review ก่อน go-live

**Target:** > 95%

**Why it matters:** ถ้า < 95% = teams ข้าม review → architectural risk สะสม

**How to track:** Sample production deployments ทุกเดือน check ว่ามี review sign-off ไหม

---

### Review Outcome Distribution

**What:** % ของ reviews ที่ได้ Approved / Conditional / Rejected

| Outcome | Healthy range | Signal ถ้าผิด range |
|---|---|---|
| Approved | 60-75% | ถ้าสูงเกิน = กำลัง rubber-stamp |
| Conditional | 20-30% | ถ้าต่ำเกิน = ไม่ catch issue จริง |
| Rejected | 5-15% | ถ้าสูงเกิน = standard ไม่ clear หรือ teams ไม่ได้รับ guidance |

---

## Tier 2: Compliance Metrics

### % Workloads Compliant with Critical Standards

**What:** จาก sample check — กี่ % ของ production workloads ที่ comply กับ critical standards

**Standards ที่ check (ตัวอย่าง):**
- Secrets ไม่อยู่ใน env vars
- RDS เปิด Multi-AZ
- S3 Block Public Access enable
- CloudTrail เปิดทุก region

**Target:** > 90% สำหรับ critical standards

**How to track:** AWS Config rules หรือ Security Hub findings รายงานทุกเดือน

---

### Exception Count and Age

**What:** จำนวน active exceptions และ average age

| Metric | Signal |
|---|---|
| Exception count เพิ่มขึ้น | Standards อาจ too strict หรือ teams ขาด resource |
| Exception อายุเกิน expiry โดยไม่ renew | Process enforcement หย่อน |
| Exception ซ้ำหลาย teams สำหรับ standard เดียวกัน | Standard นั้นอาจต้อง revisit |

**Target:** < X active exceptions (TODO: set based on org size), 0 expired exceptions

---

### Standard Coverage

**What:** % ของ technology decisions ที่ covered โดย existing standard

**Why it matters:** ถ้า standard ไม่ครอบคลุม technology ที่ teams ใช้ → teams ตัดสินใจเองโดยไม่มี guidance

**How to track:** ทุก ARB review — เกิดขึ้นเพราะ "ไม่มี standard ครอบคลุม" กี่ % ของ case?

---

## Tier 3: Outcome Metrics

### Architecture Debt Trend

**What:** จำนวน known architecture issues (จาก review findings ที่ยัง open)

**Categories:**
- Critical: security หรือ compliance risk
- High: reliability risk
- Medium: technical debt

**Target:** Critical = 0 open > 30 days, trending down overall

---

### Post-incident Review Findings Related to Architecture

**What:** ใน post-incident reviews — กี่ % มี finding ที่ "architecture review ควรจะ catch"?

**Why it matters:** ถ้าสูง = review process ไม่ effective ต้องปรับ checklist และ questions

---

## Dashboard

ควรมี dashboard ที่แสดง:

```
Governance Health — [Month YYYY]

Review Process:
├── Avg lead time (Tier 2): X days    [target: <5]
├── Completion rate: X%               [target: >95%]
└── Outcome: Approved X% / Cond X% / Rejected X%

Compliance:
├── Critical standards compliance: X% [target: >90%]
├── Active exceptions: X              [trend: ↑↓→]
└── Exceptions past expiry: X         [target: 0]

Outcomes:
└── Open critical findings: X         [target: 0 >30 days]
```

---

## Anti-patterns

- **Vanity metrics:** "ทำ 50 reviews เดือนนี้" — ไม่บอกว่า review quality ดีหรือเปล่า
- **Lagging only:** วัดแต่ incident count — รู้หลัง damage แล้ว
- **Gaming:** ถ้า team รู้ว่าถูกวัดจาก "% compliant" จะ game ระบบ → audit แบบ sample random จะ honest กว่า
