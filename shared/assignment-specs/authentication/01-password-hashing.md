---
tier: authentication
difficulty: 1
concepts: [password-hashing, bcrypt, work-factor, timing-attack, constant-time-compare]
---

# Kata: Password Hashing

## Context

การเก็บ password ผิดวิธีเป็นหนึ่งในความผิดพลาดที่ร้ายแรงที่สุดใน web security
เมื่อ database breach เกิดขึ้น (และมันจะเกิด) สิ่งเดียวที่ป้องกัน user ได้คือ hash ที่ดี
ถ้าใช้ MD5 หรือ SHA1 — ข้อมูล user ทุกคนถือว่าเปิดเผยทันที ไม่ว่า breach จะเล็กหรือใหญ่แค่ไหน

## Real World Incidents

**Incident 1 — LinkedIn Password Breach (LinkedIn, 2012)**
LinkedIn ถูก breach และ password hash 6.5 ล้านรายการรั่วไหลออกมา
ปัญหาคือ LinkedIn ใช้ SHA1 แบบไม่มี salt — hash เดียวกัน = password เดียวกัน
ภายในไม่กี่วัน password เกือบทั้งหมดถูก crack ด้วย rainbow table และ GPU
ต่อมาพบว่า breach จริงมี 117 ล้าน account — LinkedIn อัปเกรดมาใช้ bcrypt หลังจากนั้น

**Incident 2 — RockYou Plain Text Passwords (RockYou, 2009)**
เว็บไซต์ social game RockYou ถูก SQL injection และ password 32 ล้านรายการรั่วไหล
password ทั้งหมดถูกเก็บเป็น plain text — ไม่มี hash ใดๆ เลย
incident นี้กลายเป็น dataset ที่ใช้ทำ wordlist สำหรับ brute force จนถึงทุกวันนี้
บทเรียน: ไม่มี excuse สำหรับการเก็บ plain text password แม้แต่ "social game เล็กๆ"

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// ❌ SHA256 — ดูดีกว่า MD5 แต่ยังผิดอยู่
hash := sha256.Sum256([]byte(password))
stored := hex.EncodeToString(hash[:])

// ❌ bcrypt แต่ cost ต่ำเกินไป
hash, _ := bcrypt.GenerateFromPassword([]byte(password), bcrypt.MinCost) // cost = 4

// ❌ เปรียบเทียบด้วย == ตรงๆ
if storedHash == computedHash { ... }
```

**พังตอนไหน:**
- SHA256 ไม่มี salt → rainbow table crack ได้ทันที
- SHA256 เร็วเกินไป → GPU crack ได้ ~10 billion hash/วินาที
- bcrypt cost ต่ำ → brute force ได้เร็วกว่าที่ควร
- เปรียบเทียบด้วย `==` → timing attack รู้ได้ว่า hash ตรงกันมากแค่ไหน

**Root cause:**
SHA1/SHA256 ถูกออกแบบให้เร็ว — ดีสำหรับ integrity check แต่แย่สำหรับ password
password ที่คนใช้จริงมี entropy ต่ำ (เช่น "password123") — hash เร็วๆ crack ได้ใน seconds
bcrypt แก้ปัญหานี้ด้วย work factor ที่ปรับได้ — ทำให้แต่ละ attempt ช้าลงโดยตั้งใจ

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `bcrypt.GenerateFromPassword(password []byte, cost int)` — `cost` parameter หมายถึงอะไร? cost 10 กับ cost 12 ต่างกันกี่เท่าในเชิง computation?
- hint: `bcrypt.CompareHashAndPassword(hash, password []byte)` — ทำไมถึงใช้ฟังก์ชันนี้แทนการ hash แล้วเปรียบเทียบเอง?
- hint: `subtle.ConstantTimeCompare(x, y []byte)` — ต่างจาก `bytes.Equal` ยังไง? ทำไม timing ถึงสำคัญในการเปรียบเทียบ secret?
- bcrypt มี limit 72 bytes — ถ้า password ยาวกว่านั้นจะเกิดอะไรขึ้น? จะ detect และ handle ยังไง?
- `bcrypt.CompareHashAndPassword` return `nil` เมื่อตรงกัน — ถ้า return `error` หมายความว่าอะไร? ควร expose error นั้นให้ caller ไหม?

## Task

เขียนสองฟังก์ชัน:

```go
func HashPassword(password string) (string, error)
func VerifyPassword(hash, password string) bool
```

`HashPassword` รับ plain text password แล้วคืน bcrypt hash ที่พร้อมเก็บใน database
`VerifyPassword` รับ stored hash และ plain text password แล้วคืน `true` ถ้าตรงกัน — คืน `false` ทุกกรณีที่ไม่ตรง (รวมถึง error) โดยไม่รั่ว error detail ออกไป

## Requirements

- ต้องใช้ bcrypt cost >= 12 (ห้ามใช้ `bcrypt.MinCost` หรือค่าน้อยกว่า 12)
- ต้อง reject password ที่ยาวกว่า 72 bytes ก่อนส่งเข้า bcrypt (bcrypt silently truncate — อย่าให้ silent)
- `VerifyPassword` ต้อง return `false` เสมอเมื่อไม่ตรงกัน — ห้าม return error หรือ panic ออกนอกฟังก์ชัน
- `VerifyPassword` ต้องไม่รั่วข้อมูลว่า "hash format ผิด" vs "password ไม่ตรง" ผ่าน return value
- Error message จาก `HashPassword` ต้องมี context เช่น `"HashPassword: password exceeds 72 bytes"` ไม่ใช่แค่ `"too long"`

## Acceptance Criteria

- [ ] `HashPassword("correct-password")` คืน hash ที่ `VerifyPassword` ตรวจสอบผ่าน
- [ ] `VerifyPassword(hash, "wrong-password")` คืน `false` — ไม่ panic ไม่ return error
- [ ] `HashPassword` สองครั้งด้วย password เดียวกัน คืน hash ที่ต่างกัน (salt ต่างกัน)
- [ ] `HashPassword` ด้วย password ที่ยาวกว่า 72 bytes คืน error ที่ชัดเจน
- [ ] Hash ที่ได้มี prefix `$2a$` และ cost >= 12 เมื่อดูด้วยตา
- [ ] `VerifyPassword` ด้วย hash ที่ malformed คืน `false` — ไม่ crash

## Concepts Involved

- `password-hashing` — ทำไม fast hash ถึงแย่สำหรับ password, work factor คืออะไร, salt ป้องกัน rainbow table ยังไง → `shared/concepts/password-hashing.md`
- `timing-attack` — early-exit comparison รั่วข้อมูลยังไง, constant-time compare แก้ยังไง → `shared/concepts/password-hashing.md`

## Production Reality

- **ใช้จริง:** bcrypt cost 12 ใช้กันทั่วไปใน production — cost 14+ สำหรับ high-security system
- **Argon2id** ดีกว่า bcrypt ในหลายด้าน (memory-hard, resistant to GPU attack) แต่ ecosystem Go ยังไม่ mature เท่า — ถ้าขึ้น project ใหม่ในปี 2025+ พิจารณา `golang.org/x/crypto/argon2`
- **kata สอนว่า:** work factor ทำให้ attacker ช้าลง — hash ที่ใช้เวลา 300ms ต่อครั้งฟังดูช้า แต่นั่นแหละคือจุดประสงค์
