# Post-mortem Reading: Cloudflare WAF Outage, July 2, 2019

**Source:** https://blog.cloudflare.com/details-of-the-cloudflare-outage-on-july-2-2019/
*(fetched and confirmed in this session)*

**Themes:** catastrophic regex backtracking, global one-shot deploy without staged rollout, CPU exhaustion from software logic

---

## Incident Summary

วันที่ 2 กรกฎาคม 2019 เวลา 13:42 UTC Cloudflare ประสบปัญหา outage ที่กระทบ traffic ที่ proxy ผ่าน Cloudflare ราว 80% ทั่วโลก นาน 27 นาที ก่อนจะ recover ที่ 14:09 UTC

สาเหตุคือ WAF rule ใหม่ที่ถูก deploy เพื่อตรวจจับ XSS attack มี regular expression ที่มีรูปแบบทำให้เกิด catastrophic backtracking ใน PCRE regex engine โดย pattern ที่มีปัญหาคือ nested quantifier ลักษณะ `.*.*=.*` เมื่อ engine ประมวลผล input ที่ไม่ match กับ pattern นี้ จะต้องลอง combination ทุก combination ก่อนจะยืนยันว่าไม่ match จำนวน step เพิ่มแบบ exponential ตามความยาว input — ทดสอบพบว่า input 20 ตัวอักษรต้องการ 555 step ขณะที่ควรใช้เพียงไม่กี่ step

เมื่อ rule นี้ถูก deploy ไปทั่วโลกพร้อมกันทุก data center ในเวลาไม่กี่วินาที CPU ทุก core ที่ serve HTTP traffic บน server ของ Cloudflare ทั่วโลกถูก consume จนหมดทันที ทำให้ legitimate request ทุก request ไม่ได้รับการ serve

Cloudflare deploy WAF rule แบบ global เพราะการ respond ต่อ security threat ใหม่ต้องการ rollout เร็ว ต่างจาก software release ทั่วไปที่มี staged rollout แต่ทำให้ไม่มีโอกาส detect ปัญหาก่อนที่จะ global impact

---

## Design Review Questions — ก่อน incident ควรถามอะไร

ลองตอบเองก่อน แล้วค่อยดูแนวคิดด้านล่าง

<details>
<summary>แนวคิดหลังจากคิดเองแล้ว</summary>

**เรื่อง regex safety:**
- "มี automated test ที่ check ว่า regex ใหม่ไม่มี catastrophic backtracking ก่อน deploy ไหม?"
- "ใช้ regex engine อะไร? engine นั้น guarantee linear-time matching ไหม หรืออาจ exponential?"
- "มี input fuzzing หรือ worst-case input test สำหรับ WAF rule ใหม่ไหม?"

**เรื่อง deploy strategy:**
- "WAF rule deploy แบบ global ทันที หรือมี staged rollout? ถ้า global — อะไรเป็น safety net?"
- "ถ้า rule ใหม่ทำให้ CPU spike ใน data center หนึ่ง มีกลไก automatic rollback หรือ canary ไหม?"
- "metric อะไรที่ monitor ระหว่าง WAF rule deploy? CPU? error rate? latency?"

**เรื่อง blast radius:**
- "ถ้า WAF deploy ผิดพลาด กระทบ traffic กี่ %? มีวิธี limit ได้ไหม (เช่น deploy ที่ 1 PoP ก่อน)?"
- "ถ้าต้อง rollback WAF rule ใช้เวลากี่นาที?"

</details>

---

## Design Changes That Would Have Limited the Blast Radius

ลองคิดเองก่อน แล้วค่อยดูแนวคิดด้านล่าง

<details>
<summary>แนวคิดหลังจากคิดเองแล้ว</summary>

**1. Regex safety gate ใน CI/CD pipeline**
- ใช้ regex engine ที่ guarantee linear-time (เช่น RE2 ที่ Google ใช้ — ไม่มี backtracking)
- เพิ่ม automated test ที่ run regex กับ worst-case input และ measure time ก่อน merge
- ถ้า regex ใช้เวลาเกิน threshold → block deploy

**2. Staged rollout สำหรับ WAF rule**
- Deploy ที่ 1 PoP ก่อน วัด CPU / error rate ค้างไว้ 5-10 นาที
- ถ้า healthy → expand ทีละ region
- มี automatic circuit breaker: ถ้า CPU ขึ้นเกิน X% หลัง deploy → rollback อัตโนมัติ

**3. Independent monitoring ระหว่าง deploy**
- Monitor CPU utilization per PoP real-time ระหว่าง WAF rule deploy
- Alert threshold ต่ำกว่า production threshold ปกติ เพราะ deploy อยู่

**4. Graceful degradation mode**
- ถ้า WAF CPU > threshold → fail open (ยอมให้ traffic ผ่านแบบไม่ inspect) แทนที่จะ block ทั้งหมด
- trade-off: บาง malicious traffic อาจผ่านในช่วงสั้นๆ แทนที่จะ block legitimate traffic ทั้งหมด

</details>

---

## Key Themes

- **Catastrophic backtracking:** regex pattern ที่ดูบริสุทธิ์อาจมี worst-case ที่ exponential — ต้องมี automated gate
- **Global deploy without canary:** speed ของ global deploy ที่เป็น feature (security response) กลายเป็น blast radius amplifier เมื่อมี bug
- **CPU exhaustion as failure mode:** software bug สามารถ exhaust CPU ได้เหมือน traffic spike — resource protection ต้องรองรับทั้งสองกรณี
- **Monitoring coupling กับ deploy:** ต้อง monitor สิ่งที่อาจเสียหายจาก change ที่กำลัง deploy ทันที ไม่ใช่รอ alert ปกติ
