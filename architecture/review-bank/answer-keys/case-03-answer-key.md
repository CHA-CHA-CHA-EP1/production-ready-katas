# Answer Key — Case 03: Multi-Tenant API Platform

> เปิดหลังทำ review เสร็จแล้วเท่านั้น

---

## Flaw 1: Plaintext API Keys เก็บใน DynamoDB

**Severity: Critical**

**ทำไมพังใน production:**
ถ้า DynamoDB table ถูก access โดย unauthorized party (misconfigured IAM, insider threat, compromise ของ account) API key ของทุก partner จะถูก expose ในรูปแบบที่ใช้งานได้ทันที
นอกจากนี้ DynamoDB access log ที่ export ออกมา (เช่น CloudTrail, audit export) จะมี API key อยู่ใน plaintext ด้วย

**Fix:**
- เก็บเฉพาะ hash ของ API key (เช่น HMAC-SHA256 กับ secret) ไม่ใช่ plaintext
- เมื่อ partner ส่ง API key มา → hash แล้วเปรียบเทียบกับ stored hash
- API key ที่ generate ใหม่ต้องส่งให้ partner ครั้งเดียว — ถ้า lost ต้อง generate ใหม่เท่านั้น
- พิจารณาใช้ AWS Secrets Manager หรือ API Gateway API key management แทน custom DynamoDB solution

---

## Flaw 2: DB Credentials ใน Environment Variables ของ ECS Task

**Severity: Critical**

**ทำไมพังใน production:**
Environment variables ใน ECS task definition:
- เห็นได้ใน AWS Console, CLI, CloudTrail โดยใครก็ตามที่มี ECS read access
- ถ้า task crash และ dump environment → credentials โผล่ใน log
- ยาก rotate: ต้อง update task definition ใหม่ทุกครั้ง → service ต้องทำ rolling restart

**Fix:**
- ใช้ AWS Secrets Manager — store credentials ใน Secrets Manager แล้วให้ ECS task inject ตอน runtime ผ่าน `secrets` field ใน task definition
- IAM role ของ ECS task มี permission อ่าน secret ที่ specific เท่านั้น
- Rotation policy: ตั้ง automatic rotation ของ Secrets Manager สำหรับ RDS credentials

---

## Flaw 3: Single S3 Bucket สำหรับทุก Partner — Cross-Tenant Data Risk

**Severity: Critical**

**ทำไมพังใน production:**
S3 bucket policy ที่ใช้ key prefix เป็น partition มีความเสี่ยง:
- Bug ใน prefix logic ทำให้ partner A อ่าน document ของ partner B ได้
- Partner A ที่มี access key leak → attacker list ทั้ง bucket เห็น prefix ของ partner อื่น
- Compliance: financial services มักต้องการ logical isolation ระหว่าง tenant — S3 prefix ไม่ถือเป็น strong isolation

**Fix:**
- แยก S3 bucket ต่อ partner หรืออย่างน้อยต่อ tier ของ sensitivity
- ใช้ IAM + bucket policy ที่จำกัดแต่ละ partner ให้ access เฉพาะ bucket ของตัวเอง
- ถ้าใช้ bucket เดียวจริงๆ: ใช้ S3 Object Ownership + ACL ที่ strict มาก + ทดสอบ cross-prefix access จาก perspective ของแต่ละ partner

---

## Flaw 4: Single CloudWatch Log Group สำหรับทุก Service และทุก Partner

**Severity: High**

**ทำไมพังใน production:**
Log group เดียวทำให้:
- ไม่สามารถ set log retention ต่าง service ได้
- ไม่สามารถ grant partner access เพื่อดู log ของตัวเองได้
- ถ้าต้องการ audit log ของ partner เฉพาะราย ต้องกรองด้วย query — error-prone
- Compliance audit ที่ต้องการ evidence ว่า "data ของ partner A ถูก access เมื่อไร" ทำได้ยาก

**Fix:**
- แยก log group ต่อ service และต่อ tenant (เช่น `/platform/loan-service/{partner-id}`)
- ตั้ง log retention ต่าง service ตาม compliance requirement
- ใช้ CloudWatch Logs Insights สำหรับ cross-service correlation แต่เก็บ granular ก่อน

---

## Flaw 5: ไม่มี API Key Rotation Mechanism

**Severity: High**

**ทำไมพังใน production:**
API key ที่ไม่มี expiry และ rotation:
- ถ้า partner leak key ไม่มี signal จาก platform ว่า key นี้ compromised
- Offboard partner: ต้องมั่นใจว่า key ถูก revoke — ถ้า process ไม่ชัดอาจ miss
- Compliance: บาง standard กำหนดให้ rotate credential ทุก N วัน

**Fix:**
- API key ควรมี expiry date
- สร้าง self-service rotation endpoint สำหรับ partner
- Alert ถ้า key ใกล้ expire และยังไม่ rotate
- Immediate revocation endpoint สำหรับกรณี compromise

---

## Flaw 6: Rate Limiting ที่ API Gateway Level เท่านั้น — ไม่มี Defense in Depth

**Severity: Medium**

**ทำไมพังใน production:**
Usage plan ที่ API Gateway ช่วยได้ แต่:
- ถ้า partner ส่ง burst ขนาดใหญ่พร้อมกันหลายคนในเวลาเดียวกัน backend services อาจ overwhelmed ได้
- ไม่มี rate limit ที่ application layer หรือ DB layer

**Fix:**
- เพิ่ม rate limiting ที่ application layer (circuit breaker)
- กำหนด connection pool limit ที่ DB

---

## Flaw 7: Monitoring กล่าวถึงเฉพาะ API Gateway Metrics — ไม่มี Business Metric

**Severity: Medium**

**ทำไมพังใน production:**
4xx/5xx rate บอกว่า system มีปัญหา แต่ไม่บอกว่า:
- Partner ไหนกำลังมีปัญหา?
- API call ไหนสำเร็จ/ล้มเหลวบ้าง?
- SLA ต่อ partner เป็นอย่างไร?
ถ้า partner A ได้รับ 5xx 30% ของ call แต่ overall 5xx rate ดูปกติ → ไม่รู้

**Fix:**
- Metric ต่อ partner: latency, error rate, throughput
- Alert ถ้า error rate ของ partner ใดเกิน threshold
- SLA dashboard ต่อ partner

---

## Summary

| # | Flaw | Severity |
|---|---|---|
| 1 | Plaintext API keys ใน DynamoDB | Critical |
| 2 | DB credentials ใน env vars | Critical |
| 3 | Single S3 bucket cross-tenant | Critical |
| 4 | Single log group cross-service | High |
| 5 | ไม่มี API key rotation | High |
| 6 | Rate limiting ไม่มี defense in depth | Medium |
| 7 | ขาด business-level monitoring | Medium |

**Critical flaws (3):** ต้อง fix ก่อน go-live — security และ compliance risk
**High flaws (2):** ต้อง fix ก่อน go-live
**Medium flaws (2):** fix ใน sprint แรกหลัง launch
