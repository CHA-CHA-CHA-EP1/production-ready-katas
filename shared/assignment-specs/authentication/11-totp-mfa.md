---
tier: authentication
difficulty: 3
concepts: [totp, mfa, backup-codes, rate-limiting, cryptographic-hash, mfa]
---

# Kata: TOTP Multi-Factor Authentication

## Context

Password เป็น single point of failure — phished ครั้งเดียวก็เข้าได้เลย
MFA เพิ่ม factor ที่สองที่ attacker ต้องมีพร้อมกัน ณ เวลาเดียวกัน
TOTP (Time-based One-Time Password) ตาม RFC 6238 เป็น standard ที่ใช้กันแพร่หลายที่สุด — ทำงานกับ Google Authenticator, Authy, 1Password, และ hardware key หลายรุ่น

## Real World Incidents

**Incident 1 — No MFA on Vendor Account (Dropbox, 2024)**
Dropbox Sign (eSignature service) ถูก breach เพราะ credential ของ service account ถูก compromise
service account นั้นไม่ได้เปิด MFA ไว้ ทำให้ attacker เข้าถึง production environment ได้ทันทีหลัง phishing สำเร็จ
ข้อมูลที่รั่วออกไปรวมถึง email, phone number, hashed password, และ authentication token ของผู้ใช้กว่า 700,000 คน
Dropbox ต้องแจ้งผู้ใช้ทุกคนให้ reset credentials และ review MFA settings

**Incident 2 — Citrix Without MFA (Change Healthcare / UnitedHealth, 2024)**
Ransomware group ALPHV/BlackCat เข้าถึง Change Healthcare ผ่าน Citrix remote access portal
portal ไม่ได้บังคับ MFA แม้จะมีขนาด sensitive healthcare data จำนวนมหาศาล
attacker ใช้ credential ที่ขโมยมา login เข้าไปและ lateral move ในระบบได้นานกว่า 9 วัน ก่อนปล่อย ransomware
ผลกระทบประมาณ $22 billion market cap loss, ระบบ pharmacy ทั่วอเมริกาล่มนานสัปดาห์

**Incident 3 — MFA Fatigue Attack (Uber, 2022)**
Social engineer ขโมย password ของ contractor ได้จาก dark web (ซื้อมาจาก credential breach อื่น)
ส่ง MFA push notification ซ้ำๆ จนกระทั่ง contractor กด "Approve" เพื่อให้มันหยุด (หลังจากรอนานหลายชั่วโมง)
หลังจากผ่าน MFA แล้ว attacker เข้าถึง internal VPN, Slack, HackerOne bug reports, และ AWS console
บทเรียน: TOTP (code ที่ต้องพิมพ์เอง) ป้องกัน fatigue attack ได้ดีกว่า push notification เพราะต้องการ active input จากผู้ใช้

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
ไม่มี MFA เลย หรือ implement TOTP แต่ accept code แบบ window กว้างเกินไป (เช่น ±5 นาที) เพื่อ "ความยืดหยุ่น"
หรือ implement แล้วแต่ไม่มี backup codes ทำให้ user lock out ตัวเองถ้าทำ phone หาย

**พังตอนไหน:**
- ไม่มี MFA → password เดียวพัง → account โดน takeover ทันที
- Window กว้างเกินไป → attacker ที่ sniff code ได้ยังมีเวลาหลายนาทีในการ replay
- ไม่มี rate limit บน TOTP → brute force 000000-999999 ได้ใน 1,000,000 requests (~17 นาทีถ้าไม่ throttle)
- Backup codes ใน plaintext ใน DB → ถ้า DB leak ก็ข้าม MFA ได้ทันที
- ไม่ทำให้ backup code single-use → ใช้ซ้ำได้ ไม่ต่างจากไม่มี MFA

**Root cause:**
TOTP security ขึ้นอยู่กับสามอย่าง: secret ที่ไม่รั่ว, time window ที่แคบพอ, และ rate limiting ที่ป้องกัน brute force
ขาดอย่างใดอย่างหนึ่งก็พังทั้งระบบ

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `github.com/pquerna/otp/totp` — `totp.Generate(opts totp.GenerateOpts)` return type คืออะไร? field `Secret()` และ `URL()` ให้อะไร? URL format (`otpauth://`) ใช้ทำอะไร?
- hint: `totp.Validate(passcode, secret string) bool` — ใช้ time window เท่าไร by default? อ่านจาก source code หรือ godoc
- hint: `totp.ValidateCustom(passcode, secret string, t time.Time, opts totp.ValidateOpts)` — `Skew uint` ใน opts หมายความว่าอะไร? `Skew: 1` อนุญาต window กี่ window ทั้งหมด (ก่อน + ปัจจุบัน + หลัง)?
- TOTP algorithm ทำงานยังไง: `HMAC-SHA1(secret, counter)` โดย `counter = floor(unixTime / 30)` — ทำไม ±1 window ถึงจำเป็น? clock drift ระหว่าง server กับ phone อาจเกิน 30 วินาทีได้ไหม?
- hint: `crypto/rand.Read(b []byte)` — ใช้ generate backup code อะไรดี? `encoding/hex` หรือ `encoding/base32` สำหรับ human-readable code?
- Backup codes ควร hash ด้วยอะไร — `bcrypt` เหมือน password หรือ `sha256` ก็พอ? เพราะ backup code random และยาวพอ — entropy ต่างกับ password ยังไง?
- hint: rate limiting — ถ้าจะ limit TOTP attempts ต่อ user ควรเก็บ state ไว้ที่ไหน? in-memory map (พัง ถ้า restart), Redis (ดี แต่ dependency เพิ่ม) — kata นี้ให้ออกแบบ interface ที่ pluggable ได้
- Atomic operation สำหรับ mark backup code as used — ทำไม "check แล้ว update" แยกสองขั้นตอนถึงอันตราย? race condition เกิดได้อย่างไร?

## Task

เขียนสามฟังก์ชัน:

1. `setupMFA(userID)` — generate TOTP secret และ QR code URL สำหรับ setup
2. `verifyMFA(secret, code)` — verify TOTP code พร้อม clock skew tolerance
3. `generateBackupCodes()` — generate backup codes 8 อัน พร้อม hashed versions สำหรับเก็บใน DB

และ interface สำหรับ rate limiter:

```
type MFARateLimiter interface {
    Allow(userID string) bool      // true = allowed, false = rate limited
    Reset(userID string)           // เมื่อ login สำเร็จ
}
```

## Requirements

- TOTP ใช้ 30-second window, อนุญาต ±1 window สำหรับ clock skew (รวม 3 windows)
- Secret ต้อง generate ด้วย cryptographically secure random source
- QR URL ต้องอยู่ใน format `otpauth://totp/<issuer>:<userID>?secret=<secret>&issuer=<issuer>`
- Backup codes: 8 codes, แต่ละ code ยาว 10 characters (alphanumeric, uppercase)
- Return value จาก `GenerateBackupCodes` ต้องเป็น plaintext codes (แสดงให้ user ครั้งเดียว) พร้อม hashed versions แยกต่างหาก (เก็บใน DB)
- Backup code hashing: ใช้ SHA-256 (ไม่ต้องใช้ bcrypt เพราะ backup code มี entropy สูงพอ)
- Rate limiting: max 5 attempts ต่อ userID ต่อ 5 นาที
- Backup code verification ต้องเป็น constant-time comparison

## Acceptance Criteria

- [ ] `SetupMFA` return secret ที่ valid base32 string และ URL ที่ authenticator app parse ได้
- [ ] `VerifyMFA` return true สำหรับ code ที่ถูกต้องในช่วงเวลาปัจจุบัน
- [ ] `VerifyMFA` return true สำหรับ code ของ window ก่อนหน้าหรือถัดไป (clock skew ±30s)
- [ ] `VerifyMFA` return false สำหรับ code ที่หมดอายุนานกว่า 1 window (เช่น 2 minutes ago)
- [ ] `GenerateBackupCodes` return 8 codes ที่แตกต่างกันทั้งหมด ไม่มี duplicate
- [ ] Hashed backup codes ที่ return มาสามารถ verify ได้ด้วย `sha256.Sum256(bytes(code))`
- [ ] `MFARateLimiter` interface ทำงานถูกต้อง — หลัง 5 attempts ใน 5 นาที, `Allow` return false
- [ ] `Allow` return true อีกครั้งหลัง window หมด (หรือหลัง `Reset` ถูกเรียก)
- [ ] มี test: valid code, expired code, wrong code, clock skew boundary, backup code happy path, rate limit boundary

## Concepts Involved

- `mfa` — TOTP algorithm, factors of authentication, MFA fatigue, SMS vs TOTP tradeoffs → `shared/concepts/mfa.md`
- `cryptographic-hash` — เมื่อใช้ SHA-256 แทน bcrypt ได้ (entropy considerations), backup code design → Go `crypto/sha256` docs
- `rate-limiting` — sliding window vs fixed window, distributed rate limiting tradeoffs → OWASP Authentication Cheat Sheet

## Production Reality

- **ใช้จริง:** Google Authenticator, Authy, 1Password ทั้งหมดใช้ TOTP (RFC 6238) — compatible กับ library นี้
- **Hardware key:** FIDO2/WebAuthn (YubiKey) ปลอดภัยกว่า TOTP เพราะ phishing-resistant แต่ adoption ต่ำกว่า
- **SMS OTP:** ง่ายสำหรับ user แต่ susceptible to SIM swap — ใช้เป็น fallback ไม่ใช่ primary MFA
- **kata สอนว่า:** MFA implementation มีส่วนที่ fail ได้หลายจุด (window, rate limit, backup codes) — ต้องออกแบบ defense-in-depth ทุกชั้น ไม่ใช่แค่ "เพิ่ม 6-digit code"
