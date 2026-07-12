---
tier: authentication
difficulty: 1
concepts: [basic-auth, http-headers, constant-time-comparison, tls-enforcement, session-management]
---

# Kata: Basic Authentication Middleware

## Context

Basic Auth เป็น authentication scheme ที่ง่ายที่สุดใน HTTP — แต่ "ง่าย" ไม่ได้แปลว่า "ปลอดภัยโดยอัตโนมัติ"
หลาย internal tool, admin panel, และ webhook endpoint ยังใช้ Basic Auth อยู่ใน production
ปัญหาคือโค้ดที่เขียนตามสัญชาตญาณแรกมักเปิดช่องโหว่สองอย่าง: credentials โดนดักฟัง และ/หรือ รั่วออกใน log

## Real World Incidents

**Incident 1 — Credentials ใน Access Log (Uber Internal Tool, 2016)**
ทีม ops พบว่า nginx access log ของ internal dashboard เก็บ request headers ทั้งหมดไว้ รวมถึง `Authorization: Basic dXNlcjpwYXNz` ซึ่ง base64-decode แล้วได้ username:password ทันที
log ถูก ship ไปยัง centralized logging system ที่คนหลายทีมเข้าถึงได้ ทำให้ credentials ของ admin account กระจายไปอยู่ใน log index นานหลายเดือน
แก้โดย configure nginx ให้ mask `Authorization` header ก่อน log + rotate credentials ทั้งหมด + audit ว่ามีใคร query log ไปบ้าง

**Incident 2 — Basic Auth over HTTP on Public WiFi (Conference internal API, 2019)**
API ของระบบลงทะเบียนงาน conference ใช้ Basic Auth แต่ serve ผ่าน HTTP (port 80) ไม่ใช่ HTTPS
ผู้เข้าร่วมงานที่ต่อ WiFi เดียวกันสามารถ sniff traffic และเห็น credentials ของ organizer ได้ในรูป plaintext (base64 decode แบบไม่ต้องพยายาม)
ถูกพบโดย security researcher ที่งาน และ report ต่อ organizer ทันที แต่ระบบถูกใช้งานเช่นนั้นมาหลายปีแล้ว

**Incident 3 — Timing Attack บน Password Comparison (Open Source Project, 2021)**
Admin panel ใช้ `if password == stored` (string equality) ในการเช็ค Basic Auth
นักวิจัยพบว่าการเปรียบเทียบ string ใน Go หยุดทันทีที่เจอ character ที่ต่างกัน ทำให้ response time แตกต่างกันตาม prefix ที่ถูกต้อง
ด้วยการส่ง request หลายพันครั้งและวัด latency สามารถ brute force password ได้เร็วกว่าปกติมาก
แก้โดยเปลี่ยนมาใช้ `subtle.ConstantTimeCompare`

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
เรียก `r.BasicAuth()` → เช็ค username/password ด้วย `==` → ถ้าผ่านก็ให้ผ่าน
บางคนยัง log request ทั้งหมดเพื่อ debug รวมถึง headers ด้วย

**พังตอนไหน:**
- Request วิ่งผ่าน HTTP ไม่ใช่ HTTPS → credentials โดน sniff บน network ได้ทันที (base64 ≠ encryption)
- Logging middleware บันทึก `Authorization` header → credentials อยู่ใน log ตลอดไป
- ใช้ `==` เปรียบเทียบ password → เสี่ยง timing attack (attacker วัด response time แยก prefix ที่ถูกได้)
- ไม่ส่ง `WWW-Authenticate` header กลับ → browser ไม่แสดง login dialog, client ไม่รู้ว่าต้องทำอะไร

**Root cause:**
Basic Auth encode credentials ด้วย base64 ซึ่ง decode กลับได้ทันที (ไม่ใช่ encryption ไม่ใช่ hashing)
ความปลอดภัยทั้งหมดของ Basic Auth ขึ้นอยู่กับ transport layer (TLS) และการไม่ให้ credentials รั่วออกใน log หรือ response

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `r.BasicAuth()` — return value สามชั้น `(username, password string, ok bool)` — `ok` false หมายความว่าอะไร? header ไม่มี หรือ format ผิด หรืออะไร?
- hint: `base64.StdEncoding.DecodeString` — ลอง decode `"dXNlcjpwYXNz"` ด้วยตัวเอง ผลลัพธ์คืออะไร? นี่คือ "encryption" ไหม? ทำไม?
- hint: `r.TLS` — field นี้ใน `*http.Request` type อะไร? เมื่อ request มาผ่าน HTTP (ไม่ใช่ HTTPS) field นี้เป็นค่าอะไร?
- hint: `subtle.ConstantTimeCompare` จาก package `crypto/subtle` — signature คืออะไร? ทำไมถึงต้องรับ `[]byte` ไม่ใช่ `string`? และทำไม return type เป็น `int` ไม่ใช่ `bool`?
- hint: `subtle.ConstantTimeEq` — ต่างจาก `ConstantTimeCompare` ยังไง? ใช้กรณีไหน?
- `w.Header().Set("WWW-Authenticate", ...)` — format ของ value ที่ถูกต้องสำหรับ Basic Auth คืออะไร? `realm` คืออะไร? browser ใช้มันทำอะไร?
- ถ้า middleware detect ว่า request เป็น HTTP แล้วจะ redirect ไป HTTPS — `http.Redirect` กับ status code อะไรที่เหมาะสม? 301 vs 307 vs 308 ต่างกันยังไงในบริบทนี้?

## Task

เขียน middleware `BasicAuthMiddleware(validUsers map[string]string, next http.Handler) http.Handler` ที่:

1. รับ map ของ `username → password` ที่อนุญาต
2. ตรวจสอบว่า request มาผ่าน HTTPS (ไม่ใช่ HTTP)
3. ตรวจสอบ Basic Auth credentials จาก `Authorization` header
4. ถ้าผ่านแล้วส่งต่อไปยัง `next` handler
5. ถ้าไม่ผ่านให้ return 401 พร้อม `WWW-Authenticate` header ที่ถูกต้อง

## Requirements

- ปฏิเสธ request ที่มาผ่าน HTTP (ไม่ใช่ HTTPS) ด้วย 400 Bad Request พร้อม error message ที่ชัดเจน
- ใช้ `crypto/subtle.ConstantTimeCompare` ในการเปรียบเทียบ password (ป้องกัน timing attack)
- Return `401 Unauthorized` พร้อม header `WWW-Authenticate: Basic realm="<realm>"` เมื่อ credentials ผิด
- ห้าม log `Authorization` header ไม่ว่ากรณีใด
- ห้าม expose username หรือ password ใน response body หรือ error message ที่ส่งกลับ client
- `validUsers` map ต้อง thread-safe (อ่านพร้อมกันได้จากหลาย goroutine)

## Acceptance Criteria

- [ ] Request ที่มาผ่าน HTTP (r.TLS == nil) ถูกปฏิเสธด้วย 400 — ไม่มีการประมวลผล credentials
- [ ] Request ที่ไม่มี `Authorization` header ได้รับ 401 พร้อม `WWW-Authenticate` header
- [ ] Credentials ที่ถูกต้องส่งต่อไปยัง next handler — `next.ServeHTTP` ถูกเรียกครั้งเดียว
- [ ] Username ถูกต้องแต่ password ผิด → 401 (ไม่บอกว่า username ถูก)
- [ ] Username ไม่มีใน map → 401 (response time ไม่ต่างจากกรณี password ผิด)
- [ ] การเปรียบเทียบ password ใช้ constant-time comparison จริง — ไม่ใช่ `==` หรือ `strings.Compare`
- [ ] มี test ครอบคลุม: HTTPS valid, HTTPS invalid password, HTTPS unknown user, HTTP request, missing header

## Concepts Involved

- `session-management` — cookie flags, stateful vs stateless auth, session lifecycle → `shared/concepts/session-management.md`
- `constant-time-comparison` — timing attacks, ทำไม `==` ถึงอันตรายสำหรับ secrets → `crypto/subtle` package docs
- `http-security-headers` — WWW-Authenticate, Strict-Transport-Security → MDN HTTP headers reference

## Production Reality

- **ใช้จริง:** Basic Auth ใช้สำหรับ internal tools, admin panels, webhook endpoints ที่ควบคุม client ได้
- **ไม่ใช้เมื่อ:** user-facing applications ที่ต้องการ UX ที่ดี หรือ session management — ใช้ OAuth2/OIDC แทน
- **kata สอนว่า:** base64 ไม่ใช่ encryption, TLS คือ layer เดียวที่ปกป้อง Basic Auth จากการถูก sniff, และ timing attack เป็นเรื่องจริงที่ต้อง mitigate ด้วย constant-time comparison เสมอ
