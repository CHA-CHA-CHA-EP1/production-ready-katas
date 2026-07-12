---
tier: authentication
difficulty: 3
concepts: [webauthn, passkeys, fido2, public-key-cryptography, phishing-resistance, sign-counter]
---

# Kata: WebAuthn / Passkeys

## Context

Password-based authentication มีจุดอ่อนพื้นฐาน: user ต้องส่ง secret ผ่าน network ทุกครั้ง — phishing site หลอกรับ password ได้ง่าย, credential stuffing ใช้ password จาก breach หนึ่งโจมตีอีก service
WebAuthn ใช้ public key cryptography: device เก็บ private key ไว้ในตัว, server เก็บแค่ public key — ไม่มี secret ส่งผ่าน network เลย และ credential ผูกกับ origin ทำให้ phishing site ใช้ไม่ได้
ปี 2023 Apple, Google, Microsoft rollout passkeys ใน consumer products — WebAuthn กลายเป็น mainstream

## Real World Incidents

**Incident 1 — Cloudflare Survives Twilio-style Phishing Attack (Cloudflare, August 2022)**
ในคืนเดียวกับที่ Twilio ถูก phishing attack สำเร็จ Cloudflare พนักงานก็ได้รับ SMS เดียวกัน — ข้อความหลอกว่าเป็น IT team ให้ login ผ่าน link ที่ดูเหมือน Cloudflare login page
พนักงานบางคนคลิก link และพิมพ์ username กับ password — แต่ attacker ไม่สามารถ bypass 2FA ได้เพราะพนักงาน Cloudflare ใช้ hardware security key (FIDO2) ที่ผูกกับ `cloudflare.com` origin
เนื่องจาก phishing site มี origin ต่างกัน (`cloudflare-sso.com`) key จึงปฏิเสธทำ authentication — แม้แต่พนักงานที่กรอก password ไปแล้วก็ยังปลอดภัย
Cloudflare เขียน post-mortem โดยระบุว่า "hardware security keys were the difference between a near miss and a breach"

**Incident 2 — Credential Stuffing ระดับ 100 ล้าน Accounts (Multiple Companies, 2019–2023)**
ข้อมูล credential จาก breach ใหญ่ๆ อย่าง Collection #1 (773 ล้าน records) ถูกนำไปใช้ทำ credential stuffing โจมตี streaming service, e-commerce, และ banking
บริษัทที่ใช้ password + SMS OTP โดน account takeover เป็นจำนวนมากเพราะ attacker มี password จริงและ SIM swap หรือ SS7 attack เพื่อดัก OTP ได้
Disney+, Spotify, Zoom โดน credential stuffing คลื่นใหญ่ในช่วง 2020 — accounts ถูกขายใน dark web ชั่วโมงหลัง service launch
WebAuthn/passkeys ทำให้ credential stuffing เป็นไปไม่ได้ในทางทฤษฎีเพราะไม่มี reusable secret

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// ❌ password ธรรมดา
func Login(username, password string) (bool, error) {
    var storedHash string
    db.QueryRow("SELECT password_hash FROM users WHERE username = ?", username).Scan(&storedHash)
    return bcrypt.CompareHashAndPassword([]byte(storedHash), []byte(password)) == nil, nil
}

// ❌ password + TOTP (ดีขึ้น แต่ยัง phishable)
// TOTP code สามารถ relay ได้ real-time จาก phishing site → real site
// attacker หลอก user กรอก code แล้ว relay ภายใน 30 วินาที

// ❌ password + SMS OTP
// SIM swap attack, SS7 vulnerability, malware บน phone ดัก OTP
```

**พังตอนไหน:**
- password โดน phishing — user กรอกบน fake site ที่ URL ต่างกันแค่ typo
- credential stuffing — password เดียวกันใช้หลาย site, breach หนึ่งทำให้ทุก account โดน
- TOTP โดน real-time phishing relay — attacker relay code ภายใน 30 วินาที
- SMS OTP โดน SIM swap — ย้ายเบอร์ไปซิมของ attacker ผ่าน social engineering

**Root cause:**
ทุก factor ที่ "user รู้" หรือ "user ได้รับ" สามารถ intercept หรือ phish ได้
WebAuthn เปลี่ยน model เป็น "user มี" (private key บน device) — private key ไม่เคยออกจาก device และ credential ผูกกับ origin ทำให้ phishing site ต่าง origin ใช้ไม่ได้

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `webauthn.New(config *webauthn.Config)` — `RPDisplayName` และ `RPID` คืออะไร? RPID ผูกกับอะไร? ถ้าใช้ RPID ผิด domain จะเกิดอะไร?
- hint: `webauthn.BeginRegistration(user WebAuthnUser)` — ฟังก์ชันนี้คืน `*protocol.CredentialCreation` — นำ struct นี้ไปทำอะไรต่อ? ต้องส่งให้ browser ในรูปแบบไหน?
- hint: `webauthn.FinishRegistration(user WebAuthnUser, session SessionData, response *protocol.ParsedCredentialCreationData)` — `SessionData` คืออะไร? ต้องเก็บไว้ที่ไหนระหว่าง begin กับ finish?
- hint: `webauthn.BeginLogin(user WebAuthnUser)` vs `webauthn.BeginDiscoverableLogin()` — ต่างกันยังไง? discoverable credential คืออะไร?
- hint: sign counter — `Credential.Authenticator.SignCount` คือเลขอะไร? ทำไมต้อง verify ว่า sign count เพิ่มขึ้นทุก login? ถ้าลดลงหมายความว่าอะไร?
- hint: `WebAuthnUser` interface — library ต้องการ method อะไรบ้าง? `WebAuthnID()`, `WebAuthnName()`, `WebAuthnDisplayName()`, `WebAuthnCredentials()` — data model ควรเป็นยังไง?
- user หนึ่งคนมีได้หลาย credential (หลาย device) — DB schema ควร design ยังไง? one-to-many ระหว่าง user กับ credential?
- challenge ใน WebAuthn ต้องมี properties อะไรบ้าง? library generate ให้ไหม หรือต้อง generate เอง?

## Task

Implement registration flow และ login flow สำหรับ WebAuthn:

```go
// Registration
func BeginRegistration(userID string) (*protocol.CredentialCreation, error)
func FinishRegistration(userID string, response *protocol.ParsedCredentialCreationData) error

// Login (Authentication)
func BeginLogin(userID string) (*protocol.CredentialAssertion, error)
func FinishLogin(userID string, response *protocol.ParsedCredentialRequestData) (*webauthn.Credential, error)
```

`BeginRegistration` สร้าง WebAuthn challenge สำหรับ registration, เก็บ session data, คืน `CredentialCreation` ที่ส่งให้ browser
`FinishRegistration` verify response จาก browser, เก็บ public key credential ใน DB
`BeginLogin` สร้าง challenge สำหรับ authentication, คืน `CredentialAssertion` พร้อม list ของ credential IDs ที่ user มี
`FinishLogin` verify signature, อัปเดต sign counter ใน DB, คืน credential ที่ใช้

## Requirements

- ใช้ library `github.com/go-webauthn/webauthn` — ห้าม implement WebAuthn protocol เอง
- เก็บ credential ใน DB ด้วยอย่างน้อย: `credential_id`, `public_key`, `sign_count`, `user_id`, `created_at`, `last_used_at`
- Verify ว่า sign count เพิ่มขึ้นในทุก login (ป้องกัน credential cloning) — ถ้า sign count ใหม่ <= sign count เก่า ต้อง return error และ log warning
- Support multiple credentials ต่อ user — user คนเดียวมีได้หลาย device
- เก็บ session data (challenge) ระหว่าง begin และ finish ใน server-side session — ห้ามเก็บ challenge ใน client
- `RPID` ต้องตั้งค่าจาก config (environment variable) — ห้าม hardcode
- Session data ต้องมี expiry (แนะนำ 5 นาที) — challenge หมดอายุแล้ว reject

## Acceptance Criteria

- [ ] `BeginRegistration` คืน `CredentialCreation` ที่มี challenge ที่ไม่ซ้ำกันทุก call
- [ ] `FinishRegistration` หลัง valid browser response → credential ถูกเก็บใน DB พร้อม public key และ sign count เริ่มต้น
- [ ] `BeginLogin` คืน `CredentialAssertion` ที่มี `allowCredentials` list ตรงกับ credentials ที่ user ลงทะเบียนไว้
- [ ] `FinishLogin` หลัง valid browser response → คืน credential และอัปเดต sign count ใน DB
- [ ] `FinishLogin` ถ้า sign count ใน response <= sign count ใน DB → return error
- [ ] User คนเดียวลงทะเบียน 2 credentials → `BeginLogin` ส่ง credential IDs ทั้งสองใน `allowCredentials`
- [ ] Session ที่ใช้แล้ว (begin ไปแล้ว finish แล้ว) ไม่สามารถ reuse ได้ — ทำ finish สองครั้งด้วย session เดิม → reject ครั้งที่สอง

## Concepts Involved

- `webauthn` — registration flow, authentication flow, challenge-response, relying party → `shared/concepts/webauthn.md`
- `public-key-cryptography` — private key บน device, public key บน server, signature verification → `shared/concepts/webauthn.md`
- `sign-counter` — credential cloning detection, hardware vs platform authenticator behavior → `shared/concepts/webauthn.md`
- `phishing-resistance` — origin binding (rpId), ทำไม fake site ใช้ credential ไม่ได้ → `shared/concepts/webauthn.md`

## Production Reality

- **ใช้จริง:** Google, GitHub, Microsoft, Apple — ทุกบริษัทใหญ่ deploy passkeys แล้วใน 2023–2024; GitHub รายงาน passkey adoption ลด phishing จาก employee accounts ได้ 100%
- **Platform authenticators** (Touch ID, Face ID, Windows Hello) ใช้ง่ายกว่า hardware key แต่ passkey sync ผ่าน iCloud/Google Password Manager — sign counter อาจไม่เพิ่มทุกครั้งใน synced passkeys
- **Fallback** ยังจำเป็น — ไม่ใช่ทุก device support WebAuthn, legacy browser, และ account recovery flow ต้องมี
- **kata สอนว่า:** security ที่แข็งแกร่งที่สุดไม่ต้องพึ่ง user ทำอะไรถูกต้อง — passkeys ปลอดภัยโดย design แม้ user ถูก social engineer ให้ "login" บน phishing site
