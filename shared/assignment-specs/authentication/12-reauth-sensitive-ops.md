---
tier: authentication
difficulty: 2
concepts: [sudo-mode, reauth, session-management, csrf, privilege-escalation]
---

# Kata: Re-authentication for Sensitive Operations

## Context

"ผู้ใช้ login อยู่แล้ว ทำไมต้องยืนยันตัวตนอีก" — เพราะ session ที่ถูกต้องไม่ได้หมายความว่า "ผู้ใช้ตั้งใจทำสิ่งนี้ตอนนี้"
Session อาจถูก hijack, CSRF อาจหลุดรอด SameSite, หรือผู้ใช้ทิ้งคอมไว้แล้วมีคนอื่นมาทำแทน
GitHub, Google, AWS ล้วนใช้ "sudo mode" หรือ "re-authentication" ก่อนอนุญาต sensitive operations เช่น เปลี่ยน email, ปิด MFA, หรือลบบัญชี

## Real World Incidents

**Incident 1 — XSS เปลี่ยน Email โดยไม่ต้อง Re-auth (Web App Bug Bounty, 2020)**
นักวิจัยพบ stored XSS ใน profile description field ของ SaaS platform
XSS payload เรียก `/api/account/email` endpoint ด้วย AJAX ในขณะที่ victim เปิดหน้า profile
เพราะ endpoint ตรวจแค่ว่า user authenticated อยู่หรือเปล่า (session valid) ไม่ได้ require re-auth
attacker เปลี่ยน email ของ victim ไปเป็น email ของตัวเอง แล้ว trigger "forgot password" เพื่อ takeover account ทั้งหมด
แก้โดยเพิ่ม password confirmation บน email change endpoint + ทำ XSS fix

**Incident 2 — CSRF เปลี่ยน Payment Method (E-commerce Platform, 2019)**
endpoint `POST /account/payment-method` ตรวจ SameSite แต่ไม่ได้ set อย่างถูกต้อง (SameSite=None แบบ legacy)
attacker สร้างหน้าเว็บที่ auto-submit form ไปยัง endpoint นี้เมื่อ victim เปิดลิงก์
เพราะ victim มี valid session cookie อยู่ และ endpoint ไม่ require re-auth ก็ผ่านได้เลย
payment method ของ victim ถูกเปลี่ยนไปยัง attacker's account โดยไม่รู้ตัว

**Incident 3 — Session Abandoned on Shared Computer (Enterprise HR System, 2021)**
พนักงานใช้ HR portal บน shared computer แล้วเดินออกไปโดยไม่ logout
เพื่อนร่วมงานที่มาใช้คอมเดียวกันพบ session ยังอยู่ เข้าไปเปลี่ยน bank account สำหรับรับเงินเดือน
ระบบไม่มี re-auth สำหรับการเปลี่ยน payment details และไม่มี absolute session timeout
แก้โดยเพิ่ม sudo mode (require password ก่อน sensitive ops) + session timeout 30 นาทีแบบ absolute

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
ทุก endpoint ตรวจแค่ `isAuthenticated(r)` — ถ้า session valid ก็ผ่านทุกอย่าง รวมถึง เปลี่ยน password, เปลี่ยน email, ปิด MFA, โอนเงิน

**พังตอนไหน:**
- XSS ที่ inject JavaScript ได้ → เรียก sensitive endpoint แทนผู้ใช้ทันที
- CSRF ถ้า SameSite ไม่ strict พอ → หน้าเว็บ attacker submit form ไปยัง endpoint ของ victim
- Session hijacking → attacker ที่ steal cookie ทำ sensitive op ได้ทุกอย่าง
- Shoulder surfing / abandoned session → คนอื่นนั่งต่อ session ได้
- Insider threat → engineer ที่มีสิทธิ์ access DB ทำการเปลี่ยนแปลงโดยไม่มี audit trail

**Root cause:**
Session เป็นหลักฐานว่า "ผู้ใช้เคย authenticate เมื่อไม่นานมานี้" ไม่ใช่หลักฐานว่า "ผู้ใช้ตั้งใจทำสิ่งนี้ตอนนี้"
Sudo mode แก้ปัญหานี้ด้วยการ require fresh authentication credential ก่อน sensitive operation และมี timestamp ที่หมดอายุเร็ว

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `time.Duration` — `maxAge time.Duration` parameter ควรเป็น `10 * time.Minute` — ทำไมใช้ `time.Duration` แทน `int` (seconds)? มี type safety อะไร?
- hint: `time.Now().Add(-maxAge)` vs `time.Since(verifiedAt)` — ทั้งสองคำนวณอะไร? แบบไหนอ่านง่ายกว่า? มีผลต่าง performance ไหม?
- sudo mode token ควรเก็บไว้ที่ไหน — ใน session (server-side state) หรือเป็น signed cookie ที่ client? tradeoff แต่ละแบบคืออะไรสำหรับ stateless service vs stateful service?
- hint: ถ้าเก็บ sudo mode ใน context ผ่าน `context.WithValue` — ทำไม key ต้องเป็น unexported type ไม่ใช่ `string`? collision คืออะไร?
- การ design re-auth flow: user กด "Change Email" → redirect ไป `/auth/sudo?return=/settings/email` → กรอก password → redirect กลับ → ทำงานต่อ — `return` parameter นี้มี security risk อะไร? (open redirect) จะ validate ยังไง?
- hint: `context.Context` — middleware ที่ inject sudo state เข้า context ควรทำยังไง? handler ที่ consume ดึงออกมายังไง?
- Audit log — sensitive operations ควร log อะไรบ้าง ที่ไม่ log sensitive data เอง? (log "email changed" ไม่ใช่ log "email changed to new@example.com")

## Task

เขียน middleware และฟังก์ชัน:

1. `RequireSudoMode(maxAge time.Duration, next http.Handler) http.Handler` — middleware ที่ตรวจว่ามี sudo mode ที่ยังไม่หมดอายุ ถ้าไม่มีให้ redirect ไปหน้า re-auth
2. `GrantSudoMode(w http.ResponseWriter, r *http.Request, verifiedAt time.Time)` — บันทึก sudo mode timestamp หลัง re-auth สำเร็จ

และ helper:

```go
func IsSudoMode(r *http.Request, maxAge time.Duration) bool
```

## Requirements

- Sudo mode expires หลังจาก `maxAge` นับจาก `verifiedAt` timestamp (ไม่ใช่นับจาก request ปัจจุบัน)
- Operations ที่ต้อง sudo mode: เปลี่ยน password, เปลี่ยน email, disable 2FA, เปลี่ยน payment method, ลบ account
- `GrantSudoMode` ต้อง record timestamp ที่ tamper-evident (signed หรือ server-side storage)
- Middleware ที่ detect "no sudo mode" ต้อง return 403 หรือ redirect ไปหน้า re-auth (configurable)
- Re-auth endpoint ต้อง validate `return` URL ป้องกัน open redirect (แค่ path บน same origin เท่านั้น)
- Sudo mode ต้องไม่ขยาย lifetime เมื่อ request มาถึง (ไม่ rolling expiry — ใช้ absolute expiry)
- ต้อง invalidate sudo mode เมื่อ logout

## Acceptance Criteria

- [ ] Request โดยไม่มี sudo mode ไปยัง protected endpoint → 403 หรือ redirect ไป re-auth
- [ ] หลัง `GrantSudoMode` เรียกด้วย `verifiedAt = now` → `IsSudoMode` return true ด้วย maxAge 10 นาที
- [ ] หลัง `GrantSudoMode` เรียกด้วย `verifiedAt = 11 นาทีที่แล้ว` → `IsSudoMode` return false ด้วย maxAge 10 นาที
- [ ] Sudo mode ไม่ extend เมื่อมี request เพิ่มขึ้น (absolute expiry ไม่ใช่ sliding)
- [ ] `return` URL ที่ชี้ไปยัง external domain ถูกปฏิเสธ — redirect ไปหน้า default แทน
- [ ] `return` URL ที่เป็น relative path บน same origin ผ่าน
- [ ] Sudo mode ถูก clear เมื่อ logout
- [ ] มี test: no sudo mode, valid sudo mode, expired sudo mode, sudo mode boundary (exactly at maxAge), open redirect validation

## Concepts Involved

- `session-management` — sudo mode เป็น time-limited session ภายใน session หลัก, absolute vs sliding expiry → `shared/concepts/session-management.md`
- `privilege-escalation` — least privilege principle, time-limited elevated access pattern → GitHub's sudo mode documentation
- `open-redirect` — return URL validation, same-origin check → OWASP Unvalidated Redirects and Forwards

## Production Reality

- **ใช้จริง:** GitHub ใช้ sudo mode ที่หมดอายุหลัง 10 นาที, Google ใช้ "Confirm your identity" สำหรับ account recovery settings, AWS ใช้ MFA re-auth สำหรับ sensitive API calls
- **Design pattern:** Sudo mode = short-lived "elevated session" ภายใน session หลัก — คล้าย `sudo` บน Unix ที่ cache credential สั้นๆ
- **kata สอนว่า:** Authentication (คุณคือใคร) ≠ Authorization (คุณทำสิ่งนี้ได้ไหม) ≠ Intent verification (คุณตั้งใจทำสิ่งนี้ตอนนี้ไหม) — sudo mode แก้ปัญหาที่สาม ซึ่ง session ปกติแก้ไม่ได้
