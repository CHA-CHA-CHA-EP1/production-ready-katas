---
tier: authentication
difficulty: 2
concepts: [jwt, claims-validation, exp-nbf, iss-aud, stateless-auth]
---

# Kata: JWT Validation

## Context

JWT ที่ verify แค่ signature แต่ไม่ตรวจ claims ถือว่าไม่ปลอดภัย
token ที่ expired, มาจาก issuer อื่น, หรือไม่ได้ intended สำหรับ service นี้ — ถ้า signature valid ก็ผ่านได้
ใน microservice architecture ที่หลาย service ใช้ JWT ร่วมกัน การไม่ check `iss` และ `aud` เปิด cross-service token reuse

## Real World Incidents

**Incident 1 — Expired Token Auth Bypass (รายงาน Bug Bounty, ทั่วไป)**
หลาย API endpoint รับ JWT ที่ expired แล้วเพราะ verify แค่ signature ไม่ check `exp` claim
attacker ที่ได้ token เก่าจาก traffic log หรือ leaked token สามารถใช้ต่อได้ไม่จำกัดเวลา
pattern นี้ถูกพบซ้ำๆ ใน bug bounty program — มักได้ medium-high severity
แก้ด้วยการเพิ่ม `WithExpirationRequired()` และตรวจสอบ `exp` ก่อน process request ใดๆ

**Incident 2 — Cross-Service Token Reuse (ระบบ Internal, 2019-2022)**
บริษัทหลายแห่งที่ใช้ shared JWT secret ระหว่าง microservices พบว่า token ที่ issue สำหรับ service A
สามารถใช้กับ service B ได้เพราะทั้งคู่ใช้ secret เดียวกันและไม่ check `aud` claim
attacker ที่มี token สำหรับ service ที่ permission ต่ำกว่าสามารถ escalate ไป service ที่ sensitive กว่า
แก้ด้วยการใช้ issuer-specific secret หรือ verify `aud` claim ใน validation ทุกครั้ง

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// ❌ verify แค่ signature — ไม่ check claims
token, err := jwt.Parse(tokenString, func(token *jwt.Token) (interface{}, error) {
    return []byte(secret), nil
})
if err != nil || !token.Valid {
    return nil, errors.New("invalid token")
}
// token.Valid == true แต่ token อาจ expired แล้วก็ได้!

// ❌ check exp เอง แต่ลืม nbf, iss, aud
claims := token.Claims.(jwt.MapClaims)
if exp, ok := claims["exp"].(float64); ok {
    if time.Now().Unix() > int64(exp) {
        return nil, errors.New("expired")
    }
}
// ลืม check nbf, iss, aud — ยังโดน attack ได้อยู่
```

**พังตอนไหน:**
- ไม่ check `exp` → expired token ยังใช้ได้ → stolen token valid ตลอดไป
- ไม่ check `nbf` → token ที่ยังไม่ถึงเวลาใช้งาน accepted → race condition ใน token exchange
- ไม่ check `iss` → token จาก identity provider อื่นที่มี key เดียวกัน accepted
- ไม่ check `aud` → token ที่ intended สำหรับ service อื่น accepted → cross-service reuse

**Root cause:**
JWT spec กำหนดให้ validate claims เหล่านี้ แต่ library ส่วนใหญ่ไม่บังคับ — developer ต้อง opt-in เอง
signature verification เป็นแค่ขั้นแรก — claims validation เป็นส่วนที่สำคัญกว่าในเชิง business logic

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `jwt.ParseWithClaims` vs `jwt.Parse` — ต่างกันยังไง? ทำไม `ParseWithClaims` ถึงดีกว่าสำหรับ typed claims?
- hint: `jwt.RegisteredClaims` — มี field อะไรบ้าง? `ExpiresAt` เป็น type อะไร? ต่างจาก `exp` ใน JSON ยังไง?
- hint: `jwt.WithExpirationRequired()` — ถ้าไม่ใส่ option นี้ token ที่ไม่มี `exp` claim จะ valid ไหม?
- hint: `jwt.WithAudience(aud string)` และ `jwt.WithIssuer(iss string)` — ใส่ตรงไหนใน `ParseWithClaims`?
- `token.Valid` เป็น `true` หมายความว่าอะไร? signature valid เพียงพอไหมที่จะ trust token?
- `jwt.ValidationError` มี error code อะไรบ้าง? จะ return typed error แยกตาม failure reason ได้ยังไง?

## Task

implement :

```
claims {
  jwt.RegisteredClaims
  UserID string `json:"user_id"`
  Role string `json:"role"`
}

validateToken(tokenString, secret, expectedIssuer, expectedAudience) → *Claims, error
```

`ValidateToken` verify JWT และ validate claims ทั้งหมด คืน `*Claims` เมื่อ valid
ต้อง return typed error ที่บอกสาเหตุ: expired, not yet valid, wrong issuer, wrong audience, invalid signature

## Requirements

- ต้อง verify signature ด้วย HMAC-SHA256 (HS256)
- ต้อง reject token ที่ไม่มี `exp` claim (ไม่ใช่แค่ ignore)
- ต้อง reject token ที่ `exp` ผ่านไปแล้ว
- ต้อง reject token ที่ `nbf` ยังไม่ถึง (ถ้ามี `nbf` claim)
- ต้อง reject token ที่ `iss` ไม่ตรงกับ `expectedIssuer`
- ต้อง reject token ที่ `aud` ไม่มี `expectedAudience` อยู่ใน list
- ต้อง return error ที่แตกต่างกันสำหรับแต่ละ failure reason (ไม่ใช่ generic "invalid token")

## Acceptance Criteria

- [ ] token ที่ valid ทุก claim คืน `*Claims` ที่ถูกต้อง
- [ ] token ที่ expired คืน error ที่ระบุว่า expired (ไม่ใช่ generic error)
- [ ] token ที่ไม่มี `exp` claim คืน error (ไม่ accept)
- [ ] token ที่ `iss` ไม่ตรง คืน error ที่ระบุว่า wrong issuer
- [ ] token ที่ `aud` ไม่ตรง คืน error ที่ระบุว่า wrong audience
- [ ] token ที่ signature ผิด คืน error ที่ระบุว่า invalid signature
- [ ] token ที่ malformed (ไม่ใช่ JWT format) คืน error ที่ชัดเจน ไม่ panic

## Concepts Involved

- `jwt` — structure ของ JWT, standard claims, stateless validation → `shared/concepts/jwt.md`
- `stateless-auth` — ทำไม JWT ต้องครบถ้วนใน token เอง, ไม่มี server-side state → `shared/concepts/jwt.md`

## Production Reality

- **ใช้จริง:** ทุก service ที่รับ JWT ต้อง validate ครบทุก claim — library เช่น `golang-jwt/jwt` มี option เหล่านี้ให้ใช้แต่ต้อง opt-in
- **Clock skew:** production ต้องพิจารณา clock skew ระหว่าง server — เพิ่ม leeway เล็กน้อย (เช่น 30 วินาที) สำหรับ `exp` และ `nbf`
- **kata สอนว่า:** JWT เป็น stateless — ทุก security decision ต้อง encode ใน token เองและ validate ทุกครั้ง — ขาดตกบรรทัดเดียวเปิด vulnerability ได้
