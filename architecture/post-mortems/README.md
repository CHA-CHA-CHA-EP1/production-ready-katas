# Post-mortem Reading Exercises

แต่ละ exercise = อ่าน incident จริง แล้วตอบ 2 คำถาม:

1. **ก่อน incident** — design review ที่ดีควรถามอะไร เพื่อ surface risk นี้ก่อนที่มันจะเกิด?
2. **หลัง incident** — จะออกแบบยังไงให้ blast radius เล็กลง (ไม่ใช่ป้องกัน 100%)?

## วิธีอ่าน

1. อ่าน incident summary ในไฟล์
2. ไปอ่าน source ต้นฉบับที่ link ไว้
3. ตอบสองคำถามข้างบนด้วยตัวเองก่อน
4. เปรียบเทียบกับ "Design Review Questions" และ "Blast Radius Reduction" ในไฟล์

## Exercises

| ไฟล์ | Incident | Themes |
|---|---|---|
| [01-aws-s3-2017.md](01-aws-s3-2017.md) | AWS S3 us-east-1, Feb 2017 | blast radius, monitoring coupling, cascading restarts |
| [02-cloudflare-waf-2019.md](02-cloudflare-waf-2019.md) | Cloudflare WAF regex, Jul 2019 | catastrophic backtracking, staged rollout, global deploy |
| [03-facebook-bgp-2021.md](03-facebook-bgp-2021.md) | Facebook BGP, Oct 2021 | backbone failure, DNS/BGP coupling, cascading withdrawals |
