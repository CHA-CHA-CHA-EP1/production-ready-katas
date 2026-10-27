# Answer Key — Case 02: Async Document Processing Pipeline

> เปิดหลังทำ review เสร็จแล้วเท่านั้น

---

## Flaw 1: SQS Queue ไม่มี Dead Letter Queue (DLQ)

**Severity: Critical**

**ทำไมพังใน production:**
ถ้า message ใดก็ตาม process ไม่สำเร็จซ้ำๆ (เช่น document เสียหาย, Textract reject บาง file type, bug ใน worker) SQS จะ re-deliver message ซ้ำไปเรื่อยๆ จนถึง retention period (default 4 วัน) แล้ว message หาย permanently โดยที่ไม่มีใครรู้
ไม่มี DLQ = poison pill message ทำให้ worker consume resource ไปเรื่อยๆ และ message หายโดยไม่มี alert

**Fix:**
- สร้าง SQS DLQ (Dead Letter Queue) แยกต่างหาก
- ตั้ง maxReceiveCount (เช่น 3-5 ครั้ง) หลังจากนั้น message จะถูก move ไป DLQ
- ตั้ง CloudWatch Alarm บน DLQ depth > 0 เพื่อ alert ทันที
- สร้าง process สำหรับ reprocess message ใน DLQ หลัง fix bug

---

## Flaw 2: Retry Storm เมื่อ Core Banking API ล่ม

**Severity: Critical**

**ทำไมพังใน production:**
Worker ต้อง call Core Banking API แบบ synchronous ถ้า Core Banking slow หรือ unavailable:
- Worker จะรอ response จนถึง timeout
- ระหว่างรอ worker ไม่ว่าง ไม่ process message ใหม่ — throughput ตก
- SQS visibility timeout expire ก่อน worker ตอบ → SQS ส่ง message ซ้ำ → worker ใหม่รับ message เดิม
- เกิด duplicate processing + worker ทุกตัวพยายาม call Core Banking พร้อมกัน = thundering herd

**Fix:**
- ใช้ exponential backoff กับ jitter เมื่อ retry Core Banking call
- ตั้ง SQS visibility timeout ให้นานกว่า max expected processing time (เช่น 10 นาที ถ้า OCR ใช้ 90 วินาที)
- Circuit breaker: ถ้า Core Banking fail N ครั้งติดกัน → stop calling ชั่วคราว แล้ว re-queue message
- พิจารณา async submit ไป Core Banking แทน synchronous call

---

## Flaw 3: Worker ทั้ง 2 ตัวใน AZ เดียวกัน (Single AZ)

**Severity: High**

**ทำไมพังใน production:**
เช่นเดียวกับ Case 01 — ถ้า us-east-1a disrupted worker ทั้ง 2 ตัวหาย pipeline หยุด document ที่ queue ไว้รอ process จะค้างอยู่จนกว่าจะ restore

**Fix:**
กระจาย worker ไปใน AZ อย่างน้อย 2 AZ ใช้ ASG กับ multi-AZ subnets

---

## Flaw 4: ไม่มี Idempotency — Document อาจถูก Process ซ้ำ

**Severity: High**

**ทำไมพังใน production:**
SQS guarantee at-least-once delivery — message อาจถูก deliver มากกว่า 1 ครั้งในกรณี:
- Worker crash หลัง process เสร็จแต่ก่อน delete message
- Network error ระหว่าง delete message
- Visibility timeout expire
ถ้า worker process document เดิม 2 ครั้ง → OCR ซ้ำ → submit ไป Core Banking 2 ครั้ง → duplicate loan application entry

**Fix:**
- เก็บ idempotency key (เช่น S3 object ETag หรือ message ID) ใน database
- ก่อน process ให้ check ว่า document นี้ถูก process แล้วหรือยัง
- ถ้า process แล้ว → skip และ delete message ออกจาก queue

---

## Flaw 5: External SaaS Antivirus ไม่มี Fallback

**Severity: High**

**ทำไมพังใน production:**
ถ้า third-party antivirus SaaS unavailable (maintenance, outage, rate limit exceeded) worker จะรอหรือ fail การออกแบบให้ทุก document ต้องผ่าน antivirus ก่อน แต่ไม่มี fallback ทำให้:
- ถ้า timeout → process ต่อโดยไม่ scan (security risk) หรือ
- ถ้า fail → queue up ทุก document จน SaaS กลับมา (availability risk)

**Fix:**
- กำหนด policy ชัดเจน: ถ้า antivirus unavailable จะทำอะไร (reject document? quarantine? allow with audit log?)
- พิจารณา fallback provider หรือ on-premises scan option
- ตั้ง timeout ที่เหมาะสมและ alert ถ้า SaaS error rate สูง

---

## Flaw 6: RDS ที่ใช้ร่วมกับ Case 01 — Coupling ระหว่าง Systems

**Severity: Medium**

**ทำไมพังใน production:**
ถ้า document pipeline ทำ query หนักๆ (เช่น full table scan เพื่อ audit) จะกระทบ loan portal application ที่ใช้ DB เดียวกัน และ RDS ยังเป็น Single-AZ ตาม Case 01

**Fix:**
- พิจารณาแยก database สำหรับ document pipeline
- อย่างน้อย ใช้ read replica สำหรับ reporting/audit query

---

## Flaw 7: ไม่มี Monitoring บน Queue Depth และ Processing Lag

**Severity: Medium**

**ทำไมพังใน production:**
ถ้า document สะสมใน queue เพราะ worker ช้าหรือ Core Banking ล่ม จะไม่รู้จนกว่าลูกค้า complain ว่า document ไม่ได้รับการ process
Queue depth โต = processing lag โต = ลูกค้ารอนาน = SLA breach

**Fix:**
- CloudWatch Alarm บน `ApproximateNumberOfMessagesVisible` > threshold
- Alert บน processing time ของแต่ละ document
- Dashboard แสดง queue depth, DLQ depth, processing success rate

---

## Summary

| # | Flaw | Severity |
|---|---|---|
| 1 | SQS ไม่มี DLQ | Critical |
| 2 | Retry storm / Core Banking coupling | Critical |
| 3 | Workers ใน single AZ | High |
| 4 | ไม่มี idempotency | High |
| 5 | External AV ไม่มี fallback | High |
| 6 | Shared DB coupling | Medium |
| 7 | ไม่มี queue depth monitoring | Medium |

**Critical flaws (2):** ต้อง fix ก่อน go-live
**High flaws (3):** ต้อง fix ก่อน go-live
**Medium flaws (2):** fix ใน sprint แรกหลัง launch
