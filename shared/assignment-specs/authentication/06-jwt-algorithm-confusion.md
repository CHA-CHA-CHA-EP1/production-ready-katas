---
tier: authentication
difficulty: 3
concepts: [jwt-algorithm-confusion, alg-none, keyfunc, asymmetric-keys, jwt-cve]
---

# Kata: JWT Algorithm Confusion Attack

## Context

JWT header บอก library ว่าใช้ algorithm อะไร verify signature — ถ้า library เชื่อ header โดยไม่ตรวจสอบ
attacker เปลี่ยน `alg` ใน header ได้ตามต้องการ — เปลี่ยนจาก RS256 เป็น HS256 แล้วใช้ public key เป็น secret
หรือเปลี่ยนเป็น `none` แล้วไม่ต้องมี signature เลย — ผ่าน verification ได้ทันที

## Real World Incidents

**Incident 1 — Auth0 Algorithm Confusion CVE (Auth0, 2015)**
Auth0 JWT library มีช่องโหว่ที่ยอมรับ `alg: none` โดยไม่ reject
attacker สร้าง JWT ที่มี `alg: none` และ claims ใดๆ ที่ต้องการ — ไม่มี signature
library ตรวจสอบ "signature" ของ empty string แล้ว accept token นั้นว่า valid
ช่องโหว่นี้ถูก disclose อย่างกว้างขวางและทำให้ JWT community ตื่นตัวเรื่อง algorithm whitelist

**Incident 2 — RS256 to HS256 Confusion (Multiple JWT Libraries, 2015-2017)**
JWT library หลายตัว (Node.js, PHP, Python) มีช่องโหว่ algorithm confusion
ระบบที่ใช้ RS256 (asymmetric) เก็บ public key ไว้ใน config ที่ accessible
attacker download public key → สร้าง JWT ที่ claim `alg: HS256` → sign ด้วย public key เป็น HMAC secret
server ที่ configure ไว้สำหรับ RS256 แต่ library ไม่ lock algorithm — verify ด้วย public key เป็น HMAC secret → pass
CVE-2015-9235, CVE-2016-10555 และอีกหลายตัวล้วนมาจากปัญหานี้

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// ❌ ไม่ check algorithm — เชื่อ header
token, err := jwt.Parse(tokenString, func(token *jwt.Token) (interface{}, error) {
    return publicKey, nil  // คืน key โดยไม่ check token.Method
})

// ❌ check แค่ว่าเป็น signing method แต่ไม่ check ว่าเป็น method ที่ expected
token, err := jwt.Parse(tokenString, func(token *jwt.Token) (interface{}, error) {
    if _, ok := token.Method.(*jwt.SigningMethodRSA); !ok {
        return nil, fmt.Errorf("unexpected method")
    }
    return publicKey, nil  // ยังโดน HS256 ที่ใช้ RSA public key ได้อยู่
})

// ❌ ไม่ reject alg:none โดย explicit
```

**พังตอนไหน:**
- ไม่ check `token.Method` → attacker เปลี่ยน `alg` เป็น `none` → ไม่ต้องมี signature
- ไม่ check specific algorithm → RS256 public key ถูกใช้เป็น HS256 secret
- check type แต่ไม่ check algorithm string → `jwt.SigningMethodHS256` และ `jwt.SigningMethodHS384` ต่างกันแต่ทั้งคู่ pass type check เดียวกัน

**Root cause:**
JWT spec กำหนดว่า `alg: none` เป็น valid — library หลายตัวรองรับตาม spec โดยไม่ถามว่าควรไหม
การ trust `alg` จาก header ทำให้ attacker ควบคุม verification algorithm ได้
fix เดียวที่ถูกต้องคือ whitelist algorithm ที่ยอมรับก่อน return key ใน KeyFunc

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `jwt.Parse` KeyFunc parameter — `token *jwt.Token` ที่ส่งมาใน KeyFunc มี `token.Method` ที่เป็นอะไร? จะ check algorithm name จาก `token.Method` ยังไง?
- hint: `(*jwt.SigningMethodHMAC).Alg()` และ `(*jwt.SigningMethodRSA).Alg()` — return string อะไร? ใช้เปรียบเทียบกับ whitelist ยังไง?
- hint: `jwt.UnsafeAllowNoneSignatureType` — ทำไม library ถึงมี constant นี้? ควรใช้เมื่อไหร่ (ถ้าเคย)?
- KeyFunc ต้อง return key type ที่ถูกต้องตาม algorithm — RS256 ต้อง return `*rsa.PublicKey`, HS256 ต้อง return `[]byte` — จะ route ยังไงถ้า support หลาย algorithm?
- ถ้า algorithm ไม่อยู่ใน whitelist — KeyFunc ควร return error อะไร? error นั้นจะปรากฏอย่างไรใน caller?

## Task

implement :

```
type KeyFunc func(algorithm string) (key interface{}, err error)

func arseJWT(
    tokenString string,
    allowedAlgorithms list,
    getKey KeyFunc,
) (, error)
```

`ParseJWT` parse และ verify JWT โดย:
1. reject `alg: none` เสมอ ก่อนทำอะไรทั้งนั้น
2. reject algorithm ที่ไม่อยู่ใน `allowedAlgorithms`
3. เรียก `getKey(algorithm)` เพื่อ get key ที่เหมาะสมตาม algorithm
4. verify signature ด้วย key และ algorithm ที่กำหนด

## Requirements

- ต้อง reject `alg: none` ก่อนทำขั้นตอนอื่น — ไม่ว่า `allowedAlgorithms` จะมีค่าอะไร
- ต้อง reject algorithm ที่ไม่อยู่ใน `allowedAlgorithms` whitelist
- `getKey` ต้องถูกเรียกด้วย algorithm string ที่ verify แล้วว่าอยู่ใน whitelist — ไม่ใช่ raw value จาก header
- ต้อง return error ที่แยกแยะได้ระหว่าง: algorithm not allowed, signature invalid, token malformed
- ห้าม parse claims ก่อน verify algorithm — algorithm check ต้องเป็นขั้นตอนแรกใน KeyFunc

## Acceptance Criteria

- [ ] token ที่มี `alg: none` ถูก reject เสมอ แม้ว่า claims จะ valid
- [ ] token ที่มี algorithm ที่ไม่อยู่ใน whitelist ถูก reject พร้อม error ที่ชัดเจน
- [ ] token ที่มี algorithm ถูกต้องและ signature valid ผ่าน verification
- [ ] RS256 public key ที่ใช้เป็น HS256 secret ถูก reject (algorithm mismatch)
- [ ] `allowedAlgorithms: []string{"RS256"}` → HS256 token ถูก reject ทันที
- [ ] error message บอก algorithm ที่ได้รับ vs ที่คาดหวัง เพื่อ debug ได้

## Concepts Involved

- `jwt` — algorithm field ใน header, asymmetric vs symmetric key types → `shared/concepts/jwt.md`
- `jwt-algorithm-confusion` — attack mechanism, ทำไม library trust header โดย default, whitelist fix → `shared/concepts/jwt.md`

## Production Reality

- **ใช้จริง:** `golang-jwt/jwt` v5 require explicit KeyFunc — ยากขึ้นที่จะเขียนผิดได้ vs v4
- **Best practice:** ใช้ RS256 หรือ ES256 (asymmetric) สำหรับ production — public key ที่รั่วไม่ทำให้ forge token ได้ ต่างจาก HS256 ที่ secret key รั่ว = game over
- **`alg: none`** ควรถูก reject ใน library level แต่ Go library บาง version ยัง allow — อย่า rely on library default, เพิ่ม explicit check เสมอ
- **kata สอนว่า:** JWT `alg` header เป็น untrusted user input — treat เหมือน input validation ทั่วไป ไม่ใช่ trusted config
