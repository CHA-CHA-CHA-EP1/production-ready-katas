# Concept: Password Hashing

## ทำไม MD5, SHA1, SHA256 ถึงผิดสำหรับ Password

hash function เหล่านี้ถูกออกแบบมาเพื่อ **speed** — checksum ไฟล์, integrity verification, digital signature
ความเร็วเป็นจุดแข็ง แต่สำหรับ password มันคือจุดอ่อนร้ายแรง

**ตัวเลขจริง (2024, consumer GPU):**
```
MD5:       ~50,000,000,000 hash/วินาที (50 billion)
SHA1:      ~20,000,000,000 hash/วินาที (20 billion)
SHA256:    ~10,000,000,000 hash/วินาที (10 billion)
bcrypt 12: ~        50,000 hash/วินาที (50 thousand)
```

password "password123" ด้วย SHA256 ถูก crack ได้ใน milliseconds
password เดียวกันด้วย bcrypt cost 12 ใช้เวลา crack นานหลายปีแม้ใช้ GPU cluster

**ปัญหาที่สอง: Rainbow Table**
SHA256 ไม่มี salt — password เดิม = hash เดิมเสมอ
attacker สร้าง precomputed table ของ `password → hash` ล่วงหน้า
เมื่อได้ hash จาก DB breach แค่ lookup table — crack instant โดยไม่ต้องคำนวณอะไรเลย

## bcrypt: Intentionally Slow

bcrypt ถูกออกแบบโดย Niels Provos และ David Mazières ในปี 1999 โดยตั้งใจให้ช้า

**โครงสร้าง bcrypt hash:**
```
$2a$12$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy
 ↑   ↑  ←————————— salt (22 chars) ————————→ ←—— hash ——→
 |   |
 |   cost factor (12)
 version (2a)
```

**Cost Factor (Work Factor):**
- cost factor = จำนวน round ของ key derivation = 2^cost iterations
- cost 10 → 2^10 = 1,024 rounds
- cost 12 → 2^12 = 4,096 rounds → ช้ากว่า cost 10 ประมาณ 4 เท่า
- cost 14 → 2^14 = 16,384 rounds → ช้ากว่า cost 12 ประมาณ 4 เท่า

**Salt built-in:**
bcrypt generate random 128-bit salt ทุกครั้งที่ hash — encode อยู่ใน hash string เลย
`CompareHashAndPassword` extract salt จาก hash แล้วใช้ verify — ไม่ต้อง store salt แยก

**เวลาจริงบน commodity hardware (2024):**
```
cost 10 → ~100ms per hash
cost 12 → ~300ms per hash   ← production standard
cost 14 → ~1,200ms per hash
```

## การเลือก Work Factor

**ตั้งค่า cost ยังไง:**
```go
const bcryptCost = 12  // production default ที่ดี

// ตรวจสอบเวลาที่ใช้จริงบน hardware ของคุณ
start := time.Now()
bcrypt.GenerateFromPassword([]byte("test"), bcryptCost)
elapsed := time.Since(start)
// target: 100-500ms — ถ้าเร็วกว่า 100ms ควรเพิ่ม cost
```

**Tradeoff:**
- cost สูง → ปลอดภัยกว่า → login ช้าลง + CPU load สูงขึ้น
- cost ต่ำ → เร็วกว่า → attacker crack ได้เร็วขึ้นถ้า DB breach
- cost 12 เป็น sweet spot ที่ยอมรับกันใน community — login ~300ms ยัง UX acceptable

**ปรับ cost ตามเวลา:**
hardware เร็วขึ้นทุกปี — cost ที่ใช้เวลา 300ms ในปี 2024 อาจใช้เวลา 150ms ในปี 2026
ควร review cost ทุก 2-3 ปีและเพิ่มขึ้น ระบบดีจะ re-hash เมื่อ user login ถ้าค้นพบว่า cost ต่ำเกินไป

## Timing Attack: ทำไม `==` ถึงอันตราย

**Early-exit comparison:**
การเปรียบเทียบ string ด้วย `==` หรือ `bytes.Equal` ทำงานแบบ **early exit**:
เมื่อเจอ byte แรกที่ต่างกัน → return ทันที ไม่ compare ต่อ

```
hash1: "abc123xyz..."
hash2: "abd456..."
          ↑ ต่างตรงนี้ → return false ทันที — ใช้เวลา 3 byte comparisons

hash1: "abc123xyz..."
hash3: "abc456..."
           ↑ ต่างตรงนี้ → return false — ใช้เวลา 4 byte comparisons (นานกว่า hash2!)
```

attacker วัด response time ได้ — ยิ่ง response นานขึ้น แปลว่า prefix ตรงกันมากขึ้น
ทำซ้ำหลายพันครั้ง statistical analysis เปิดเผย hash ทีละ byte ได้

**Constant-time comparison:**
```go
import "crypto/subtle"

// ✅ ใช้เวลาเท่ากันไม่ว่า byte ไหนจะต่างกัน
subtle.ConstantTimeCompare([]byte(hash1), []byte(hash2))

// ❌ early-exit — leaks timing info
hash1 == hash2
bytes.Equal([]byte(hash1), []byte(hash2))
```

`subtle.ConstantTimeCompare` compare ทุก byte เสมอ — ไม่ early exit — เวลาเท่ากันเสมอ

**bcrypt กับ timing:**
`bcrypt.CompareHashAndPassword` ใช้ `subtle.ConstantTimeCompare` ภายใน
เมื่อใช้ bcrypt verify ไม่ต้อง implement constant-time เอง — library ทำให้แล้ว

## bcrypt 72-Byte Limit

bcrypt ใช้ Blowfish cipher ที่รับ key ได้สูงสุด 448 bits = 56 bytes
แต่ bcrypt implementation ส่วนใหญ่ (รวมถึง Go) รับ 72 bytes (576 bits) แล้วตัดส่วนเกิน

**ปัญหา:**
```
password1: "a" × 72 + "bcdef"  → hash เดียวกับ "a" × 72
password2: "a" × 72            → hash เดียวกัน!
```

password ที่ต่างกันอาจมี hash เหมือนกัน ถ้าส่วนที่แตกต่างอยู่เกิน 72 bytes

**วิธีแก้:**
```go
// ✅ reject ก่อนส่ง bcrypt
if len(password) > 72 {
    return fmt.Errorf("HashPassword: password exceeds maximum length of 72 bytes")
}

// อีกวิธี (ถ้าต้องการรองรับ password ยาว): pre-hash ด้วย SHA256 ก่อน
// แต่ต้องระวัง null byte ใน SHA256 output กับ bcrypt implementation บางตัว
```

ในทางปฏิบัติ user แทบไม่มี password ยาวกว่า 72 bytes — reject พร้อม error message ชัดเจนดีที่สุด

## Password ใน Production

**อย่า store plain text ใดๆ ทั้งสิ้น:**
- ไม่มี excuse — แม้แต่ "prototype", "internal tool", "just for testing"
- ถ้าใช้ OAuth / SSO ทั้งหมด → ไม่มี password ให้ hash ก็ไม่มีปัญหา

**Algorithm ที่แนะนำ (2024+):**
- `bcrypt` (cost 12+) — mature, well-tested, ใช้กันกว้างขวาง ✅
- `argon2id` — memory-hard, resistant to GPU + ASIC attack, แนะนำสำหรับ new system ✅
- `scrypt` — memory-hard แต่ argon2id ดีกว่า
- `PBKDF2-SHA256` — ใช้ได้แต่ไม่ memory-hard, crack ด้วย GPU ได้ดีกว่า bcrypt/argon2

**อย่าประดิษฐ์ใหม่:**
ใช้ library ที่ proven แล้ว — `golang.org/x/crypto/bcrypt` หรือ `golang.org/x/crypto/argon2`
ห้าม implement hashing algorithm เอง ไม่ว่าจะมั่นใจแค่ไหน
