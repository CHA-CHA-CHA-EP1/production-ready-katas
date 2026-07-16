---
tier: authentication
difficulty: 3
concepts: [token-revocation, jwt-blocklist, jti-claim, redis-ttl, stateless-tradeoff]
---

# Kata: Token Revocation

## Context

JWT ที่ stateless คือ double-edged sword — verify ได้โดยไม่ต้อง query DB แต่ก็ revoke ได้ยาก
การ "logout" ที่แค่ลบ cookie จาก client ไม่ได้ invalidate token จริงๆ — attacker ที่ copy token ไปก่อนหน้าใช้ต่อได้
blocklist pattern แก้ปัญหานี้ด้วย overhead ที่จำกัด: เฉพาะ revoked token เท่านั้นที่ต้องเก็บ ไม่ต้องเก็บทุก token

## Real World Incidents

**Incident 1 — Auth Token Exposure after Logout (Salesforce, 2025)**
Salesforce พบ security issue ที่ session token บางตัวยังสามารถใช้งานได้หลัง user logout
เพราะ token เป็น stateless JWT ที่ valid จนกว่าจะ expire — server-side logout ไม่ invalidate token จริงๆ
attacker ที่ capture token จาก traffic (เช่น ใน shared network) ยังคงมี access หลัง user logout
Salesforce ต้อง implement token revocation ด่วนและแจ้งให้ customer review audit log

**Incident 2 — Account Takeover after Password Change (การค้นพบทั่วไปจาก Penetration Testing)**
User เปลี่ยน password หลังสงสัยว่า account ถูก compromise — ช่อง "logout all devices" ก็กด
แต่ JWT ที่ attacker มีอยู่ยังคง valid จนกว่าจะ expire (บางครั้งนานหลายชั่วโมง)
attacker ยังคง access ได้ในช่วงเวลานั้น — บางกรณีเปลี่ยนข้อมูลสำคัญหรือ exfiltrate ข้อมูลก่อน token หมดอายุ
pattern นี้เป็น known limitation ของ stateless JWT ที่ต้องแก้ด้วย revocation mechanism

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// ❌ "logout" แค่ลบ cookie จาก client
func Logout(w http.ResponseWriter) {
    http.SetCookie(w, &http.Cookie{
        Name:   "session",
        Value:  "",
        MaxAge: -1,
    })
    // token ยังใช้งานได้อยู่ถ้ามีคนเอาไปแล้ว!
}

// ❌ เก็บ blocklist ทุก token ที่เคย issue — ใช้ memory มหาศาล
func RevokeToken(tokenID string) {
    revokedTokens[tokenID] = true  // map ที่ไม่เคย clear
}

// ❌ ไม่มี TTL → blocklist โตเรื่อยๆ ไม่มีวันหมด
redis.Set(ctx, "revoked:"+jti, "1", 0) // 0 = no expiry
```

**พังตอนไหน:**
- แค่ลบ cookie → token ที่ถูก copy ก่อนหน้ายังใช้ได้จนหมดอายุ
- เก็บทุก token → blocklist โตเรื่อยๆ, memory leak, ไม่ scalable
- ไม่มี TTL → token ที่ expire ตาม JWT แล้วยังอยู่ใน blocklist ตลอดไป
- check blocklist แต่ไม่ handle Redis down → service พัง หรือข้าม security check

**Root cause:**
JWT stateless หมายถึงไม่มี server-side state — การ revoke ต้องเพิ่ม state กลับเข้าไป
trick คือเพิ่มเฉพาะ state ที่จำเป็น: เก็บแค่ revoked token และลบออกเมื่อ expire ตาม JWT อยู่แล้ว
Redis TTL ทำงานได้ perfect สำหรับ use case นี้ — token expire จาก JWT → ออกจาก blocklist อัตโนมัติ

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `jwt.RegisteredClaims.ID` — นี่คือ `jti` claim, ควร generate ด้วยอะไร? ทำไมต้อง unique ต่อ token?
- hint: Redis `SET key value EX seconds NX` — `EX` คืออะไร? ทำไม TTL ของ blocklist entry ควรเท่ากับเวลาที่เหลือจนถึง token expiry?
- เมื่อ parse JWT สำเร็จ จะคำนวณเวลาที่เหลือจนถึง expiry ยังไง? `claims.ExpiresAt.Time.Sub(time.Now())` → ถ้าค่าลบแสดงว่าอะไร?
- ถ้า Redis unavailable ระหว่าง blocklist check — ควร fail open (allow request) หรือ fail closed (deny request)? trade-off คืออะไร?
- hint: `http.Handler` middleware pattern — จะ inject blocklist check ระหว่าง JWT parse กับ handler ยังไง?
- `jti` ที่ generate โดย attacker แล้ว revoke ก่อน — attack scenario นี้เป็นไปได้ไหม? จะป้องกันยังไง?

## Task

เขียนสองส่วน:

```
type TokenStore interface {
    AddToBlocklist(ctx cancellation context, jti string, ttl duration) error
    IsBlocklisted(ctx cancellation context, jti string) (bool, error)
}

revokeToken(ctx, store, tokenString, secret) → error

requireValidToken(store, secret, next) → HTTP middleware handler
```

`RevokeToken` parse token, extract `jti` และ remaining TTL, เพิ่มลง blocklist
`RequireValidToken` เป็น middleware ที่ validate JWT signature + claims + blocklist ก่อน forward ไป handler

## Requirements

- token ต้องมี `jti` claim — ถ้าไม่มี `jti`, `RevokeToken` คืน error
- TTL ของ blocklist entry ต้องเท่ากับเวลาที่เหลือจนถึง token expiry (ไม่ใช่ fixed duration)
- `RequireValidToken` ต้อง check ทั้ง JWT validity และ blocklist — ลำดับ: parse signature → check claims → check blocklist
- ถ้า TokenStore unavailable (error), middleware ต้อง fail closed — return 503 Service Unavailable
- fail closed message ต้องไม่รั่ว internal error detail ออกไป — log เก็บไว้ แต่ response เป็น generic message
- `jti` ต้อง generate ตอน issue token ด้วย `crypto/rand` — ไม่ใช่ sequential ID

## Acceptance Criteria

- [ ] token ที่ valid และไม่อยู่ใน blocklist ผ่าน middleware
- [ ] token ที่ revoke แล้ว ถูก reject ด้วย 401 แม้ว่า JWT signature และ claims ยัง valid
- [ ] `RevokeToken` เพิ่ม jti ลง blocklist ด้วย TTL ที่ถูกต้อง (ไม่เกินเวลา expire ของ token)
- [ ] หลัง token expire ตาม JWT, blocklist entry หาย (TTL หมด) — ไม่ต้อง cleanup manual
- [ ] ถ้า TokenStore return error, middleware return 503 ไม่ใช่ 200
- [ ] token ที่ไม่มี `jti` claim ถูก reject โดย `RevokeToken`

## Concepts Involved

- `jwt` — jti claim คืออะไร, stateless tradeoff ที่ต้องแก้ด้วย revocation → `shared/concepts/jwt.md`
- `token-revocation` — blocklist pattern, ทำไม TTL ต้องตรงกับ token expiry, fail open vs fail closed → (concept doc ยังไม่มี)

## Production Reality

- **ใช้จริง:** Redis เป็น standard สำหรับ JWT blocklist — fast, TTL native, horizontal scalable
- **Scale concern:** blocklist ขนาดใหญ่เมื่อ logout volume สูง (เช่น force logout ทั้ง platform) — Redis cluster handle ได้แต่ต้อง plan
- **Alternative:** short-lived access token (5-15 นาที) + refresh rotation ลด need ของ per-request blocklist check — แต่ยังต้องการ revocation สำหรับ "logout all devices" feature
- **kata สอนว่า:** JWT stateless เป็น property ที่มี cost — revocation คือการยอมรับ state บางส่วนกลับมา รู้จัก tradeoff และเลือกอย่างตั้งใจ
