# Architecture Track — Roadmap

แต่ละ topic มี **Level** (ความลึก), **Priority** (M=Must / S=Should / N=Nice), และ **Status** (todo / doing / done)

Numbering ใน kata ไม่ใช่ order บังคับ — แต่ควรทำ Level ต่ำก่อนถ้ายังใหม่กับ topic นั้น

---

## Level 0 — Foundations

ก่อนเริ่ม design ต้องเข้าใจ building block พวกนี้

| Topic | Priority | Status |
|---|---|---|
| IP addressing, CIDR, subnetting | Should | todo |
| CIDR planning across many VPCs and accounts | **Must** | todo |
| DNS basics (zones, record types, resolution) | Should | todo |
| TLS and certificates (chain of trust, renewal) | Should | todo |
| Latency / throughput / availability maths — 99.9% ใน minutes คือเท่าไร | Should | todo |
| RTO and RPO — นิยาม, วัดยังไง, ส่งผลต่อ design ยังไง | **Must** | todo |
| Trade-off articulation — อธิบาย design decision อย่างมีเหตุผล | **Must** | todo |

---

## Level 1 — AWS Building Blocks

Service แต่ละตัวทำงานยังไง ก่อน compose เป็น architecture

| Topic | Priority | Status |
|---|---|---|
| VPC, subnets, route tables, IGW, NAT Gateway | Should | todo |
| Security Group vs NACL — ต่างกันยังไง ใช้เมื่อไร | Should | todo |
| S3 basics — storage class, versioning, lifecycle | Should | todo |
| IAM basics — policy types, evaluation logic, trust policy | **Must** | todo |
| EC2, ALB, ASG — scaling patterns | Nice | todo |
| RDS Multi-AZ vs read replica — ต่างกันยังไง failover เป็นยังไง | Should | todo |
| VPC endpoints — Gateway vs Interface endpoint | Should | todo |
| CloudWatch, CloudTrail — metrics vs audit logs | Should | todo |
| Basic cost drivers — what makes AWS bills spike | **Must** | todo |

---

## Level 2 — Application Design

Design pattern ระดับ application บน AWS

| Topic | Priority | Status |
|---|---|---|
| AZ-resilient three-tier architecture | **Must** | todo |
| Upload patterns — presigned PUT, confirm pattern, S3 events | Nice | todo |
| CDN + WAF + origin header secret | Nice | todo |
| Cache strategies — TTL, invalidation, thundering herd | Should | todo |
| Queue basics — SQS, DLQ, visibility timeout | Should | todo |
| Idempotency — ทำไมถึงสำคัญ, implement ยังไง | Should | todo |
| Retry, timeout, circuit breaker | **Must** | todo |
| Secrets management — Secrets Manager vs Parameter Store | Should | todo |
| Encryption at rest — SSE-S3 vs SSE-KMS, envelope encryption | Should | todo |
| Authn/authz patterns — JWT, IAM, Cognito | Should | todo |
| Design review: find the flaws in an existing design | **Must** | todo |
| Observability design — structured logs, metrics, tracing | Should | todo |
| Reading public post-mortems | **Must** | todo |

---

## Level 3 — Organisation Level

Design ระดับ AWS Organization — หลาย account, หลาย team

| Topic | Priority | Status |
|---|---|---|
| Account structure and OU design | **Must** | todo |
| Organizations and SCP guardrails | **Must** | todo |
| Hub-and-spoke vs peering vs Transit Gateway | **Must** | todo |
| Transit Gateway route table segmentation (prod vs non-prod) | Should | todo |
| Hybrid connectivity — Direct Connect, Site-to-Site VPN, hybrid DNS | **Must** | todo |
| Centralized egress/ingress and traffic inspection | Should | todo |
| Cross-account access — assume role, resource policies, KMS grants | Should | todo |
| Identity — IAM Identity Center, break-glass account | Should | todo |
| Cross-account DNS — Route 53 Resolver rules | Should | todo |
| Centralized logging and audit trail | Should | todo |
| Tagging strategy and cost allocation | Should | todo |
| Policy-as-code — SCP, Config rules, SCM | Should | todo |
| Account vending and onboarding automation | Should | todo |
| Multi-tenant EKS standards | Nice | todo |
| Compliance mapping for financial services — generic controls: data residency, third-party/outsourcing risk, cloud exit plan, audit trail, DR testing (TODO: map to official regulator text) | **Must** | todo |

---

## Level 3.5 — EA Governance

Enterprise Architecture ในทางปฏิบัติ

| Topic | Priority | Status |
|---|---|---|
| Writing principles and standards — short, actionable, enforceable | **Must** | todo |
| ARB process — intake, triage, approve / conditional / reject | **Must** | todo |
| Tiered review by impact — delivery team / domain architect / ARB | **Must** | todo |
| Exception and waiver management — time-bound, with remediation path | **Must** | todo |
| Technology radar and lifecycle / retirement planning | Should | todo |
| Reference architectures and golden paths | Should | todo |
| Embedding architecture checks into CI/CD | Should | todo |
| Governance metrics — review lead time, % compliant, exception count | Nice | todo |

---

## Level 4 — Advanced

| Topic | Priority | Status |
|---|---|---|
| DR strategies — backup-restore, pilot light, warm standby, active-active | Should | todo |
| Multi-region active-active | Nice | todo |
| Event-driven patterns — outbox pattern, event ordering | Nice | todo |
| Data platform basics — lake, warehouse, lakehouse | Nice | todo |
| Migration strategies — 6R framework | Should | todo |
| IaC and drift detection | Should | todo |
| ADRs and executive communication | **Must** | todo |
| AI/ML risk governance for regulated firms | Nice | todo |

---

## Reading List

public sources ที่แนะนำให้อ่านประกอบ (ไม่ได้ verify ทุก link ในการเขียน roadmap นี้ — ตรวจ availability ก่อนใช้):

- [AWS Organizing Your AWS Environment Using Multiple Accounts](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_best-practices.html)
- [AWS Well-Architected Framework](https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html)
- [AWS Transit Gateway documentation](https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html)
- [Cloudflare Learning Center — BGP](https://www.cloudflare.com/learning/security/glossary/what-is-bgp/)
