---
tier: authentication
difficulty: 3
concepts: [oauth2, pkce, authorization-code-flow, code-verifier, code-challenge, s256]
---

# Kata: PKCE Flow (Proof Key for Code Exchange)

## Context

Authorization Code flow ส่ง authorization code ผ่าน redirect URL — code นั้น intercept ได้บน device เดียวกัน
mobile app ที่ใช้ custom URL scheme (`myapp://callback`) หรือ deep link สามารถถูก malicious app อีกตัวบน device เดียวกัน register scheme เดียวกันแล้วดัก code ไปได้
PKCE (RFC 7636) แก้ปัญหานี้โดยผูก authorization request กับ token exchange ด้วย cryptographic proof ที่ไม่สามารถ forge ได้แม้จะดัก code ไปสำเร็จ

## Real World Incidents

**Incident 1 — iOS Custom URL Scheme Hijacking (Industry-wide, 2014–2019)**
ก่อนที่ Apple จะบังคับ Universal Links ใน iOS 9 (2015) แอพ iOS ทุกตัวที่ register custom URL scheme เช่น `mybank://` สามารถ intercept redirect ของแอพอื่นที่ใช้ scheme เดียวกันได้
malicious app บน App Store ที่ผ่านการ review โดยใช้ scheme ทั่วไปสามารถดัก OAuth callback จาก banking app หรือ SSO app แล้วนำ authorization code ไปแลก token ในนาม victim ได้
นักวิจัยจาก Indiana University สาธิต attack นี้สำเร็จใน paper "Unauthorized Cross-App Resource Access on MAC OS X and iOS" (2015)
IETF ออก RFC 7636 (PKCE) เป็น official mitigation ในปีเดียวกัน และ OAuth 2.1 บังคับ PKCE สำหรับ public client ทุกประเภท

**Incident 2 — OAuth Code Injection Attack (Research, 2020)**
Fett et al. ค้นพบ attack class ใหม่เรียกว่า "Authorization Code Injection" ที่ bypass state parameter ได้โดยฉีด authorization code ที่ถูก intercept เข้าไปใน victim's session โดยตรง
attacker ที่ได้ authorization code ของตัวเอง (legitimate) สามารถนำ code นั้นไปใส่ใน victim's callback URL ทำให้ victim แลก token ของ attacker แทน
state parameter ป้องกัน CSRF แต่ไม่ป้องกัน code injection — PKCE แก้ปัญหานี้เพราะ code_verifier ผูกกับ session ของ client
การค้นพบนี้เร่งให้ OAuth 2.1 draft บังคับ PKCE เป็น mandatory สำหรับ Authorization Code flow

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// ❌ Authorization Code flow ปกติ ไม่มี PKCE
func Login(w http.ResponseWriter, r *http.Request) {
    url := oauthConfig.AuthCodeURL(state)
    http.Redirect(w, r, url, http.StatusTemporaryRedirect)
}

func Callback(w http.ResponseWriter, r *http.Request) {
    code := r.URL.Query().Get("code")
    // แลก code เอา token เลย — ใครดัก code ไปก็แลกได้เลย
    token, err := oauthConfig.Exchange(ctx, code)
}

// ❌ ใช้ PKCE แต่เลือก "plain" method
challenge := base64.RawURLEncoding.EncodeToString([]byte(verifier))  // plain = ส่ง verifier เป็น challenge เลย
// plain method แปลว่า ใครดัก code_challenge ไปก็รู้ verifier แล้ว ไม่ได้ป้องกันอะไร

// ❌ code_verifier สั้นเกินไป
verifier := fmt.Sprintf("%d", time.Now().Unix())  // predictable + สั้นมาก
```

**พังตอนไหน:**
- ไม่มี PKCE → authorization code ที่ถูก intercept นำไปแลก token ได้ทันที
- ใช้ `plain` method → code_challenge = code_verifier ทำให้ attacker ที่ดัก challenge ไปแลก token ได้เลย
- verifier สั้น/predictable → brute force verifier ได้ก่อน token expire
- verifier ไม่ได้มาจาก `crypto/rand` → entropy ต่ำ, pattern เดาได้

**Root cause:**
Authorization Code ถูกออกแบบสำหรับ confidential client (web app ที่มี server-side secret) — server เก็บ client_secret ไว้ใช้แลก token ทำให้ code ที่ถูก intercept ไม่มีประโยชน์
public client (mobile app, SPA) ไม่มี client_secret ที่ปลอดภัย — ใครก็ใช้ code แลก token ได้
PKCE แก้โดยใช้ one-time cryptographic proof แทน client_secret

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `crypto/rand.Read(b []byte)` — code_verifier ต้องมี entropy เท่าไหร่? RFC 7636 กำหนด minimum ไว้ที่กี่ bytes? ทำไม 32 bytes ถึงพอ?
- hint: `crypto/sha256.Sum256(data []byte)` — S256 method คำนวณ code_challenge จาก code_verifier ยังไง? ทำไม SHA256 ถึงเหมาะกับงานนี้?
- hint: `base64.RawURLEncoding.EncodeToString(src []byte)` — ทำไมต้องใช้ `RawURLEncoding` (ไม่มี padding `=`) แทน `URLEncoding`? OAuth spec บอกอะไร?
- hint: `oauth2.S256ChallengeOption(verifier string)` — package `golang.org/x/oauth2` มี built-in PKCE support ไหม? ต้องส่ง option อะไรใน `AuthCodeURL` และ `Exchange`?
- hint: `oauth2.VerifierOption(verifier string)` — verifier ส่งไปกับ token exchange request ยังไง? ใน header หรือ body? parameter ชื่ออะไร?
- RFC 7636 กำหนด code_verifier length ระหว่าง 43–128 characters — ถ้า generate 32 random bytes แล้ว encode เป็น base64url ได้กี่ตัวอักษร?
- ทำไม `plain` method ถึงไม่ secure? อธิบาย attack scenario ที่ attacker ที่ดัก challenge ไปสามารถทำอะไรได้บ้าง
- verifier ควรใช้แค่ครั้งเดียว — จะ enforce one-time use ยังไงใน server side?

## Task

เขียนฟังก์ชัน generate PKCE values และ full PKCE flow:

```go
// สร้าง code_verifier และ code_challenge คู่กัน
func GeneratePKCE() (verifier, challenge string, err error)

// เริ่ม OAuth flow พร้อม PKCE — เก็บ verifier ใน session
func InitiateOAuthFlowWithPKCE(w http.ResponseWriter, r *http.Request, oauthConfig *oauth2.Config) error

// รับ callback — ดึง verifier จาก session แล้วส่งพร้อม token exchange
func HandleOAuthCallbackWithPKCE(w http.ResponseWriter, r *http.Request, oauthConfig *oauth2.Config) (*oauth2.Token, error)
```

`GeneratePKCE` สร้าง cryptographically random code_verifier แล้วคำนวณ code_challenge ด้วย S256 method
`InitiateOAuthFlowWithPKCE` เก็บ verifier ใน session แล้ว redirect พร้อม challenge และ state
`HandleOAuthCallbackWithPKCE` verify state, ดึง verifier จาก session, แลก token พร้อม verifier

## Requirements

- code_verifier ต้องมีความยาวระหว่าง 43–128 ตัวอักษร (RFC 7636 requirement)
- code_verifier ต้องสร้างจาก `crypto/rand` — ห้ามใช้ `math/rand` หรือ `time.Now()`
- code_challenge ต้องคำนวณด้วย S256: `BASE64URL(SHA256(ASCII(code_verifier)))` — ห้าม support `plain` method
- Encode ด้วย `base64.RawURLEncoding` (ไม่มี `=` padding)
- Verifier ต้องใช้ได้แค่ครั้งเดียว — ลบออกจาก session ทันทีหลัง token exchange สำเร็จหรือล้มเหลว
- รวม state parameter ด้วยเสมอ (PKCE ไม่ได้ replace state)
- ถ้า verifier ไม่พบใน session หรือหมดอายุ → return error ที่ชัดเจน

## Acceptance Criteria

- [ ] `GeneratePKCE` คืน verifier ที่มีความยาว 43–128 ตัวอักษร
- [ ] เรียก `GeneratePKCE` สองครั้ง → verifier และ challenge ต่างกันทุกครั้ง
- [ ] `GeneratePKCE` คำนวณ challenge ถูกต้อง: `base64url(sha256(verifier))` verify ด้วยมือได้
- [ ] `InitiateOAuthFlowWithPKCE` redirect URL มี `code_challenge` และ `code_challenge_method=S256` ใน query string
- [ ] `HandleOAuthCallbackWithPKCE` พร้อม verifier ที่ valid → แลก token สำเร็จ
- [ ] `HandleOAuthCallbackWithPKCE` โดยไม่มี verifier ใน session → return error
- [ ] Verifier ถูกลบจาก session หลัง callback — เรียกซ้ำด้วย code เดิม → reject

## Concepts Involved

- `oauth2` — Authorization Code flow, public vs confidential client, why PKCE needed → `shared/concepts/oauth2.md`
- `pkce` — code_verifier → code_challenge transform, S256 vs plain, one-time use → `shared/concepts/oauth2.md`

## Production Reality

- **ใช้จริง:** PKCE เป็น mandatory ใน OAuth 2.1 (draft) สำหรับ Authorization Code flow ทุกประเภท — ไม่ใช่แค่ mobile app
- **golang.org/x/oauth2** รองรับ PKCE ผ่าน `oauth2.S256ChallengeOption` และ `oauth2.VerifierOption` ตั้งแต่ Go 1.17
- **SPA** (Single Page Application) ควรใช้ PKCE แทน Implicit flow ที่ deprecated แล้ว
- **kata สอนว่า:** cryptographic binding ระหว่าง request สองขั้นตอนป้องกัน code interception ได้แม้ในสภาพแวดล้อมที่ไม่ trusted
