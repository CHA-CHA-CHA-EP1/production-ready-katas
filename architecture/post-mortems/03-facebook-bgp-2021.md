# Post-mortem Reading: Facebook BGP Outage, October 4, 2021

**Sources:**
- Meta Engineering Blog: https://engineering.fb.com/2021/10/04/networking-traffic/outage/
  *(fetched in this session — high-level; use this for official Meta statements)*
- Cloudflare Analysis: https://blog.cloudflare.com/october-2021-facebook-outage/
  *(external analysis with DNS and BGP routing details — not Meta's official account)*

**Themes:** backbone failure causing DNS/BGP cascade, health check coupled to routing, recovery hampered by disrupted internal tools

---

## Incident Summary

วันที่ 4 ตุลาคม 2021 Facebook, Instagram, WhatsApp และ Messenger ไม่สามารถเข้าถึงได้นานประมาณ 6 ชั่วโมง กระทบผู้ใช้หลายพันล้านคนทั่วโลก

**จาก Meta's official post:** การ outage เริ่มจาก configuration change บน backbone router ที่ดูแล traffic ระหว่าง data center ของ Meta การเปลี่ยนแปลงนี้ทำให้การสื่อสารระหว่าง data center หยุดชะงัก และยังกระทบ internal tools และ systems ที่ Meta ใช้ในการ diagnose และ resolve ปัญหาอีกด้วย Meta ยืนยันว่าไม่มี malicious activity และไม่มี user data ที่ถูก compromise

**จาก Cloudflare's external analysis (BGP และ DNS perspective):**
เมื่อ backbone connectivity หายไป DNS server ของ Facebook ที่ทำหน้าที่เป็น authoritative nameserver ไม่สามารถ communicate กลับมายัง data center ได้ ตาม analysis ของ Cloudflare DNS server เหล่านั้นถอน BGP route ที่ประกาศ IP address ของตัวเองออกจาก internet routing table ส่งผลให้ resolver ทั่วโลกไม่สามารถ reach Facebook's nameservers เพื่อ resolve domain ได้อีก เมื่อ DNS ไม่ resolve ทุก service ของ Facebook จึงหายไปจาก internet โดยสมบูรณ์ แม้แต่คนที่รู้ IP address ของ Facebook โดยตรงก็ reach ไม่ได้เพราะ BGP route ของ IP prefix ถูก withdraw

**เรื่อง recovery:** Meta's official post ระบุว่า configuration change ยังกระทบ internal tools ด้วย ทำให้การ diagnose ช้าลง แต่ไม่ได้ระบุรายละเอียดเพิ่มเติมเกี่ยวกับสาเหตุที่ recovery ใช้เวลานาน รายละเอียดเพิ่มเติมเกี่ยวกับ physical access และ staffing จะปรากฏใน subsequent posts ของ Meta ซึ่งไม่ได้ verify ในเซสชันนี้

---

## Design Review Questions — ก่อน incident ควรถามอะไร

ลองตอบเองก่อน แล้วค่อยดูแนวคิดด้านล่าง

<details>
<summary>แนวคิดหลังจากคิดเองแล้ว</summary>

**เรื่อง backbone change safety:**
- "backbone router configuration change มี validation / rollback plan ไหม?"
- "change นี้ tested ใน staging environment ก่อน apply production ไหม?"
- "blast radius ถ้า change นี้ fail คือ network ขาดเฉพาะ edge หรือขาดทั้ง backbone?"

**เรื่อง DNS / BGP coupling:**
- "DNS server ที่ depend on connectivity กลับไป data center — ถ้า connectivity หาย DNS server ทำอะไร? withdraw BGP ไหม? หรือ serve stale records?"
- "authoritative nameservers มี BGP redundancy จาก multiple independent paths ไหม?"
- "ถ้า nameservers ทั้งหมดถอน route พร้อมกัน domain จะหายจาก internet ได้ไหม? มี minimum announcement requirement ไหม?"

**เรื่อง internal tools dependency:**
- "internal tools (monitoring, incident management, deployment) ขึ้นอยู่กับ production infrastructure เดียวกันไหม?"
- "ถ้า production network ล่ม engineer ยังสามารถ communicate และ access diagnostic tool ได้ไหม?"
- "out-of-band management channel มีไหม?"

</details>

---

## Design Changes That Would Have Limited the Blast Radius

ลองคิดเองก่อน แล้วค่อยดูแนวคิดด้านล่าง

<details>
<summary>แนวคิดหลังจากคิดเองแล้ว</summary>

**1. Staged rollout สำหรับ backbone configuration change**
- Apply configuration ที่ router หนึ่งก่อน ตรวจ connectivity ก่อน proceed
- มี automated health check หลัง apply กับ automatic rollback ถ้า connectivity drops

**2. DNS health check ที่ไม่ depend on backbone**
- DNS server ไม่ควร withdraw BGP route เพียงเพราะไม่เห็น data center
- health check ของ DNS server ควรแยก plane จาก data path: management plane อิสระจาก data plane
- อย่างน้อย ควรมี "withdraw ช้าๆ" แทนที่จะ withdraw ทันที เพื่อให้ engineer มีเวลา intervene

**3. Out-of-band management infrastructure**
- Internal tools ที่ใช้ during incident ต้องอยู่บน infrastructure ที่ independent จาก production
- มี separate communication path (เช่น satellite link, dedicated management network) สำหรับ incident response
- engineer ทุกคนควรมี fallback authentication method ที่ไม่พึ่ง internal IdP

**4. Graceful DNS degradation**
- ถ้า nameservers ไม่สามารถ reach data center — serve last-known-good answers แบบ read-only แทนที่จะ withdraw
- TTL ที่เหมาะสม: ยาวพอให้ user cache ช่วย absorb short outage แต่สั้นพอให้ recover เร็วหลังจาก fix

</details>

---

## Key Themes

- **Backbone เป็น SPOF ที่ซ่อน:** network infrastructure ที่ span ทุก data center ถ้า fail พร้อมกันทำให้ทุกอย่างพัง
- **Health check coupling กับ routing:** เมื่อ health check และ BGP advertisement ผูกกัน failure ของ health check → route withdrawal → service disappears from internet — cascading failure ที่ amplify ผล
- **Internal tools บน production infra:** ถ้า tool ที่ใช้ fix production อยู่บน production infra เดียวกัน outage ทำให้ทั้ง fix และ diagnose ยากขึ้นพร้อมกัน
- **DNS เป็น single point of internet presence:** ถ้า authoritative DNS หายไป ทุก service บน domain นั้นหายตาม — ต้องออกแบบ DNS availability ให้ resilient อย่างน้อยเท่ากับ service ที่สำคัญที่สุด
