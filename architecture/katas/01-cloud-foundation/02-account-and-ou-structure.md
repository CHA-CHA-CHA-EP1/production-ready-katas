---
tier: architecture/01-cloud-foundation
difficulty: 2
concepts: [aws-organizations, ou-design, scp, account-vending, landing-zone]
prerequisites: [architecture/katas/01-cloud-foundation/01-cidr-planning]
---

# Kata 02: Account and OU Structure

## Context

AWS Organizations ให้คุณจัดกลุ่ม account ด้วย Organizational Unit (OU) แล้ว apply Service Control Policy (SCP) ที่ระดับ OU ทำให้ทุก account ใต้ OU นั้นได้รับ guardrail เดียวกัน

แต่หลายองค์กรออกแบบ OU structure ผิด — มักจะ mirror org chart หรือ mirror team name ซึ่ง AWS แนะนำไม่ให้ทำ เพราะ org chart เปลี่ยนบ่อย แต่ control requirement ที่ใช้จัดกลุ่ม account ควร stable กว่า

kata นี้เริ่มจาก naive design 2 แบบที่พบบ่อย แล้วให้คุณออกแบบ structure ที่ดีกว่า

## Real World Incidents

> ไม่มี public post-mortem เรื่อง OU design โดยตรงที่ verify ได้ในเซสชันนี้
> ด้านล่างเป็น **Illustrative scenarios** ที่สะท้อน failure mode จริง

**Illustrative scenario A — SCP ที่ apply ผิด OU ทำให้ prod ทำงานไม่ได้**
องค์กรหนึ่ง apply SCP "deny all EC2 instance types ยกเว้น t3.micro" เพื่อควบคุม cost ใน dev
แต่เนื่องจาก dev account อยู่ใน OU เดียวกับ prod account (จัดตาม business unit ไม่ใช่ environment)
SCP กระทบ production workload ที่ต้องการ r5.2xlarge — ทำให้ scale-out ล้มเหลวระหว่าง peak

**Illustrative scenario B — Shared account ที่ไม่มี isolation ทำให้ blast radius ใหญ่**
5 app team ใช้ AWS account เดียวร่วมกัน แยกด้วย IAM path และ tag เท่านั้น
เมื่อ developer คนหนึ่ง accidentally delete S3 bucket โดยไม่มี bucket policy
ทุก team ได้รับผลกระทบ เพราะ CloudTrail ไม่ได้แยก per-team และ IAM boundary ไม่ strict พอ

## The Naive Design

### Naive design 1 — One shared account, separated by tags

```
AWS Account: shared-all
├── Team Alpha resources  (tagged team=alpha)
├── Team Beta resources   (tagged team=beta)
├── Team Gamma resources  (tagged team=gamma)
├── Dev workloads         (tagged env=dev)
└── Prod workloads        (tagged env=prod)
```

**ทำไมถึงพัง:**
- Tag ไม่ใช่ security boundary — IAM policy ที่อ้าง tag เขียนผิดนิดเดียวก็ให้ access ข้าม team ได้
- Blast radius กว้าง: security incident หรือ misconfiguration ใน 1 team กระทบทุกคน
- Cost allocation ไม่ clean — shared resource ต้องแตก cost ด้วย tag ซึ่ง error-prone
- Service limit (quota) เป็น per-account — team หนึ่ง exhaust quota กระทบทุกคน
- ไม่สามารถ apply SCP ที่แตกต่างระหว่าง dev กับ prod ได้

### Naive design 2 — OUs ที่ mirror org chart

```
Root
├── OU: Retail Division
│   ├── Account: retail-dev
│   ├── Account: retail-uat
│   └── Account: retail-prod
├── OU: Lending Division
│   ├── Account: lending-dev
│   ├── Account: lending-uat
│   └── Account: lending-prod
└── OU: Operations
    └── Account: ops-shared
```

**ทำไมถึงพัง:**
- Org chart เปลี่ยนบ่อย (reorganization, new division) แต่ OU structure ยากเปลี่ยนตาม
- SCP ที่ต้องการ apply "สำหรับ production ทุก account" ต้อง apply ซ้ำใน 2 OU แยก แทนที่จะ apply ที่ level เดียว
- Control requirement จริงคือ "prod vs non-prod" และ "sensitive data vs non-sensitive" — ไม่ใช่ business unit
- เมื่อ team ย้าย division ต้อง move account ระหว่าง OU (ซับซ้อนและมีความเสี่ยง)

## Explore First

ก่อน design ให้อ่าน concept เหล่านี้ก่อน — ห้ามข้าม

- AWS doc: **"Organizing Your AWS Environment Using Multiple Accounts"** (aws.amazon.com/organizations/resources) — AWS แนะนำ OU structure แบบไหน? organize by function/controls ต่างจาก mirror org chart อย่างไร?
- AWS doc: **"AWS Organizations — best practices for management account"** — management account ควรใช้ทำอะไร? และไม่ควรทำอะไร?
- AWS doc: **"Service Control Policies (SCPs)"** — SCP evaluate ยังไง? deny ที่ SCP กับ deny ที่ IAM policy ต่างกันไหม? SCP affect management account ไหม?
- AWS doc: **"AWS Control Tower"** — เกี่ยวข้องยังไงกับ Organizations? Landing Zone คืออะไร?
- Concept: **Break-glass account** — คำถามที่ต้องตอบได้: ในกรณีฉุกเฉินที่ Identity Provider ล่ม จะ access AWS ได้ยังไง? ควรเก็บ credential break-glass ยังไง?
- Concept: **Principle of least privilege ที่ OU level** — SCP เป็น "guardrail" ไม่ใช่ "grant" หมายความว่าอะไร?

## Task

**Scenario:** Meridian Finance (ต่อจาก kata 01) กำลังออกแบบ AWS Organization structure

ข้อมูลที่รู้:
- 5 app team ในวันนี้ คาด 15 team ใน 2 ปี
- แต่ละ team มี: dev, uat, prod environment
- มี sensitive customer data (PII, financial data) — ต้องการ isolation จาก non-sensitive workload
- มี shared services: central logging, network hub, secrets management
- Security team ต้องการ audit trail ทุก account
- Cost team ต้องการ attribute cost ต่อ team และต่อ environment
- ต้องการ onboard team ใหม่ได้โดยไม่ redesign OU structure

**งาน:** ออกแบบ OU hierarchy และ account structure พร้อมระบุว่า SCP ใดควร apply ที่ OU ไหน

## Constraints

- Production account ต้องแยกจาก non-production อย่างชัดเจน — SCP ต่างกันระหว่างสอง group
- Cost ต้อง attributable ต่อ team โดยไม่ต้องพึ่งพา tag เพียงอย่างเดียว
- เมื่อ onboard team ใหม่ ต้องไม่ต้องแก้ OU structure ที่มีอยู่แล้ว
- Controls (SCP, guardrail) ต้อง apply ที่ OU level — ไม่ใช่ per-account manual config
- Management account ต้องใช้สำหรับ Organizations management เท่านั้น — ไม่มี workload
- ต้องมีกลไก break-glass access สำหรับกรณีฉุกเฉิน
- ระบุ SPOF ใน design

## What to Submit

1. **OU hierarchy diagram** — แสดง Root → OUs → Accounts พร้อมชื่อ account ตัวอย่างสำหรับ 5 team + shared services
2. **SCP mapping table** — OU แต่ละระดับควรมี SCP ประเภทใด (อธิบาย intent ไม่ต้องเขียน JSON จริง)
3. **Account list** — ระบุทุก account ที่ควรมีในวันแรก พร้อม purpose
4. **Key Decisions** — กรอก `templates/key-decisions-template.md`
5. **Assumptions** — เกี่ยวกับ data sensitivity, compliance scope, Identity Provider

บันทึกไว้ที่ `architecture/submissions/YYYY-MM-DD-02-account-ou-structure/`

## Acceptance Criteria

- [ ] Production account อยู่ใน OU แยกจาก non-production — SCP ที่ apply ต่างกันได้
- [ ] Cost attributable ต่อ team ได้โดยดูจาก account structure (ไม่ใช่แค่ tag)
- [ ] Onboard team ที่ 6-15 ได้โดยเพิ่ม account ใน OU ที่มีอยู่ — ไม่ต้องสร้าง OU ใหม่หรือ modify SCP
- [ ] Controls (SCP) apply ที่ OU level — แสดงว่า SCP ใด apply ที่ OU ใด
- [ ] Management account ไม่มี workload — ระบุได้ว่า account นี้ควรทำอะไรได้บ้าง
- [ ] มีกลไก break-glass access — อธิบายว่าเก็บ credential ยังไงและใช้เมื่อไร
- [ ] ระบุ SPOF ได้อย่างน้อย 2 จุด พร้อม mitigation

## Concepts Involved

- AWS Organizations — OUs, SCPs, account structure
- ดู AWS doc: [Organizing Your AWS Environment](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_best-practices.html)
- ดู AWS doc: [SCP evaluation logic](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps_evaluation.html)
- ดู AWS doc: [AWS Control Tower concepts](https://docs.aws.amazon.com/controltower/latest/userguide/concepts.html)
