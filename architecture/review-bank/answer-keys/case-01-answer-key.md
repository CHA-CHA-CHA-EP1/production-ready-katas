# Answer Key — Case 01: Three-Tier Web Application

> เปิดหลังทำ review เสร็จแล้วเท่านั้น

---

## Flaw 1: Single-AZ RDS (no Multi-AZ)

**Severity: Critical**

**ทำไมพังใน production:**
RDS ใน Single-AZ ไม่มี automatic failover ถ้า AZ us-east-1a มีปัญหา (hardware failure, AWS maintenance, network event) database จะ unavailable จนกว่าจะ restore ซึ่งอาจใช้เวลา 20-30 นาทีหรือมากกว่า application ที่ต้องการ availability ตลอด 24 ชั่วโมงจะ down ในช่วงนั้น

**Fix:**
Enable RDS Multi-AZ deployment — AWS จะ maintain standby replica ใน AZ อื่น automatic failover ใช้เวลา 60-120 วินาที ซึ่ง acceptable สำหรับ most workloads

**คำถามที่ควรถาม team:** RTO ของ application คือเท่าไร? ถ้า database down 30 นาที business impact คืออะไร?

---

## Flaw 2: ALB และ App Servers อยู่ใน Single AZ เดียว

**Severity: Critical**

**ทำไมพังใน production:**
Diagram แสดง ALB, App1, App2 ทั้งหมดใน us-east-1a เดียว ถ้า AZ นั้น disrupted ทั้ง tier ล่มพร้อมกัน การมี 2 app server ใน AZ เดียวกันเป็น horizontal scale ไม่ใช่ HA

**Fix:**
กระจาย App Server ไปทุก AZ อย่างน้อย 2 AZ (us-east-1a + us-east-1b) — ALB จะ route ไปยัง healthy instance ในแต่ละ AZ ต้องใช้ ASG เพื่อ manage instance lifecycle และ replace unhealthy instance อัตโนมัติ

---

## Flaw 3: S3 Bucket มี public-read ACL

**Severity: Critical**

**ทำไมพังใน production:**
Bucket นี้เก็บ KYC documents และ income statements ของลูกค้า — ข้อมูล sensitive ที่ไม่ควร public accessible การตั้ง public-read ACL แปลว่าใครก็ได้บน internet ที่รู้ key name สามารถ download document ได้โดยตรง
นอกจาก data breach risk ยังมี regulatory implication สำหรับ financial data

**Fix:**
- ลบ public ACL ออก — bucket ควรเป็น private
- ใช้ presigned URL สำหรับ legitimate user ที่ต้องการ download document ของตัวเอง
- Enable S3 Block Public Access ที่ account level

---

## Flaw 4: SSH port 22 เปิดสู่ Internet สำหรับ Admin Access

**Severity: High**

**ทำไมพังใน production:**
Port 22 ที่เปิดไว้ใน Security Group สำหรับ admin access เป็น attack surface — brute force, credential stuffing, CVE ใน SSH daemon ใดๆ ที่ยังไม่ได้ patch สามารถ exploit ได้
ไม่มีการระบุว่า restrict จาก IP range ใด ถ้า open 0.0.0.0/0 คือ critical

**Fix:**
- ปิด SSH ที่ Security Group สำหรับ inbound จาก internet
- ใช้ AWS Systems Manager Session Manager แทน SSH — ไม่ต้องเปิด port ใดๆ, audit trail อัตโนมัติ, ไม่ต้อง manage SSH key
- ถ้าต้องการ SSH จริงๆ: จำกัดเฉพาะ IP ของ bastion host หรือ VPN endpoint

---

## Flaw 5: ElastiCache Redis ใน Single AZ และ Single Node

**Severity: Medium**

**ทำไมพังใน production:**
Cache เก็บ session data และ rate-limit counter ถ้า Redis node fail session ทุก session จะหาย ทำให้ user ทุกคน logout ทันที นอกจากนี้ถ้าใช้ rate-limit counter ที่ Redis และ Redis ไม่ available จะ handle rate limiting ยังไง?

**Fix:**
- ใช้ ElastiCache Redis Cluster mode หรืออย่างน้อย Multi-AZ replication group
- ออกแบบ application ให้ degrade gracefully ถ้า cache unavailable (เช่น ถ้า Redis down → fallback ไป no-session หรือ short-lived DB session)

---

## Flaw 6: ไม่มี NAT Gateway Redundancy (implied single-AZ)

**Severity: Medium**

**ทำไมพังใน production:**
ถ้า App Server ใน private subnet ต้องการ outbound internet (เช่น third-party API, software update) และมี NAT Gateway เดียวใน us-east-1a เมื่อ AZ นั้นมีปัญหา outbound connectivity หาย
Diagram ไม่ได้แสดง NAT Gateway แต่ถ้า app server อยู่ใน private subnet จะต้องมี

**Fix:**
สร้าง NAT Gateway ใน แต่ละ AZ ที่มี app server — อย่างน้อย 2 NAT Gateway
Route table ของแต่ละ private subnet ชี้ไปที่ NAT Gateway ใน AZ เดียวกัน

---

## Flaw 7: Deploy ด้วย Manual SSH — ไม่มี Deployment Automation

**Severity: Medium**

**ทำไมพังใน production:**
Manual deploy ผ่าน SSH มีปัญหาหลายอย่าง:
- Human error: deploy version ผิด, miss step ใน deploy process
- ไม่มี rollback mechanism ที่ tested
- ไม่มี audit trail ว่าใคร deploy อะไร เมื่อไร
- ถ้า deploy ระหว่าง peak traffic จะ handle gracefully ยังไง?

**Fix:**
ใช้ deployment automation เช่น AWS CodeDeploy กับ rolling deploy, CodePipeline, หรือ container-based deploy ด้วย ECS แทน manual EC2 management

---

## Flaw 8: Monitoring ที่อาจพึ่ง S3 หรือ Service ที่กำลัง Monitor

**Severity: Low**

**ทำไมพังใน production:**
ไม่มีรายละเอียดว่า alarm ส่งไปที่ไหน ถ้า monitoring infrastructure ขึ้นอยู่กับ service เดียวกับที่กำลัง monitor (เช่น dashboard อยู่บน same EC2) เมื่อ service พัง monitoring ก็พังตาม ไม่รู้ว่า production พัง

**Fix:**
- ใช้ CloudWatch Alarms ที่ส่ง notification ผ่าน SNS → email/PagerDuty ที่ independent จาก application
- Dashboard ควรอยู่บน infrastructure ที่แยกจาก application (เช่น CloudWatch Console ซึ่ง AWS-managed)

---

## Summary

| # | Flaw | Severity |
|---|---|---|
| 1 | Single-AZ RDS | Critical |
| 2 | All resources in single AZ | Critical |
| 3 | S3 public-read ACL บน sensitive data | Critical |
| 4 | SSH port 22 open | High |
| 5 | Redis single-node single-AZ | Medium |
| 6 | Single NAT Gateway | Medium |
| 7 | Manual SSH deploy | Medium |
| 8 | Monitoring coupling | Low |

**Critical flaws (3):** ต้อง fix ก่อน go-live
**High flaws (1):** ต้อง fix ก่อน go-live
**Medium/Low flaws (4):** fix ใน sprint แรกหลัง launch
