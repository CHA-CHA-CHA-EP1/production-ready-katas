---
tier: authentication
difficulty: 2
concepts: [jwt, xss, csrf, httponly-cookie, token-storage, session-management]
---

# Kata: Bearer Token Storage

## Context

"เราใช้ JWT แล้ว ปลอดภัยแน่นอน" — ประโยคนี้ผิดครึ่งหนึ่ง
JWT เป็นแค่ format ของ token ไม่ใช่กลไกป้องกัน token theft
ปัญหาจริงคือ token เก็บไว้ที่ไหน: `localStorage` ที่ JavaScript ทุกตัวบนหน้าเว็บเข้าถึงได้ หรือ `httponly cookie` ที่ JavaScript แตะไม่ได้เลย

## Real World Incidents

**Incident 1 — XSS + localStorage Token Theft (British Airways, 2018)**
Magecart group inject JavaScript ไว้ใน script ของ third-party payment form บนเว็บ British Airways
script ที่ inject มีสิทธิ์อ่าน `localStorage` ทั้งหมด รวมถึง JWT session token ของผู้ใช้ที่ login อยู่
token ถูกส่งออกไปยัง attacker's server แบบ real-time ระหว่างที่ผู้ใช้ทำ booking
ผลกระทบ: ข้อมูล 500,000 คน รวมถึง payment details และ session token — ปรับ GDPR £20M

**Incident 2 — Stored XSS ขโมย Token ใน Slack (Bug Bounty Report, 2019)**
นักวิจัยพบ stored XSS ใน Slack workspace name ที่แสดงใน electron desktop app
เพราะ Slack เก็บ session token ใน `localStorage` ของ electron (ซึ่งเข้าถึงได้ด้วย JavaScript เหมือนกัน)
XSS payload ดึง token ออกมาได้และ exfiltrate ออกไป ทำให้ attacker เข้า workspace ได้โดยไม่ต้องรู้ password
Slack แก้โดยย้ายมาใช้ httponly cookie + เพิ่ม CSP header ที่เข้มข้นขึ้น

**Incident 3 — "We Use JWT So We're Safe" (SaaS Startup postmortem, 2022)**
ทีม dev เชื่อว่า JWT stateless = ไม่ต้องกังวลเรื่อง session hijacking
เก็บ JWT ใน `sessionStorage` คิดว่าดีกว่า `localStorage` เพราะปิด tab แล้วหาย
จริงอยู่ว่า lifetime สั้นกว่า แต่ `sessionStorage` ยัง accessible จาก JavaScript ในหน้าเดียวกัน
XSS attack ที่เกิดขึ้นยังดึง token ออกได้ตลอด session ที่ tab ยังเปิดอยู่ — และ session ของผู้ใช้มักเปิดค้างไว้หลายชั่วโมง

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
หลัง login สำเร็จ server ส่ง JWT กลับใน response body แล้ว client เก็บไว้ใน `localStorage`
ทุก request ถัดไป client อ่าน token จาก `localStorage` แล้วใส่ใน `Authorization: Bearer <token>` header

**พังตอนไหน:**
- Third-party script (analytics, chat widget, A/B testing SDK) ที่โหลดมาจาก CDN อื่น มีสิทธิ์อ่าน `localStorage` ทั้งหมด
- Stored XSS แม้แค่ injection เล็กน้อยก็ดึง token ออกได้ทันที
- Browser extension ที่ติดตั้งโดย user ก็เข้าถึง `localStorage` ได้เช่นกัน
- Developer tools ที่เปิดทิ้งไว้บนเครื่อง shared ก็เห็น token ทันที

**Root cause:**
`localStorage` และ `sessionStorage` เป็น JavaScript-accessible storage — ไม่มีกลไกใดใน browser ที่ป้องกัน JavaScript บนหน้าเดียวกันไม่ให้อ่าน
`HttpOnly` cookie คือ flag พิเศษที่บอก browser ว่า "JavaScript แตะ cookie นี้ไม่ได้" — มีเฉพาะ HTTP requests เท่านั้นที่ส่ง cookie นี้ไปได้

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `http.Cookie` struct — field `HttpOnly bool` ทำงานยังไง? browser enforce กฎนี้ที่ไหน (client-side หรือ server-side)?
- hint: `http.Cookie.SameSite` — `http.SameSiteStrictMode` vs `http.SameSiteLaxMode` vs `http.SameSiteNoneMode` ต่างกันยังไง? แต่ละแบบ protect อะไรได้บ้าง? `SameSiteNoneMode` ต้องใช้ร่วมกับ flag อะไร?
- hint: `http.Cookie.Secure` — flag นี้ทำงานยังไง? ถ้าไม่ set แล้ว cookie จะถูกส่งผ่าน HTTP ไหม? นั่นหมายความว่าอะไรสำหรับ Basic Auth ที่เรียนไปก่อนหน้า?
- ลอง decode JWT token (สามส่วน header.payload.signature) ด้วย `base64.RawURLEncoding.DecodeString` — อ่านได้ไหม? นั่นหมายความว่าอะไรสำหรับ sensitive data ใน payload?
- hint: CSRF double-submit cookie pattern — ถ้า server set cookie สองตัว: `session` (HttpOnly) และ `csrf_token` (readable by JS) แล้ว client ต้องส่ง `X-CSRF-Token` header ที่ตรงกับ `csrf_token` cookie — ทำไม attacker ถึงทำไม่ได้? SameSite ช่วยได้ตรงไหน?
- hint: `r.Header.Get("Authorization")` — ถ้า client ส่ง `Authorization: Bearer <token>` จะดึง token ออกมายังไง? ใช้ `strings.CutPrefix` หรือ `strings.TrimPrefix` ดีกว่ากัน? ทำไม?
- ถ้าต้องการรองรับทั้ง web (cookie) และ API (Bearer token) ใน endpoint เดียวกัน — ลำดับการตรวจสอบควรเป็นอะไรก่อน? มี security implication ไหนถ้าตรวจผิดลำดับ?

## Task

เขียนสองฟังก์ชัน:

1. `IssueTokenCookie(w http.ResponseWriter, token string)` — set httponly cookie สำหรับ web client พร้อม CSRF token แยกต่างหาก
2. `ExtractTokenFromRequest(r *http.Request) (string, error)` — ดึง token จาก request โดยรองรับทั้ง httponly cookie (web) และ `Authorization: Bearer` header (API client)

## Requirements

- `IssueTokenCookie` ต้องตั้ง `HttpOnly: true`, `Secure: true`, `SameSite: http.SameSiteLaxMode` ขั้นต่ำ
- ห้าม expose JWT token ใน response body สำหรับ web flow (token อยู่ใน cookie เท่านั้น)
- ต้อง generate และ set CSRF token แยกต่างหาก (readable by JS) พร้อมกับ session cookie
- `ExtractTokenFromRequest` ตรวจ `Authorization: Bearer` header ก่อน (API client) แล้วจึง fallback ไปยัง cookie (web client)
- ถ้าใช้ cookie route ต้องตรวจ `X-CSRF-Token` header ด้วยว่าตรงกับ CSRF cookie
- CSRF token comparison ต้องใช้ constant-time comparison
- Return error ที่ชัดเจนแยก case: "no token provided", "csrf token mismatch", "invalid bearer token format"

## Acceptance Criteria

- [ ] `IssueTokenCookie` set cookie ที่มี `HttpOnly`, `Secure`, `SameSite` flags ครบ
- [ ] Token ไม่ปรากฏใน response body JSON สำหรับ web flow
- [ ] CSRF token แยกต่างหากถูก set เป็น cookie ที่ JavaScript อ่านได้ (ไม่ HttpOnly)
- [ ] `ExtractTokenFromRequest` อ่าน Bearer header ได้ถูกต้องสำหรับ API client
- [ ] `ExtractTokenFromRequest` อ่าน cookie ได้สำหรับ web client เมื่อไม่มี Bearer header
- [ ] Request ที่ใช้ cookie แต่ไม่มี `X-CSRF-Token` header หรือ CSRF mismatch → error
- [ ] CSRF comparison ใช้ `subtle.ConstantTimeCompare` ไม่ใช่ `==`
- [ ] มี test: API client with Bearer, web client with valid CSRF, web client with missing CSRF, web client with wrong CSRF, no token at all

## Concepts Involved

- `session-management` — cookie flags (HttpOnly, Secure, SameSite), CSRF attacks, double-submit cookie pattern → `shared/concepts/session-management.md`
- `xss-csrf` — XSS ขโมย token ได้ยังไง, CSRF ทำงานยังไง, defense-in-depth ระหว่าง SameSite + CSRF token → OWASP XSS Prevention Cheat Sheet

## Production Reality

- **ใช้จริง:** Web apps ใช้ httponly cookie + SameSite + CSRF token เสมอ ไม่ว่าจะ session-based หรือ JWT-in-cookie
- **localStorage ใช้ได้เมื่อ:** native mobile app หรือ desktop app ที่ไม่มี JavaScript execution environment (ไม่ใช่ web browser)
- **kata สอนว่า:** JWT เป็น format ไม่ใช่ security mechanism — ความปลอดภัยขึ้นอยู่กับว่าเก็บ token ไว้ที่ไหนและส่งยังไง ไม่ใช่ว่า token มีลายเซ็นหรือเปล่า
