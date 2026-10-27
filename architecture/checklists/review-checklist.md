# Architecture Review Checklist

Well-Architected style checklist สำหรับใช้ review design ของ app team

ใช้ checklist นี้เป็น **starting point** ไม่ใช่ exhaustive list — ไม่ใช่ทุก item ใช้กับทุก workload
สำหรับคำถามเชิง conversation ให้ดู [questions-for-app-teams.md](questions-for-app-teams.md)

---

## Reliability

- [ ] มี Single Point of Failure ที่ระบุได้ไหม? มีแผนจัดการยังไง?
- [ ] แต่ละ critical component อยู่ใน AZ อย่างน้อย 2 AZ หรือไหม?
- [ ] ถ้า AZ หนึ่งล่ม system ยังทำงานได้ไหม? ใช้เวลา recover นานแค่ไหน?
- [ ] Database มี Multi-AZ หรือ replica สำหรับ failover ไหม?
- [ ] Queue/async processing มี DLQ และ retry policy ที่กำหนดไว้ไหม?
- [ ] มี idempotency สำหรับ operation ที่อาจ retry ไหม?
- [ ] Circuit breaker หรือ timeout ต่อ external dependency กำหนดไว้ไหม?
- [ ] Health check ของ component แต่ละตัว independent จาก component นั้นเองไหม?
- [ ] RTO และ RPO กำหนดไว้และ design รองรับตาม target นั้นไหม?

---

## Security

- [ ] Data ทั้งหมดที่ transport ใช้ encryption (TLS/HTTPS) ไหม?
- [ ] Data at rest ใช้ encryption ไหม? ใช้ SSE-S3 หรือ SSE-KMS? เลือกเพราะอะไร?
- [ ] IAM role ใช้ least privilege ไหม? ไม่มี `*` action หรือ `*` resource โดยไม่จำเป็น?
- [ ] Secret / credential เก็บอยู่ที่ไหน? อยู่ใน code หรือ env var ไหม?
- [ ] Security Group เปิดเฉพาะ port ที่จำเป็น? ไม่มี 0.0.0.0/0 สำหรับ inbound ที่ไม่ควร?
- [ ] S3 bucket มี Block Public Access enable ไหม?
- [ ] Network ingress ผ่าน WAF หรือ shield ไหม?
- [ ] Data ที่ sensitive ถูก classify ไว้ไหม? มี handling requirement ตาม classification ไหม?
- [ ] Admin access ใช้ Session Manager หรือ bastion host — ไม่ใช่ direct SSH?
- [ ] มี audit trail สำหรับ privileged action (CloudTrail, access log) ไหม?

---

## Performance

- [ ] Bottleneck หลักของ design คืออะไร? ระบุได้ไหม?
- [ ] Database ใช้ connection pooling ไหม? connection limit มีไหม?
- [ ] Cache อยู่ที่ไหน? cache miss สำหรับ popular key จะ spike DB ไหม (thundering herd)?
- [ ] Auto Scaling policy กำหนดไว้ไหม? trigger จาก metric อะไร?
- [ ] ถ้า load เพิ่ม 10x สิ่งแรกที่พังคืออะไร?

---

## Cost

- [ ] ระบุ cost driver หลักได้ไหม (compute, data transfer, storage, request count)?
- [ ] NAT Gateway มีค่าใช้จ่ายต่อ data transfer — traffic ที่ไปออก internet ผ่าน NAT มีปริมาณเท่าไร?
- [ ] Reserved Instance หรือ Savings Plan เหมาะกับ baseline load ไหม?
- [ ] Log retention กำหนดไว้ไหม? log ที่ไม่ได้อ่านเก็บนานเกินไปไหม?
- [ ] S3 storage class เหมาะกับ access pattern ไหม (Frequent Access vs Infrequent)?
- [ ] มี cost alerting (AWS Budgets alarm) ไหม?

---

## Operational Excellence

- [ ] Deploy process automated ไหม? manual step มีไหม?
- [ ] Rollback mechanism กำหนดไว้และ tested ไหม?
- [ ] ถ้า system พังตอนตี 2 จะรู้ได้ยังไงว่าพัง? alarm ส่งไปหาใคร?
- [ ] Runbook สำหรับ common failure scenario มีไหม?
- [ ] On-call process และ escalation path กำหนดไว้ไหม?

---

## Observability

- [ ] Structured log (JSON) ใช้ไหม? มี request ID ที่ trace ข้าม service ได้ไหม?
- [ ] Key metrics กำหนดไว้ไหม (latency p99, error rate, throughput)?
- [ ] Dashboard สำหรับ "ระบบ healthy ไหม" มีไหม? ดูได้ใน 30 วินาทีไหม?
- [ ] Alert ที่ actionable มีไหม? ไม่ใช่ alert ที่ noise ล้วนๆ?
- [ ] Distributed tracing implement ไหม (ถ้า multi-service)?
- [ ] Monitoring infrastructure ขึ้นอยู่กับ application ที่ monitor หรือไม่? (monitoring coupling)

---

## Governance / Compliance

- [ ] Design สอดคล้องกับ organisation standards ไหม (tagging, naming convention, approved services)?
- [ ] Data classification ของ data ที่ handle มีไหม? control ตาม classification implement ไหม?
- [ ] Audit trail ครอบคลุม access ถึง sensitive data ไหม?
- [ ] Retention requirement ของ log / data กำหนดไว้ไหม?
- [ ] ถ้ามี regulatory requirement (เช่น data residency) — design comply ไหม?
- [ ] Exception หรือ deviation จาก standard มี waiver approved ไหม?

---

## Checklist Usage Notes

**Critical = must fix before go-live** — security breach, data loss, หรือ unacceptable downtime risk
**High = should fix before go-live** — significant risk แต่ workaround มี
**Medium = fix in first sprint** — improve resilience หรือ operability
**Low = track in backlog** — nice to have หรือ future optimization
