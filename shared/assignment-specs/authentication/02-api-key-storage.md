---
tier: authentication
difficulty: 2
concepts: [api-key-storage, crypto-rand, sha256, show-once-pattern, constant-time-compare]
---

# Kata: API Key Storage

## Context

API key คือ credential ที่ต้องตรวจสอบทุก request — อาจวินาทีละหลายพัน request ในระบบ production
วิธีเก็บ key ต้องปลอดภัย (breach ไม่เปิด key ทั้งหมด) และเร็วพอสำหรับ per-request validation
bcrypt ช้าเกินไปสำหรับ use case นี้ — ต้องใช้วิธีอื่นที่ยังคง security ได้

## Real World Incidents

**Incident 1 — Twitch Source Code and API Key Breach (Twitch, 2021)**
Twitch ถูก breach ขนาดใหญ่ — source code และ internal data 125GB รั่วไหลทาง torrent
ใน data ที่รั่วพบ API key และ credential หลายรายการที่เก็บใน plain text หรือ log
Twitch ต้องรีบ rotate key ทุกตัวและแจ้ง streamer ให้เปลี่ยน credential ใหม่ทั้งหมด
บทเรียน: key ที่ถูกเก็บ plain text ใน breach หมายถึง revoke ไม่ทัน — damage เกิดก่อนที่จะรู้ตัว

**Incident 2 — GitHub OAuth Token Exposure in Logs (GitHub, 2013)**
GitHub พบว่า OAuth token บาง token ถูก log ลง server log ในระหว่าง debugging session
log ที่ถูก access โดย third-party monitoring service ทำให้ token รั่วออกไปชั่วคราว
GitHub ต้อง rotate token ที่ exposed ทั้งหมดและเพิ่ม secret scanning ใน pipeline
การเก็บ hash แทน plaintext ทำให้ token ที่อยู่ใน log ไม่สามารถ replay ได้

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// ❌ เก็บ plain text ใน DB
key := generateRandomString(32)
db.Exec("INSERT INTO api_keys (key, user_id) VALUES (?, ?)", key, userID)

// ❌ เปรียบเทียบ plain text ตรงๆ
row := db.QueryRow("SELECT * FROM api_keys WHERE key = ?", inputKey)

// ❌ ใช้ bcrypt สำหรับ API key
hash, _ := bcrypt.GenerateFromPassword([]byte(key), 12)
// แล้วต้อง bcrypt.CompareHashAndPassword ทุก request → ช้ามาก
```

**พังตอนไหน:**
- เก็บ plain text → database breach เปิด key ทั้งหมดทันที
- ค้นหาด้วย `WHERE key = ?` → timing attack รู้ได้ว่า key ถูกต้องหรือไม่จากเวลา DB query
- bcrypt ทุก request → 300ms per request → ระบบรับ traffic ไม่ได้

**Root cause:**
API key มี entropy สูง (32 bytes random = 256 bits) — ไม่เหมือน password ที่คนพิมพ์เอง
เพราะ entropy สูง SHA-256 ปลอดภัยเพียงพอ — attacker ไม่สามารถ brute force ได้
pattern ที่ถูกต้องคือ hash ก่อนเก็บ แล้ว hash อีกครั้งตอน validate — เหมือน password แต่ใช้ SHA-256 แทน bcrypt

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `crypto/rand.Read(b []byte)` — ต่างจาก `math/rand` ยังไง? ทำไม API key ต้องใช้ cryptographically secure random?
- hint: `crypto/sha256.Sum256(data []byte)` — return type คืออะไร? ทำไมถึง OK ใช้ SHA-256 สำหรับ API key แต่ไม่ OK สำหรับ password?
- hint: `encoding/hex.EncodeToString` vs `encoding/base64.RawURLEncoding.EncodeToString` — อันไหนเหมาะสำหรับ API key ที่ต้องใส่ใน HTTP header? ต่างกันใน output length ยังไง?
- hint: `crypto/subtle.ConstantTimeCompare(x, y []byte)` — ทำไมต้องใช้แม้ว่า attacker ไม่รู้ original key? อะไรที่ทำให้ timing leak เกิดได้แม้ใน hash comparison?
- key prefix เช่น `sk_live_` มีประโยชน์อะไรนอกจาก readability? GitHub, Stripe ใช้ pattern นี้เพื่ออะไร?

## Task

เขียนสองฟังก์ชัน:

```go
func GenerateAPIKey() (plaintext string, hash string, err error)
func ValidateAPIKey(plaintext, storedHash string) bool
```

`GenerateAPIKey` สร้าง API key ใหม่ คืน plaintext (แสดงให้ user ครั้งเดียวเท่านั้น) และ hash (เก็บใน DB)
`ValidateAPIKey` รับ key จาก HTTP request และ hash จาก DB แล้วตรวจสอบว่าตรงกันหรือไม่

## Requirements

- ต้องใช้ `crypto/rand` สำหรับ generate — ห้ามใช้ `math/rand` หรือ UUID library
- entropy ต้องมีอย่างน้อย 32 bytes (256 bits) ก่อน encode
- key format ต้องมี prefix ที่ระบุ type ได้ เช่น `sk_live_` หรือ `sk_test_`
- เก็บ SHA-256 hash ใน hex หรือ base64 format — ไม่เก็บ plaintext
- `ValidateAPIKey` ต้องใช้ constant-time comparison — ห้ามใช้ `==` หรือ `strings.Compare`
- `GenerateAPIKey` ต้อง propagate error จาก `crypto/rand` อย่างชัดเจน

## Acceptance Criteria

- [ ] `GenerateAPIKey()` คืน key ที่มี prefix ถูกต้องและ `ValidateAPIKey` ตรวจสอบผ่าน
- [ ] เรียก `GenerateAPIKey()` สองครั้ง คืน key ที่ต่างกันทุกครั้ง (ไม่ซ้ำ)
- [ ] `ValidateAPIKey(key, hash)` คืน `true` เฉพาะเมื่อ key ตรงกับ hash จริงๆ
- [ ] `ValidateAPIKey("wrong-key", hash)` คืน `false` — ไม่ panic ไม่ error
- [ ] hash ที่เก็บใน DB ไม่สามารถ reverse กลับเป็น plaintext key ได้
- [ ] key สองตัวที่ต่างกันไม่มีทาง validate ผ่าน hash เดิมได้ (no collision)

## Concepts Involved

- `api-key-storage` — show-once pattern คืออะไร, ทำไม SHA-256 OK สำหรับ high-entropy secret, prefix สำหรับ secret scanning → `shared/concepts/password-hashing.md`
- `crypto-rand` — ความแตกต่างของ CSPRNG กับ PRNG, entropy source จาก OS → (concept doc ยังไม่มี)

## Production Reality

- **ใช้จริง:** Stripe, GitHub, Linear ใช้ pattern นี้ทั้งหมด — key prefix ช่วย secret scanning tool (เช่น GitHub secret scanning) detect key ที่รั่วใน repo ได้อัตโนมัติ
- **Show-once pattern:** ระบบ production แสดง plaintext key ให้ user ครั้งเดียวตอน generate — ถ้า user หาย ต้อง revoke แล้ว generate ใหม่เท่านั้น
- **kata สอนว่า:** ไม่ใช่ทุก secret ต้องใช้ bcrypt — รู้จัก entropy ของ secret แล้วเลือก algorithm ที่เหมาะสม
