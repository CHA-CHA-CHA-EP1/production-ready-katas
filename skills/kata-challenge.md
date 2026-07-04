---
name: kata-challenge
description: Spot-the-Bug challenge after kata review — uses retrieval practice to test deep understanding, not pattern memorization
---

# Kata Challenge

## Purpose

ทดสอบว่าเข้าใจ *concept* จริง ไม่ใช่แค่จำ *pattern* ที่เพิ่งแก้

Challenge จะ generate snippet ใหม่ที่มี bug ประเภทเดียวกับที่เจอใน review แต่เปลี่ยน context — ถ้าจำแนกได้แสดงว่าเข้าใจจริง ไม่ใช่แค่ทำตาม

---

## Rules

1. **อย่าเฉลยก่อน** — user ต้อง type คำตอบก่อนเสมอ ไม่ hint ไม่ multiple choice
2. **เปลี่ยน surface** — snippet ต้องต่างจาก code ที่ review ไปแล้ว (function name, use case, context ต่างกัน) แต่ bug category เดิม
3. **หนึ่ง bug ต่อ challenge** — ไม่ซ้อนหลาย bug ในครั้งเดียว ให้ focus
4. **ให้ feedback หลัง user ตอบเท่านั้น**
5. **ถามทีละข้อ** — generate 3 challenges แต่โชว์ทีละข้อ รอ user ตอบและ check คำตอบให้เสร็จก่อน แล้วค่อยไปข้อถัดไป
6. **concept ต้องต่างกันทั้ง 3 ข้อ** — ดึงจาก `Concepts Involved` ใน kata spec ไม่ถาม concept เดิมซ้ำ

---

## How to Generate the Challenges

1. อ่าน kata spec — ดู `Concepts Involved` section เพื่อรู้ว่า kata นี้สอน concept อะไรบ้าง (เช่น `fd-lifecycle`, `error-wrapping`, `memory-allocation`)
2. คิด 3 challenge จาก bug patterns ที่ engineer มักพลาดจริงๆ ใน domain เดียวกับ kata — **ไม่ต้องยึดติดกับ concepts list ของ kata** คิดจาก production scenarios จริง เช่น concurrent load, large files, permission issues, network filesystem แต่ละ challenge ต้องต่าง bug category กัน คิดใหม่ทุกรอบ อย่าวนซ้ำ pattern เดิม
3. สำหรับแต่ละ challenge — สร้าง snippet ที่:
   - ใช้ use case ต่างออกไป (เช่น `ReadConfig` → `ReadCertificate`, `LoadTemplate`, `ReadKey`)
   - bug subtle พอที่จะต้องอ่านทั้งฟังก์ชัน แต่ไม่ยากจนต้องรู้ edge case ลึกมากหรือ compiler internals — developer ที่เข้าใจ concept จริงควร spot ได้
   - hint อยู่ใน code เสมอ ไม่ต้องอาศัย knowledge นอก snippet
   - ยาวพอให้มี noise — อย่าให้ bug obvious จากความสั้นของ code
4. เรียง 3 ข้อจากง่ายไปยาก

---

## Challenge Format

โชว์ทีละข้อ — format แต่ละข้อ:

```
## Challenge [N/3]: Spot the Bug

Context: [อธิบาย scenario สั้นๆ — function นี้ทำอะไร ใช้ที่ไหน]

[snippet]

มีอะไรผิดในโค้ดนี้?
- ชี้บรรทัดที่ผิด
- อธิบายว่าจะเกิดอะไรขึ้นใน production (ไม่ใช่แค่ "มัน leak")
- บอกว่าจะแก้ยังไง

(type คำตอบก่อน — ยังไม่เฉลย)
```

หลัง check คำตอบข้อนั้นเสร็จแล้ว → โชว์ข้อถัดไปเอง

---

## After User Answers

### ถ้าถูกครบ
- ยืนยัน + อธิบายเพิ่มว่า *ทำไม* bug นี้ถึง subtle / เจอบ่อยใน production
- ถ้า finding นี้มี concept doc ที่เกี่ยว → link ให้

### ถ้าผิดหรือไม่ครบ
- ไม่บอกตรงๆ ทันที — ถามให้ลองคิดใหม่ก่อน 1 ครั้ง
- ถ้ายังผิด → เฉลย + อธิบาย + link concept doc ที่เกี่ยว

### Pattern Connection (ทุกครั้งหลังเฉลย)
Connect กลับไปที่ finding ใน review เสมอ:
> "นี่คือ bug category เดียวกับที่เจอใน [kata name] — [ชื่อ finding]"

ถ้า bug นี้มี concept doc:
> "อ่านเพิ่มที่ shared/concepts/[doc].md — section [ชื่อ section]"
