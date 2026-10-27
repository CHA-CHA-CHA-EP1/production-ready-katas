# Questions for App Teams — Design Review

คำถามสำหรับใช้ระหว่าง design review session กับ app team
เป้าหมาย: ช่วยให้ team คิดถึง dimension ที่อาจ miss ไป ไม่ใช่เพื่อ catch พวกเขา

---

## เปิด Review

- "ช่วย walk me through design นี้ใน 5 นาทีได้ไหม — เริ่มจาก request journey ของ user"
- "ส่วนไหนของ design ที่คุณยังไม่แน่ใจที่สุด?"
- "assumption หลักที่ทำให้ design นี้ work คืออะไร?"

---

## Reliability

- "ถ้า [component หลัก] down ตอน 3 ทุ่ม ระบบทำอะไร? user จะเห็นอะไร?"
- "component ไหนที่ถ้าพังแล้วกระทบ user 100%? มีแผน mitigate ไหม?"
- "คุณทดสอบ failover จริงๆ ไหม หรือ assume ว่า Multi-AZ จะ work เอง?"
- "ถ้า database connection หมด pool ระบบจัดการยังไง?"
- "retry logic ของคุณมี exponential backoff ไหม? ถ้าไม่มี เกิด thundering herd ได้ไหม?"
- "RTO ของคุณคือเท่าไร? ถ้า deploy ใหม่ใช้เวลา 20 นาที RTO นั้น acceptable ไหม?"

---

## Security

- "secret เก็บอยู่ที่ไหน? ใครดู secret นั้นได้บ้าง?"
- "ถ้าผมมี access read ECS task definition ผมเห็นอะไรได้บ้าง?"
- "S3 bucket ที่เก็บข้อมูล user — ใคร access ได้บ้าง? access ผ่านช่องทางไหน?"
- "IAM role ของ application มี permission อะไรบ้าง? จำเป็นทั้งหมดไหม?"
- "ถ้า EC2 ตัวหนึ่งถูก compromise attacker ทำอะไรได้บ้างจาก instance นั้น?"
- "audit trail ของ admin action มีไหม? ดูได้จากไหน?"

---

## Data and Classification

- "data ที่ system นี้ handle มี classification ไหม? (public / internal / confidential / restricted)"
- "data ที่ sensitive ที่สุดใน system นี้คืออะไร? เก็บที่ไหน? ใครมี access?"
- "ถ้า database leak ออกไป impact ต่อ user คืออะไร? ต่อ business?"
- "data residency requirement มีไหม? data ออกนอก region ได้ไหม?"
- "retention policy ของ data คืออะไร? data ถูก delete เมื่อไร?"

---

## Cost

- "cost driver หลักของ design นี้คืออะไร?"
- "ถ้า traffic เพิ่ม 10x cost จะเพิ่มกี่เท่า? linear ไหม?"
- "NAT Gateway cost per GB — traffic ที่ออก internet มีปริมาณเท่าไรต่อเดือน?"
- "มี cost alert ไหม? ถ้า cost spike 3x จากปกติจะรู้ได้ยังไง?"

---

## Observability

- "ถ้า error rate เพิ่มขึ้นเป็น 5% คุณจะรู้ได้ยังไง? ในกี่นาที?"
- "ถ้ามี user complaint ว่า transaction ช้า คุณจะ trace ปัญหาไปถึงระดับ service ได้ไหม?"
- "request ที่ fail ในสัปดาห์ที่แล้วมี pattern อะไร? คุณ query ได้ไหม?"
- "metric ที่คุณดู on-call คืออะไร? dashboard มีไหม?"

---

## Operational

- "deploy process มีกี่ manual step? ใครทำได้บ้าง?"
- "rollback ทำได้ไหม? ใช้เวลากี่นาที? เคย test rollback ไหม?"
- "runbook สำหรับ 'database ไม่ตอบ' มีไหม?"
- "on-call rotation มีไหม? alert ส่งไปหาใครตอนตี 2?"

---

## Scale and Future

- "design นี้รองรับ load ได้ถึงแค่ไหนก่อนที่จะต้อง redesign?"
- "6 เดือนข้างหน้ามี feature อะไรใหม่ที่จะกระทบ architecture นี้?"
- "ถ้าต้องเพิ่ม team ใหม่เข้ามา access data ใน system นี้ จะทำยังไง?"

---

## ปิด Review

- "จากที่คุย ส่วนไหนที่คุณรู้สึกว่าต้อง revisit ก่อน go-live?"
- "มีข้อกังวลด้านไหนที่ยังไม่ได้พูดถึงไหม?"
- "timeline ของ go-live คือเมื่อไร? มีเวลา address feedback ก่อนไหม?"
