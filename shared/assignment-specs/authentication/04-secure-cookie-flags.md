---
tier: authentication
difficulty: 1
concepts: [cookie-security, httponly, secure-flag, samesite, csrf, xss]
---

# Kata: Secure Cookie Flags

## Context

Session cookie ที่ set ผิด flag เดียวทำให้ XSS หรือ CSRF attack สำเร็จได้ทันที
browser มี security feature หลายอย่างสำหรับ cookie — แต่ต้อง opt-in ทุกอย่างเอง
default ของ `http.Cookie` ใน Go คือไม่มี flag อะไรเลย — developer ต้องรู้และ set เอง

## Real World Incidents

**Incident 1 — Session Hijacking via XSS (British Airways, 2018)**
British Airways ถูก Magecart attack — attacker inject script ลงใน checkout page
script ขโมย session cookie และ payment data ของ customer ประมาณ 500,000 คน
cookie ที่ไม่มี `HttpOnly` flag ทำให้ `document.cookie` อ่าน session token ได้จาก JavaScript
ค่า fine จาก GDPR สูงถึง 20 ล้านปอนด์ (ลดจาก 183 ล้านปอนด์ที่เสนอแรก)

**Incident 2 — CSRF Attack via Missing SameSite (ทั่วไป, ก่อน 2020)**
ก่อนที่ browser จะเปลี่ยน default เป็น `SameSite=Lax` ใน 2020, form ที่ submit จาก website อื่น
ส่ง cookie ไปด้วยโดยอัตโนมัติ — ทำให้ attacker สร้าง page ที่ submit action โดยไม่รู้ตัวได้
banking site หลายแห่งได้รับผลกระทบจาก CSRF ที่ทำ transfer ในนามของ user
แก้ด้วยการ set `SameSite=Strict` หรือ `SameSite=Lax` พร้อม CSRF token เป็น defense in depth

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// ❌ set cookie แบบ minimal — ไม่มี flag อะไรเลย
http.SetCookie(w, &http.Cookie{
    Name:  "session",
    Value: sessionID,
})

// ❌ set บางอย่างแต่ลืมบางอย่าง
http.SetCookie(w, &http.Cookie{
    Name:     "session",
    Value:    sessionID,
    HttpOnly: true,
    // ลืม Secure, SameSite, Path, MaxAge
})
```

**พังตอนไหน:**
- ไม่มี `HttpOnly` → JavaScript `document.cookie` อ่าน session token ได้ → XSS = account takeover
- ไม่มี `Secure` → cookie ถูกส่งผ่าน HTTP ที่ไม่ encrypted → man-in-the-middle ดัก token ได้
- ไม่มี `SameSite` → cross-origin form submit ส่ง cookie ไปด้วย → CSRF attack สำเร็จ
- ไม่มี `Path` → cookie ส่งไปทุก path รวมถึง third-party script ที่ serve จาก path อื่น
- ไม่มี `MaxAge` → session ไม่มีวันหมดอายุจาก browser side → session ที่ถูกขโมยไม่มีวันหมดอายุ

**Root cause:**
Go `http.Cookie` zero value ไม่ set flag อะไรเลย — ต้องรู้และ set ทุก field เอง
browser ออกแบบให้ backwards compatible — cookie ที่ไม่มี flag ก็ใช้ได้ แต่ไม่ปลอดภัย
developer ที่ไม่รู้เรื่อง cookie security model จะเขียนโค้ดที่ "ใช้ได้" แต่เป็น security hole

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `http.Cookie` struct — list ทุก field ที่เกี่ยวกับ security ออกมา มีกี่ field? field ไหน Go ใส่ไว้ให้ default?
- hint: `http.SameSiteStrictMode` vs `http.SameSiteLaxMode` vs `http.SameSiteNoneMode` — ต่างกันยังไง? `None` ต้องใช้คู่กับ flag อะไร?
- `HttpOnly: true` บล็อกอะไรได้บ้าง? มีอะไรที่มัน**ไม่**บล็อก? (JavaScript ยังทำอะไรได้บ้าง?)
- `Secure: true` บล็อกอะไร? ถ้า serve ผ่าน HTTP ใน local dev แล้ว set `Secure: true` จะเกิดอะไรขึ้น?
- `MaxAge` vs `Expires` — อันไหน preferred ใน HTTP spec สมัยใหม่? ต่างกันยังไงถ้า user ปิด browser?
- OAuth callback ต้องใช้ `SameSite=Lax` ไม่ใช่ `Strict` — ทำไม? OAuth flow มี cross-origin redirect ยังไง?

## Task

เขียนฟังก์ชัน:

```go
func SetSessionCookie(w http.ResponseWriter, sessionID string, rememberMe bool)
```

`SetSessionCookie` set session cookie พร้อม security flag ที่ถูกต้องทุกตัว
ถ้า `rememberMe = true` ให้ cookie อยู่ได้ 30 วัน, ถ้า `false` ให้เป็น session cookie (ปิด browser หาย)

## Requirements

- `HttpOnly: true` — เสมอ ไม่มีข้อยกเว้น
- `Secure: true` — เสมอ ไม่มีข้อยกเว้น (assume production ใช้ HTTPS)
- `SameSite: http.SameSiteStrictMode` — สำหรับ normal session cookie
- `Path: "/"` — เสมอ เพื่อให้ cookie ส่งไปทุก path ใน same origin
- `MaxAge` — ถ้า `rememberMe = true`: 30 วัน (เป็นวินาที), ถ้า `false`: 0 (session cookie)
- ห้าม set `Domain` field — ปล่อย browser ใช้ exact origin แทน (subdomain sharing ต้องการ explicit decision)
- ชื่อ cookie ต้องไม่มี space หรือ special character ที่ไม่ valid ตาม RFC 6265

## Acceptance Criteria

- [ ] cookie ที่ set มี `HttpOnly: true` เสมอ
- [ ] cookie ที่ set มี `Secure: true` เสมอ
- [ ] cookie ที่ set มี `SameSite=Strict` เสมอ
- [ ] `rememberMe = true` → `MaxAge` = 2592000 (30 วัน ในวินาที)
- [ ] `rememberMe = false` → `MaxAge` = 0 (session cookie หายเมื่อปิด browser)
- [ ] `Path` = `"/"` เสมอ
- [ ] `Domain` ไม่ถูก set (zero value)
- [ ] header `Set-Cookie` ใน response มี flag ที่กำหนดครบถ้วน

## Concepts Involved

- `cookie-security` — HttpOnly บล็อก JS access, Secure บล็อก HTTP, SameSite ป้องกัน CSRF → (concept doc ยังไม่มี)
- `csrf` — cross-site request forgery ทำงานยังไง, SameSite เป็น defense layer แรก → (concept doc ยังไม่มี)

## Production Reality

- **ใช้จริง:** ทุก authentication system ที่จริงจังใช้ทั้ง 5 flag: `HttpOnly`, `Secure`, `SameSite`, `Path`, `MaxAge`
- **`__Host-` prefix:** cookie ชื่อ `__Host-session` บังคับให้ browser ตรวจสอบ Secure flag และ Path="/` โดย browser เอง — เป็น defense in depth layer เพิ่มเติม
- **SameSite=None:** ต้องการสำหรับ cross-origin embed เช่น payment iframe — แต่ต้องเข้าใจ risk ก่อน set
- **kata สอนว่า:** security ใน browser มาจาก opt-in flags — รู้จัก flag แต่ละตัวและ threat ที่มันป้องกันก่อน copy-paste โค้ด
