# Concept: JSON Web Token (JWT)

## Structure: Header.Payload.Signature

JWT คือ string สามส่วนที่คั่นด้วย `.` แต่ละส่วน encode ด้วย **Base64URL** (ไม่ใช่ encryption!)

```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMTIzIiwiZXhwIjoxNzAwMDAwMDAwfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
←————————————— header ————————————————→←—————————————— payload —————————————————→←———————— signature ————————→
```

**Header (Base64URL decode แล้วได้ JSON):**
```json
{
  "alg": "HS256",
  "typ": "JWT"
}
```

**Payload (Base64URL decode แล้วได้ JSON):**
```json
{
  "sub": "user123",
  "iss": "https://auth.example.com",
  "aud": "api.example.com",
  "exp": 1700000000,
  "nbf": 1699996400,
  "iat": 1699996400,
  "jti": "unique-token-id-abc123",
  "role": "admin"
}
```

**สำคัญ:** Base64URL ไม่ใช่ encryption — ใครก็ decode payload ได้โดยไม่ต้องมี key
อย่าเก็บ sensitive data ใน JWT payload เช่น password, credit card number, PII

## Standard Claims (Registered Claims)

| Claim | ชื่อเต็ม | ความหมาย | ตัวอย่าง |
|-------|----------|-----------|---------|
| `sub` | Subject | user หรือ entity ที่ token represent | `"user_id_123"` |
| `iss` | Issuer | service ที่ออก token | `"https://auth.example.com"` |
| `aud` | Audience | service ที่ token intended สำหรับ | `"api.example.com"` หรือ `["svc-a", "svc-b"]` |
| `exp` | Expiration | unix timestamp ที่ token expire | `1700000000` |
| `nbf` | Not Before | unix timestamp ที่ token เริ่มใช้ได้ | `1699996400` |
| `iat` | Issued At | unix timestamp ที่ออก token | `1699996400` |
| `jti` | JWT ID | unique ID ของ token นี้ (สำหรับ revocation) | `"abc123-def456"` |

**Validation Checklist (ทำตามลำดับ):**
1. ✅ verify signature ก่อนอื่น — ถ้าผิดหยุดทันที
2. ✅ check `exp` — reject ถ้าหมดอายุแล้ว
3. ✅ check `nbf` (ถ้ามี) — reject ถ้ายังไม่ถึงเวลา
4. ✅ check `iss` — reject ถ้าไม่ใช่ issuer ที่คาดหวัง
5. ✅ check `aud` — reject ถ้าไม่ได้ intended สำหรับ service นี้
6. ✅ check custom claims ตาม business logic
7. ✅ check blocklist ด้วย `jti` ถ้ามี revocation mechanism

## Signing Algorithms: HS256 vs RS256

### HS256 — Symmetric (HMAC-SHA256)

```
sign:   HMAC-SHA256(header.payload, secret_key)
verify: HMAC-SHA256(header.payload, secret_key) == signature
```

- ใช้ **key เดียวกัน** สำหรับ sign และ verify
- ถ้า key รั่ว → attacker forge token ได้ทันที
- เหมาะสำหรับ: monolith หรือ services ที่ไว้วางใจกันได้ (internal only)
- ต้องแชร์ secret กับทุก service ที่ต้องการ verify → key distribution problem

### RS256 — Asymmetric (RSA-SHA256)

```
sign:   RSA_SIGN(header.payload, private_key)     ← issuer เท่านั้นที่มี
verify: RSA_VERIFY(header.payload, signature, public_key)  ← ทุก service มีได้
```

- ใช้ **private key** สำหรับ sign, **public key** สำหรับ verify
- private key อยู่ที่ auth server เท่านั้น
- public key แจกได้อย่างเปิดเผย (JWKS endpoint)
- ถ้า public key รั่ว → attacker ยังไม่สามารถ forge token ได้ (ต้องมี private key)
- เหมาะสำหรับ: microservices, multi-tenant, federated identity

### ES256 — Asymmetric (ECDSA-SHA256)

- เหมือน RS256 แต่ใช้ Elliptic Curve Cryptography
- key size เล็กกว่า RSA มาก — signature เล็กกว่า, compute เร็วกว่า
- แนะนำสำหรับ new system ที่ต้องการ asymmetric JWT

## Algorithm Confusion Attack

### RS256 → HS256 Downgrade

**scenario:**
1. ระบบใช้ RS256: sign ด้วย private key, verify ด้วย public key
2. public key ถูกเปิดเผย (ปกติ จาก JWKS endpoint หรือ config)
3. attacker ดาวน์โหลด public key มา
4. attacker สร้าง JWT ที่มี header: `{"alg": "HS256", "typ": "JWT"}`
5. attacker sign JWT นั้นด้วย public key เป็น HMAC secret
6. server ที่ไม่ check algorithm: "oh, HS256, ใช้ key ที่มีอยู่ verify..." → ผ่าน!

```
RS256 public key (bytes) → ใช้เป็น HS256 HMAC secret → verify สำเร็จ
```

**Fix:** KeyFunc ต้อง check algorithm ก่อน return key:
```go
jwt.ParseWithClaims(tokenString, &claims, func(token *jwt.Token) (interface{}, error) {
    // ✅ check algorithm ก่อนเสมอ
    if token.Method.Alg() != "RS256" {
        return nil, fmt.Errorf("unexpected signing algorithm: %s", token.Method.Alg())
    }
    return publicKey, nil
})
```

### alg:none Attack

JWT spec กำหนดว่า `"alg": "none"` หมายถึงไม่มี signature — token เป็นแค่ unsigned data
library บางตัว (เก่า) implement ตาม spec และ accept token ที่ไม่มี signature

```json
// header
{"alg": "none", "typ": "JWT"}
// payload
{"sub": "admin", "role": "superuser", "exp": 9999999999}
// signature = "" (empty string)
```

attacker สร้าง token แบบนี้ได้โดยไม่ต้องมี key — ถ้า library accept → auth bypass สมบูรณ์

**Fix:** reject `alg: none` ก่อนทำอะไรทั้งนั้น:
```go
if token.Method == jwt.SigningMethodNone {
    return nil, fmt.Errorf("algorithm 'none' is not allowed")
}
```

## สิ่งที่ JWT ไม่ได้ให้

**JWT ไม่ใช่ encryption:**
- payload อ่านได้โดยใครก็ตามที่มี token
- ถ้าต้องการ encrypt payload → ใช้ **JWE** (JSON Web Encryption) แทน
- JWE ซับซ้อนกว่ามาก — ใช้เฉพาะเมื่อ necessary จริงๆ

**JWT ไม่มี revocation (โดย default):**
- JWT เป็น stateless — server ไม่เก็บ state ว่า token ไหนยัง valid
- ไม่มีวิธี "cancel" token ก่อน expire โดยไม่เพิ่ม server-side state
- workaround: blocklist ด้วย `jti` claim + Redis TTL
- workaround: short-lived token (5-15 นาที) + refresh rotation

**JWT ไม่ใช่ session:**
- session มี server-side state → server control ได้ทุกอย่าง
- JWT stateless → ไม่มี server state → ง่ายต่อ scale แต่ยาก revoke

## JWT ใน Go: golang-jwt/jwt

```go
import "github.com/golang-jwt/jwt/v5"

// Define custom claims
type Claims struct {
    jwt.RegisteredClaims
    UserID string `json:"user_id"`
    Role   string `json:"role"`
}

// Issue token
claims := Claims{
    RegisteredClaims: jwt.RegisteredClaims{
        Subject:   userID,
        Issuer:    "https://auth.example.com",
        Audience:  jwt.ClaimStrings{"api.example.com"},
        ExpiresAt: jwt.NewNumericDate(time.Now().Add(15 * time.Minute)),
        IssuedAt:  jwt.NewNumericDate(time.Now()),
        ID:        generateJTI(), // unique per token
    },
    UserID: userID,
    Role:   "user",
}
token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
signed, err := token.SignedString([]byte(secret))

// Validate token
parsed, err := jwt.ParseWithClaims(
    tokenString,
    &Claims{},
    func(token *jwt.Token) (interface{}, error) {
        // 1. Check algorithm
        if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
            return nil, fmt.Errorf("unexpected algorithm: %v", token.Header["alg"])
        }
        return []byte(secret), nil
    },
    jwt.WithExpirationRequired(),           // reject tokens without exp
    jwt.WithIssuer("https://auth.example.com"),
    jwt.WithAudience("api.example.com"),
)
```

## JWKS: JSON Web Key Set

ระบบที่ใช้ RS256 มักเปิด endpoint สำหรับ public key:
```
GET https://auth.example.com/.well-known/jwks.json
```

response:
```json
{
  "keys": [
    {
      "kty": "RSA",
      "use": "sig",
      "kid": "key-id-2024",
      "n": "...",
      "e": "AQAB"
    }
  ]
}
```

service ที่ verify token download public key จาก JWKS endpoint แทนการ hardcode
`kid` (Key ID) ใน JWT header บอกว่า key ไหนใช้ verify — ช่วยให้ rotate key ได้โดยไม่ downtime
