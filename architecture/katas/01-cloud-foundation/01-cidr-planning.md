---
tier: architecture/01-cloud-foundation
difficulty: 1
concepts: [cidr, vpc-design, ip-addressing, multi-account]
prerequisites: []
---

# Kata 01: CIDR Planning Across Multiple VPCs and Accounts

## Context

ก่อนที่จะ provision VPC แรกบน AWS ต้องตัดสินใจ CIDR range ให้กับแต่ละ VPC — และถ้าคิดไม่ดีตั้งแต่แรก ราคาที่ต้องจ่ายคือ re-subnet ทั้ง environment ซึ่งแปลว่า downtime, re-deploy ทุก workload, และงาน network re-peering ทั้งหมด

problem นี้ซับซ้อนขึ้นเมื่อ organization มีหลาย account หลาย environment (dev/uat/prod) และต้องการ connectivity ระหว่าง VPC โดยไม่มี CIDR overlap

## Real World Incidents

> ไม่มี public post-mortem ที่ verify ได้สำหรับ CIDR exhaustion โดยตรง
> ด้านล่างเป็น **Illustrative scenario** ที่สะท้อน failure mode จริงที่พบบ่อย

**Illustrative scenario — CIDR overlap blocks Transit Gateway attachment**
บริษัทขยาย AWS environment จาก 3 account เป็น 12 account ในเวลา 8 เดือน
ทุก VPC ได้รับ CIDR `10.0.0.0/16` เพราะไม่มี standard — dev team แต่ละทีม provision เอง
เมื่อต้องการเชื่อม VPC ผ่าน Transit Gateway พบว่า route table conflict ทุก attachment
ต้องทำ re-CIDR production VPC 3 ตัวในช่วง maintenance window รวม 14 ชั่วโมง

## The Naive Design

### Naive design 1 — ให้แต่ละทีม pick CIDR เอง

```
Account A (Team Alpha)   Account B (Team Beta)   Account C (Team Gamma)
┌──────────────────┐     ┌──────────────────┐    ┌──────────────────┐
│ VPC 10.0.0.0/16  │     │ VPC 10.0.0.0/16  │    │ VPC 10.0.0.0/16  │
│  prod            │     │  prod            │    │  prod            │
└──────────────────┘     └──────────────────┘    └──────────────────┘
```

**ทำไมถึงพัง:** VPC แต่ละตัว isolated อยู่ได้ แต่ทันทีที่ต้องการ VPC peering หรือ Transit Gateway
overlap CIDR ทำให้ routing เป็นไปไม่ได้ AWS ไม่อนุญาต peer VPC ที่มี CIDR ซ้อนกัน

### Naive design 2 — ใช้ /16 ทั้งหมดแต่แบ่งต่างกัน

```
Account A: 10.1.0.0/16
Account B: 10.2.0.0/16
Account C: 10.3.0.0/16
```

**ทำไมถึงพัง:** /16 = 65,534 IPs ต่อ VPC — ใหญ่เกินความจำเป็นสำหรับ workload ส่วนใหญ่
พอมี 20 account ใช้ไป 20 /16 แล้วเหลือ 236 สำหรับ future expansion ใน 10.x.x.x space
ถ้ารวม on-premises network ที่ใช้ 10.x.x.x อยู่แล้ว มีโอกาส conflict สูง
นอกจากนี้ subnet ใน VPC จะ waste IP ถ้า sizing ไม่ถูก

## Explore First

ก่อน design ให้ไปอ่าน / ทำความเข้าใจ concept เหล่านี้ก่อน — **ห้ามเดา**

- AWS doc: **"VPC CIDR blocks"** — ขนาด CIDR ที่ AWS support คืออะไร? minimum และ maximum คืออะไร?
- AWS doc: **"Subnet sizing for IPv4"** — AWS reserve IP ใน subnet กี่ตัว และทำไม?
- AWS doc: **"Transit Gateway route tables"** — CIDR overlap มีผลอะไรต่อ route propagation?
- AWS doc: **"AWS Organizations — multiple accounts best practices"** — AWS แนะนำให้ allocate CIDR ยังไงใน multi-account?
- Concept: **VLSM (Variable Length Subnet Masking)** — คำถามที่ต้องตอบได้: ถ้าต้องการ 50 host addresses ควรใช้ subnet ขนาดเท่าไร?
- Concept: **RFC 1918 private address ranges** — มี 3 block คืออะไร? แต่ละ block เหมาะกับ use case อะไร?

## Task

**Scenario:** องค์กร Fintech สมมติ "Meridian Finance" กำลังเริ่ม AWS environment ใหม่ตั้งแต่ต้น

ข้อมูลที่รู้:
- 5 app team ในวันนี้ คาด 15 team ใน 2 ปี
- แต่ละ team มี: dev, uat, prod environment (= 3 VPC ต่อ team)
- มี shared services (DNS, logging, secrets): 2 VPC (hub-spoke model)
- มี connectivity กลับ on-premises ผ่าน Direct Connect ในอนาคต
- On-premises network ใช้ range `192.168.0.0/16` อยู่แล้ว
- แต่ละ VPC คาดว่ามี workload ไม่เกิน 200 EC2/container instances

**งาน:** ออกแบบ CIDR allocation plan ที่รองรับ scale ข้างต้น

## Constraints

- ต้องรองรับ 15 team × 3 env = 45 app VPC + 2 shared VPC = **47 VPC** ในอนาคต
- ไม่ conflict กับ on-premises `192.168.0.0/16`
- แต่ละ VPC ต้องมี subnet หลายขนาด: public subnet สำหรับ ALB, private subnet สำหรับ app tier, isolated subnet สำหรับ database
- ต้อง support Transit Gateway routing ในอนาคตโดยไม่ต้อง re-CIDR
- ต้อง document ได้ว่า account ไหนได้ CIDR อะไร — ต้อง traceable

## What to Submit

1. **CIDR allocation table** — สำหรับ 5 team ปัจจุบัน + shared services + placeholder สำหรับ 10 team ที่เหลือ พร้อม VPC CIDR และ subnet breakdown (อย่างน้อย 1 VPC ที่แตก subnet ให้ครบ)
2. **Key Decisions** — กรอก `templates/key-decisions-template.md`: เลือก address range ไหนและทำไม, ขนาด VPC /? เพราะอะไร, แบ่ง subnet ยังไง
3. **Assumptions** — สิ่งที่ assume เกี่ยวกับ growth rate, on-premises range, และ future Direct Connect

บันทึกไว้ที่ `architecture/submissions/YYYY-MM-DD-01-cidr-planning/`

## Acceptance Criteria

- [ ] CIDR plan รองรับ 47 VPC ในอนาคตได้โดยไม่ overlap
- [ ] ไม่มี VPC ที่มี CIDR ซ้อนทับกับ on-premises `192.168.0.0/16`
- [ ] แต่ละ VPC มี subnet อย่างน้อย 3 tier (public / private / isolated) ใน 2 AZ ขึ้นไป
- [ ] ระบุได้ว่า account ไหน / team ไหน ได้ block CIDR อะไร — traceable โดยดูที่ table เดียว
- [ ] อธิบายได้ว่าทำไมถึงเลือก block ขนาดนั้น (ไม่ใช่แค่ "เพราะ default")
- [ ] ระบุ SPOF และ constraint ที่เหลืออยู่ใน plan (เช่น จุดที่จะ exhaust ถ้า scale เกิน assumption)

## Concepts Involved

- [`cidr`](../../concepts/cidr.md) — CIDR notation, subnet sizing, AWS reserved IPs *(สร้างตามต้องการ)*
- ดู AWS doc: [VPC CIDR blocks](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html)
- ดู AWS doc: [AWS Organizations best practices for multiple accounts](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_best-practices_mgmt-acct.html)
