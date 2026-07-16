---
tier: authentication
difficulty: 2
concepts: [oauth2, csrf, state-parameter, constant-time-compare, session-management]
---

# Kata: OAuth2 State Parameter

## Context

OAuth2 Authorization Code flow มี callback URL ที่ browser จะถูก redirect กลับมาพร้อม authorization code
ถ้าไม่มีการ verify ว่า callback นั้นมาจาก flow ที่เราเริ่มเอง — attacker สามารถหลอกให้ browser ของ victim ทำ OAuth flow ของ attacker จนสำเร็จแล้วผูก attacker's account กับ victim's session ได้
State parameter คือ random nonce ที่ป้องกัน CSRF บน callback endpoint โดยเฉพาะ

## Real World Incidents

**Incident 1 — Facebook OAuth CSRF Bug Bounty (Facebook, 2014)**
นักวิจัยด้านความปลอดภัยค้นพบว่า Facebook OAuth implementation ไม่ validate state parameter ใน flow บางประเภท
attacker สร้าง authorization URL พิเศษแล้วหลอก victim ให้คลิก — เมื่อ victim คลิก Facebook link ใดๆ หลังจากนั้น browser จะ complete flow ของ attacker โดยอัตโนมัติ
ผลคือ attacker สามารถ link Facebook account ของตัวเองเข้ากับ victim's session ในแอปพลิเคชันที่ใช้ "Login with Facebook"
Facebook จ่าย bug bounty $500 และแก้ไขโดยบังคับ validate state ในทุก OAuth endpoint

**Incident 2 — "Login with X" CSRF Vulnerabilities (Industry-wide, 2012–2019)**
การศึกษาในปี 2012 โดย Wang et al. (Microsoft Research) พบว่า website ที่ implement Social Login มากกว่า 61% ไม่ validate state parameter
attacker สามารถทำ account hijacking ผ่าน CSRF — เช่น ฝัง OAuth callback URL ใน `<img src>` หรือ hidden iframe ใน malicious page
เว็บไซต์ที่โดนรวมถึงบริการช้อปปิ้งออนไลน์ที่ sensitive มาก เพราะ attacker ผูก payment method ของ victim เข้ากับ account ของตัวเอง
IETF ออก RFC 6749 Section 10.12 บังคับให้ state เป็น REQUIRED สำหรับ CSRF protection

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// ❌ redirect ไป provider โดยไม่มี state
func Login(w http.ResponseWriter, r *http.Request) {
    url := oauthConfig.AuthCodeURL("")  // state = ""
    http.Redirect(w, r, url, http.StatusTemporaryRedirect)
}

// ❌ callback รับ code มาแล้วแลก token เลย ไม่ verify อะไร
func Callback(w http.ResponseWriter, r *http.Request) {
    code := r.URL.Query().Get("code")
    token, _ := oauthConfig.Exchange(r.Context(), code)
    // ใช้ token ต่อเลย...
}

// ❌ มี state แต่ compare แบบผิด
func Callback(w http.ResponseWriter, r *http.Request) {
    state := r.URL.Query().Get("state")
    if state == sessionState {  // ❌ == comparison
        // proceed...
    }
}
```

**พังตอนไหน:**
- ไม่มี state → CSRF: attacker ฝัง callback URL ใน malicious page, victim's browser complete flow โดยไม่รู้ตัว
- state เป็น empty string → ทุก request ผ่าน แปลว่าป้องกันอะไรไม่ได้เลย
- state เป็น static value (เช่น user ID) → predictable, attacker สร้าง URL ได้เอง
- ใช้ `==` compare state → timing attack รู้ได้ว่าตัวอักษรตรงกันมากแค่ไหน
- ไม่มี expiry บน state → state เก่าสามารถ replay ได้หลายชั่วโมงต่อมา

**Root cause:**
OAuth callback endpoint เปิดรับ request จากทุกคนที่มี valid code — โดยไม่มี state การพิสูจน์ว่า "flow นี้เริ่มจาก browser ของ user คนนี้จริงๆ" ไม่มีเลย
State parameter สร้าง binding ระหว่าง authorization request กับ callback request ผ่าน session ที่ attacker เข้าถึงไม่ได้

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `crypto/rand.Read(b []byte)` — ทำไมต้องใช้ `crypto/rand` แทน `math/rand` สำหรับ state generation? entropy ต่างกันยังไง?
- hint: `base64.URLEncoding.EncodeToString(src []byte)` — ทำไมต้องใช้ URL-safe base64 (URLEncoding) แทน StdEncoding? ตัวอักษรไหนที่ทำให้มีปัญหาใน URL?
- hint: `oauthConfig.AuthCodeURL(state string, opts ...oauth2.AuthCodeOption)` — state parameter ถูกส่งไปใน request ยังไง? ใน query string หรือ body?
- hint: `subtle.ConstantTimeCompare(x, y []byte)` — ทำไม string comparison แบบ `==` ถึงรั่ว timing information? constant-time แก้ยังไง?
- hint: session management — ควรเก็บ state ไว้ใน session ที่ไหน? cookie, server-side session, หรืออะไร? ถ้าเก็บใน cookie ควร sign ไหม?
- state ต้องมีกี่ bytes ถึงจะ secure พอ? 8 bytes กับ 32 bytes ต่างกันยังไงในเชิง security?
- ถ้า provider ส่ง state กลับมาแต่ session หาไม่เจอ (expired หรือ replay) ควร response อะไร? 400 หรือ 302 redirect ไป error page?

## Task

implement สองฟังก์ชัน:

```
initiateOAuthFlow(w, r, oauthConfig) → state , err error

handleOAuthCallback(w, r, oauthConfig) → *oauth2.Token, error
```

`InitiateOAuthFlow` สร้าง cryptographically random state, เก็บไว้ใน session พร้อม expiry, แล้ว redirect user ไป OAuth provider
`HandleOAuthCallback` รับ callback จาก provider, ดึง state จาก session มา verify กับ state ใน query string, แลก authorization code เอา token — reject ทุกกรณีที่ state ไม่ตรงหรือ session ไม่พบ

## Requirements

- State ต้องสร้างจาก `crypto/rand` ขนาดอย่างน้อย 32 bytes แล้ว encode เป็น base64url
- เก็บ state ใน session ก่อน redirect พร้อม expiry 10 นาที
- Callback ต้อง reject ถ้าไม่มี `state` parameter ใน query string
- Callback ต้องใช้ `subtle.ConstantTimeCompare` เปรียบเทียบ state — ห้ามใช้ `==` หรือ `strings.Compare`
- Callback ต้อง reject state ที่หมดอายุหรือไม่พบใน session — คืน error ที่ชัดเจน
- ลบ state ออกจาก session ทันทีหลัง verify สำเร็จ (prevent replay)
- Error message ต้องไม่บอก attacker ว่า state มีอยู่แต่ผิด vs ไม่มีเลย (ให้ response เดียวกัน)

## Acceptance Criteria

- [ ] `InitiateOAuthFlow` คืน state string ที่มีความยาวอย่างน้อย 43 ตัวอักษร (32 bytes base64url)
- [ ] เรียก `InitiateOAuthFlow` สองครั้ง คืน state ที่ต่างกันทุกครั้ง
- [ ] `HandleOAuthCallback` พร้อม state ที่ถูกต้องและ session ที่ valid → แลก token สำเร็จ
- [ ] `HandleOAuthCallback` พร้อม state ที่ผิด → return error, ไม่แลก token
- [ ] `HandleOAuthCallback` พร้อม state ที่หมดอายุ (simulate โดย set expiry เป็นอดีต) → return error
- [ ] `HandleOAuthCallback` ถ้าไม่มี `state` parameter เลยใน query string → return error
- [ ] State ถูกลบจาก session หลัง callback สำเร็จ — เรียก callback ซ้ำด้วย state เดิม → reject

## Concepts Involved

- `oauth2` — Authorization Code flow ทำงานยังไง, state parameter role ใน flow → `shared/concepts/oauth2.md`
- `csrf` — Cross-Site Request Forgery คืออะไร, ทำไม OAuth callback ถึงเสี่ยง → `shared/concepts/oauth2.md`
- `constant-time-compare` — timing attack บน string comparison, subtle.ConstantTimeCompare → `shared/concepts/password-hashing.md`

## Production Reality

- **ใช้จริง:** ทุก production OAuth implementation บังคับใช้ state — library อย่าง `golang.org/x/oauth2` support ผ่าน `AuthCodeURL(state)`
- **PKCE** เสริม security ได้อีกชั้นบน state (ดู kata ถัดไป) แต่ state ยังจำเป็นอยู่แม้มี PKCE
- **kata สอนว่า:** OAuth flow มี attack surface หลายจุด — state เป็น defense ต่อ CSRF บน callback, แต่ไม่ใช่ silver bullet สำหรับทุกปัญหา
