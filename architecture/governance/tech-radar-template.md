# Technology Radar Template

*Fictional template สำหรับ practice — inspired by Thoughtworks Tech Radar format*

Technology Radar ช่วย communicate ว่า technology ไหนที่ organization นี้แนะนำ กำลัง trial ประเมิน หรือหลีกเลี่ยง

---

## Zones

| Zone | ความหมาย | ควรทำอะไร |
|---|---|---|
| **Adopt** | Technology ที่ proven ใน production และแนะนำเป็น default | ใช้ได้เลย ไม่ต้อง justify |
| **Trial** | Technology ที่มี evidence ว่า promising แต่ยังอยู่ระหว่าง evaluate | ใช้ได้ใน limited context โดยต้องแชร์ findings กลับมา |
| **Assess** | Technology ที่น่าสนใจและควร watch — ยังไม่พร้อม production | ทำ proof-of-concept ได้ แต่ไม่ใช้ใน production workload |
| **Hold** | Technology ที่ไม่แนะนำให้ใช้ใหม่ หรืออยู่ระหว่าง phase out | ไม่เริ่มใช้ใหม่ — workload ที่ใช้อยู่ให้ migrate ออกตาม plan |

---

## Radar Entries

### Adopt

| Technology | Category | Date added | Notes |
|---|---|---|---|
| AWS ECS Fargate | Compute | YYYY-MM | Container workload standard |
| AWS RDS (MySQL/Postgres) | Database | YYYY-MM | Managed relational DB standard |
| AWS S3 | Storage | YYYY-MM | Object storage standard |
| AWS Secrets Manager | Security | YYYY-MM | Secret storage standard — env vars ไม่ acceptable |
| Terraform | IaC | YYYY-MM | Infrastructure as Code standard |
| GitHub Actions | CI/CD | YYYY-MM | Pipeline standard |

### Trial

| Technology | Category | Date added | Trial owner | Expected decision date | Notes |
|---|---|---|---|---|---|
| Amazon EKS | Compute | YYYY-MM | [Team X] | YYYY-MM | Evaluating for multi-tenant workloads |
| AWS EventBridge | Messaging | YYYY-MM | [Team Y] | YYYY-MM | Evaluate vs SQS+SNS for event routing |

### Assess

| Technology | Category | Date added | Notes |
|---|---|---|---|
| AWS Bedrock | AI/ML | YYYY-MM | Watch for use in internal tooling |
| Graviton instances | Compute | YYYY-MM | Cost saving potential, evaluate compatibility |

### Hold

| Technology | Category | Date added | Reason | Retirement target | Migration path |
|---|---|---|---|---|---|
| EC2 with manual config | Compute | YYYY-MM | Drift risk, no repeatability | YYYY-MM | Migrate to ECS Fargate or use AMI + LaunchTemplate |
| Plaintext secrets in env vars | Security | YYYY-MM | Security risk | Immediate | Move to Secrets Manager |
| Single-AZ RDS | Database | YYYY-MM | No failover | YYYY-MM | Enable Multi-AZ |

---

## Lifecycle and Retirement Process

### Moving a technology to "Hold"

1. Raise proposal กับ ARB — ระบุ reason และ migration path
2. Set retirement target date (realistic — ให้ teams มีเวลา migrate)
3. Communicate ไปยัง all teams
4. Track migration progress ทุก quarter

### Retiring a technology

1. Confirm ไม่มี active workload ใช้งานอยู่
2. Archive radar entry — ไม่ delete เพื่อรักษา decision history
3. Update any onboarding documentation

### Review Cadence

Technology Radar ควร review ทุก 6 เดือน:
- มี technology ใหม่ที่ควร assess ไหม?
- Technology ที่อยู่ใน "Trial" มี findings แล้วหรือยัง?
- "Hold" technology ที่ถึง retirement target — migrate แล้วหรือยัง?

---

## Entry Template

ใช้ format นี้เมื่อ propose entry ใหม่หรือ change zone:

```markdown
**Technology:** [ชื่อ]
**Category:** Compute / Database / Storage / Security / IaC / Messaging / Framework / Other
**Proposed zone:** Adopt / Trial / Assess / Hold
**Proposed by:** [Name, Team]
**Justification:** [เหตุผล 2-3 ประโยค]
**Evidence:** [ถ้า Trial/Adopt — ผล trial หรือ production usage]
**Risks:** [ถ้า Adopt — risks ที่ accept และ mitigations]
**Migration path:** [ถ้า Hold — path สำหรับ existing users]
```
