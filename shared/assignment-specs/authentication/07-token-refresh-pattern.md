---
tier: authentication
difficulty: 2
concepts: [token-refresh, refresh-token-rotation, short-lived-token, access-token]
---

# Kata: Token Refresh Pattern

## Context

Access token ที่อายุยาวนานเป็นปัญหาด้าน security — ถ้า token ถูก steal, attacker มีสิทธิ์เท่า user นั้นนานเท่ากับอายุ token
short-lived access token แก้ปัญหานี้ แต่ต้องมี mechanism สำหรับ renew โดยไม่ให้ user login ซ้ำทุก 15 นาที
refresh token pattern แก้ทั้งสองปัญหา: access token สั้น + user experience ที่ seamless

## Real World Incidents

**Incident 1 — Long-lived Session Token Exposure (Slack, 2022)**
Slack พบว่า session token บางตัวถูก expose ในระหว่าง security incident
เพราะ token มีอายุยาวนานมาก (หลายเดือน), attacker ที่ได้ token ยังคงสามารถ access ได้นาน
Slack ต้อง force revoke token ทั้งหมดและให้ user login ใหม่ทั้ง platform
ถ้าใช้ short-lived access token + refresh rotation, blast radius จะจำกัดกว่ามาก

**Incident 2 — "Can't Log Out" Problem (Social Media Platforms, ทั่วไป)**
หลาย mobile app ใช้ long-lived token เป็น shortcut ให้ stay logged in
user ที่ phone หาย report ว่า logout จาก website แต่ app บน phone เก่ายังใช้งานได้
เพราะ server-side logout แค่ clear client session ไม่ได้ invalidate token จริงๆ
refresh rotation แก้ปัญหานี้ — เมื่อ user logout, revoke refresh token → access token หมดอายุเองใน 15 นาที

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// ❌ access token อายุยาว 30 วัน — ง่ายแต่อันตราย
claims := jwt.RegisteredClaims{
    ExpiresAt: jwt.NewNumericDate(time.Now().Add(30 * 24 * time.Hour)),
}

// ❌ refresh token ไม่ rotate — ใช้ซ้ำได้เรื่อยๆ
func RefreshToken(refreshToken string) (string, error) {
    // validate refresh token...
    // issue new access token
    // แต่ refresh token เดิมยังใช้ได้อยู่!
    return newAccessToken, nil
}

// ❌ เก็บ refresh token plaintext ใน DB
db.Exec("INSERT INTO refresh_tokens (token, user_id) VALUES (?, ?)", token, userID)
```

**พังตอนไหน:**
- access token อายุ 30 วัน → stolen token ใช้ได้ 30 วันเต็ม
- refresh token ไม่ rotate → เมื่อ refresh token รั่วออกไป attacker เปลี่ยน access token ได้ไม่จำกัด
- เก็บ refresh token plaintext → DB breach ทำให้ attacker มี long-term access ของ user ทุกคน

**Root cause:**
Long-lived token เหมือน password ที่หมดอายุช้า — ช่วงที่ถูก compromise ยาวกว่าที่ควร
refresh token rotation ทำให้ token แต่ละตัวใช้ได้ครั้งเดียว — replay attack ไม่ work
การ detect ว่า refresh token ถูกใช้ซ้ำ (ที่ควรจะ invalid แล้ว) เป็น signal ว่ามีการ compromise

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `time.Now().Add(15 * time.Minute)` vs `time.Now().Add(30 * 24 * time.Hour)` — อายุของ access token และ refresh token ควรต่างกันยังไงใน production?
- refresh token rotation คืออะไร? เมื่อ client ใช้ refresh token, server ควรทำอะไรกับ token เก่า?
- hint: `crypto/rand.Read` สำหรับ refresh token — ทำไม refresh token ไม่ต้องเป็น JWT? ข้อดีของ opaque token สำหรับ refresh?
- ถ้า client ใช้ refresh token ที่ expire แล้ว (เพราะ rotate) — นั่นหมายความว่าอะไร? ควร response อะไรกลับไป?
- การเก็บ SHA-256 hash ของ refresh token แทน plaintext — ทำไม? refresh token ต่างจาก API key ยังไงในแง่ entropy?

## Task

เขียนสองฟังก์ชัน:

```go
type TokenStore interface {
    SaveRefreshToken(ctx context.Context, userID, hashedToken string, expiry time.Time) error
    FindAndDeleteRefreshToken(ctx context.Context, hashedToken string) (userID string, err error)
}

func IssueTokenPair(userID string, secret string) (accessToken, refreshToken string, err error)
func RefreshAccessToken(ctx context.Context, store TokenStore, refreshToken, secret string) (newAccessToken, newRefreshToken string, err error)
```

`IssueTokenPair` สร้าง access token (JWT, 15 นาที) และ refresh token (opaque, 30 วัน)
`RefreshAccessToken` แลก refresh token เก่า → issue pair ใหม่, invalidate เก่า

## Requirements

- access token เป็น JWT ที่มี `exp` = 15 นาที และ `sub` = userID
- refresh token เป็น random opaque token (ไม่ใช่ JWT) ที่มี entropy อย่างน้อย 32 bytes
- เก็บ SHA-256 hash ของ refresh token ใน store — ไม่เก็บ plaintext
- `RefreshAccessToken` ต้อง atomically delete refresh token เก่าก่อน issue ใหม่ — ห้ามใช้ซ้ำ
- ถ้า refresh token ไม่พบใน store (already used หรือ expired) ต้อง return error ที่ชัดเจน
- refresh token ที่คืนให้ client ต้องเป็น plaintext (เห็นครั้งเดียว), hash เก็บใน store

## Acceptance Criteria

- [ ] `IssueTokenPair` คืน access token ที่ valid JWT และ refresh token ที่ opaque
- [ ] access token มี `exp` ไม่เกิน 15 นาทีจากตอนออก
- [ ] `RefreshAccessToken` คืน token pair ใหม่ทั้งคู่
- [ ] refresh token เก่าไม่สามารถใช้ซ้ำหลัง refresh — คืน error ทันที
- [ ] hash ของ refresh token ที่เก็บใน store ไม่ใช่ plaintext token
- [ ] `RefreshAccessToken` ด้วย token ที่ไม่มีใน store คืน error ที่อ่านเข้าใจได้

## Concepts Involved

- `jwt` — access token ใช้ JWT เพราะ stateless verification, exp claim สำคัญ → `shared/concepts/jwt.md`
- `refresh-token-rotation` — ทำไม rotate, replay attack detection, blast radius reduction → (concept doc ยังไม่มี)

## Production Reality

- **ใช้จริง:** OAuth 2.0 standard ใช้ pattern นี้ — access token + refresh token เป็น de facto standard
- **Refresh token family:** บาง system track "token family" — ถ้า revoked token ถูกใช้ซ้ำ, invalidate ทุก token ใน family → detect compromise ได้
- **Redis vs DB:** refresh token มักเก็บใน Redis เพราะ TTL native, fast lookup — DB เหมาะถ้าต้องการ audit log ระยะยาว
- **kata สอนว่า:** short-lived access token ลด blast radius ของ token theft — refresh rotation ลด blast radius ของ refresh token theft — defense in depth
