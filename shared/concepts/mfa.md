# Concept: Multi-Factor Authentication (MFA)

## สามปัจจัยของการยืนยันตัวตน

MFA คือการต้องการหลักฐานอย่างน้อยสองประเภทจากสามประเภทนี้:

| Factor | คืออะไร | ตัวอย่าง |
|--------|---------|---------|
| **Something you know** | ความรู้ที่เฉพาะตัว | Password, PIN, security question |
| **Something you have** | วัตถุที่ครอบครอง | Phone (TOTP app), hardware key (YubiKey), smart card |
| **Something you are** | ลักษณะทางชีวภาพ | Fingerprint, Face ID, iris scan |

การรวม factor สองประเภทที่แตกต่างกัน = MFA ที่แท้จริง
Password + security question = ยังเป็น single factor (both "something you know") ไม่ใช่ MFA

---

## TOTP Algorithm (RFC 6238)

TOTP (Time-based One-Time Password) สร้าง 6-digit code ที่เปลี่ยนทุก 30 วินาที

### ขั้นตอนการคำนวณ

```
1. ตกลงกัน: server และ phone มี shared secret เดียวกัน (base32 string เช่น "JBSWY3DPEHPK3PXP")

2. คำนวณ counter จากเวลา:
   counter = floor(unix_timestamp / 30)
   เช่น timestamp = 1700000060 → counter = floor(1700000060/30) = 56666668

3. HMAC-SHA1(secret_bytes, counter_as_8_byte_big_endian):
   hmac_result = HMAC-SHA1(secret, counter) → 20 bytes

4. Dynamic truncation (เลือก 4 bytes จาก 20 bytes):
   offset = hmac_result[19] & 0x0F  (เอา 4 bits สุดท้ายของ byte สุดท้าย)
   code_bytes = hmac_result[offset:offset+4]
   code_int = (code_bytes[0] & 0x7F) << 24 | code_bytes[1] << 16 | code_bytes[2] << 8 | code_bytes[3]

5. Truncate เป็น 6 หลัก:
   totp_code = code_int % 1_000_000
   → "847392" (zero-padded ถ้าสั้นกว่า 6 หลัก: "047392")
```

### ทำไม HMAC-SHA1 ถึง "พอ" สำหรับ TOTP

SHA1 มีช่องโหว่ใน collision resistance แต่ TOTP ใช้ HMAC-SHA1 ไม่ใช่ SHA1 ตรงๆ
HMAC ใช้ secret key ทำให้ collision attack ไม่ applicable — attacker ต้องรู้ key ถึงจะ forge ได้
RFC 6238 เลือก HMAC-SHA1 เพราะ compatible กับ hardware token รุ่นเก่า (ที่มี compute จำกัด)
algorithm ที่ใหม่กว่าอย่าง HMAC-SHA256 ก็ supported ใน library สมัยใหม่

---

## Time Window และ Clock Skew

### ปัญหา: นาฬิกาไม่ตรงกัน

```
server time:  12:00:00.000
phone time:   11:59:52.000  (phone ช้ากว่า 8 วินาที)

counter (server) = floor(43200 / 30) = 1440   → expects code for window 1440
counter (phone)  = floor(43192 / 30) = 1439   → generates code for window 1439

→ code ที่ user พิมพ์ไม่ตรงกับที่ server expect!
```

### วิธีแก้: อนุญาต ±1 Window

```go
// totp.ValidateCustom ใน pquerna/otp:
opts := totp.ValidateOpts{
    Skew: 1,  // อนุญาต 1 window ก่อนหน้าและหลังจาก current window
}
// → accept codes จาก 3 windows รวม: t-30s, t, t+30s
```

```
ถ้า current time = 12:00:15 (อยู่ใน window 1440: 12:00:00-12:00:29):

Skew=0: accept เฉพาะ window 1440 (code valid 12:00:00-12:00:29 เท่านั้น)
Skew=1: accept windows 1439, 1440, 1441 (code valid 11:59:30-12:01:00)
Skew=2: accept windows 1438-1442 (±60s — กว้างเกินไป เพิ่ม replay risk)
```

**ทำไม Skew=1 เป็นค่าที่เหมาะสม:**
- Clock drift ของ phone ปกติไม่เกิน 15-20 วินาที
- ±30s (Skew=1) ครอบคลุม drift ทั่วไปได้สบาย
- ±60s (Skew=2) เพิ่ม replay attack window ให้ attacker มากเกินไป

---

## Backup Codes

### วัตถุประสงค์

เมื่อผู้ใช้ทำ phone หาย, TOTP app เสีย, หรือ MFA device ไม่สามารถเข้าถึงได้
backup codes ช่วยให้ผู้ใช้ยังสามารถ login เข้า account และ re-setup MFA ได้

### Design ที่ถูกต้อง

**1. Single-use: แต่ละ code ใช้ได้ครั้งเดียวเท่านั้น**

```go
// เมื่อ verify backup code:
func UseBackupCode(userID string, inputCode string) error {
    codes := db.GetBackupCodes(userID)  // ดึง hashed codes ทั้งหมดที่ยังไม่ถูกใช้

    for _, code := range codes {
        if sha256.Sum256([]byte(inputCode)) == code.Hash {
            // ✅ ใช้ atomic update เพื่อ mark as used
            err := db.MarkCodeUsed(code.ID)
            if err != nil {
                return err
            }
            return nil  // สำเร็จ
        }
    }
    return ErrInvalidBackupCode
}
```

**2. Hashing: เก็บ hash ไม่ใช่ plaintext**

```go
// Generate:
plainCode := generateRandomCode()  // เช่น "XKCD4F7Z2Q"
hash := sha256.Sum256([]byte(plainCode))
db.StoreBackupCode(userID, hex.EncodeToString(hash[:]))
// แสดง plainCode ให้ user ครั้งเดียวแล้วลืมทิ้ง

// Verify:
inputHash := sha256.Sum256([]byte(userInput))
stored := db.GetBackupCodeHash(codeID)
// constant-time comparison!
if subtle.ConstantTimeCompare(inputHash[:], storedHash) == 1 {
    // valid
}
```

**ทำไมใช้ SHA-256 แทน bcrypt:**
- bcrypt ออกแบบมาสำหรับ password ซึ่งมี entropy ต่ำ (คนมักใช้ predictable password)
- Backup code ที่ generate randomly มี entropy สูงมาก: 10 chars alphanumeric = log2(36^10) ≈ 51.7 bits
- ด้วย entropy ระดับนี้ SHA-256 เพียงพอ — cost function ของ bcrypt ไม่จำเป็น
- SHA-256 เร็วกว่า bcrypt มาก ไม่ทำให้ login ช้า

**3. จำนวนและ format**

```
จำนวน: 8-10 codes (พอสำหรับหลายสถานการณ์ฉุกเฉิน แต่ไม่มากจนผู้ใช้ประมาทเลินเล่อ)
Format: ตัวอักษร uppercase + ตัวเลข, ยาว 8-10 chars, แบ่งเป็นกลุ่มอ่านง่าย
ตัวอย่าง: "XKCD-4F7Z" หรือ "ABCD1234" (หลีกเลี่ยง O, 0, I, 1 ที่สับสนกัน)
```

---

## MFA Fatigue Attack

### ทำงานอย่างไร (Push Notification MFA)

```
1. attacker มี password ของ victim (จาก breach อื่น หรือ phishing)
2. attacker พยายาม login → system ส่ง push notification ไปยัง phone ของ victim
3. victim เห็น notification แต่ไม่ได้พยายาม login → กด "Deny"
4. attacker retry ซ้ำๆ ส่ง push notification ทุกไม่กี่นาที
5. victim เหนื่อย หรือคิดว่าเป็น bug หรือโดนรบกวนตอนนอน → กด "Approve" เพื่อให้หยุด
6. attacker เข้า account ได้
```

### ทำไม TOTP ป้องกัน Fatigue Attack ได้ดีกว่า

| MFA Type | Fatigue Attack | เหตุผล |
|----------|----------------|--------|
| Push Notification | เสี่ยง | User แค่กด Approve — passive action |
| TOTP | ป้องกันได้ | User ต้องเปิด app อ่าน code แล้วพิมพ์ — active, intentional action |
| Hardware Key | ป้องกันได้มากกว่า | ต้องมี physical key present + touch |

**Mitigation สำหรับ Push MFA:**
- Number matching: แสดงตัวเลข 2 หลักบนหน้า login, push notification ถามว่า "กด X ถ้าตัวเลขนี้ตรงกัน" — attacker ไม่รู้ตัวเลขที่ถูก
- Rate limiting: จำกัดจำนวน push ที่ส่งต่อ session
- หลัง N denials: block account ชั่วคราว

---

## SMS vs TOTP vs Hardware Key

### เปรียบเทียบ

| | SMS OTP | TOTP (App) | FIDO2/WebAuthn (Hardware Key) |
|--|---------|-----------|-------------------------------|
| **Security** | ต่ำ-กลาง | กลาง-สูง | สูงมาก |
| **Phishing resistant** | ไม่ | ไม่ (real-time phishing ดัก code ได้) | ใช่ (key bound to origin) |
| **SIM swap resistant** | ไม่ | ใช่ | ใช่ |
| **MFA fatigue resistant** | ไม่ (รับรหัส SMS แล้วพิมพ์ = ง่ายเกินไป) | บางส่วน | ใช่ |
| **Device loss recovery** | ง่าย (SIM) | กลาง (backup codes) | ยาก (ต้องมี spare key) |
| **User adoption** | สูงมาก | สูง | ต่ำ |
| **Cost** | สูง (per SMS) | ฟรี | ~$25-50 ต่อ key |

### SIM Swap Attack

```
1. attacker โทรไปยัง mobile carrier แอบอ้างว่าเป็น victim
2. ขอ transfer SIM ไปยัง SIM ใหม่ (แก้ตัวว่าโทรศัพท์หายหรือเสีย)
3. carrier ย้าย number ไปยัง SIM ของ attacker
4. SMS OTP ถูกส่งไปยัง phone ของ attacker
5. attacker เข้า account ได้

เหยื่อที่โดน SIM swap มักมีเหตุผล: celebrities, crypto holders, ผู้ใช้ที่มีหมายเลขนาน
```

TOTP และ hardware key ป้องกัน SIM swap ได้ เพราะไม่พึ่ง phone number

---

## ตัวเลขที่ควรรู้

**Microsoft (2019) :** MFA ป้องกัน account takeover ได้ **99.9% ของ automated attacks**

**Google (2019):** เพิ่ม recovery phone number = ป้องกัน bot attacks ได้ 100%, phishing 66%, targeted attacks 76%

**Verizon DBIR 2023:** 74% ของ breaches ที่เกี่ยวกับ human element — credential theft, phishing, misuse
MFA ป้องกันได้มากถ้า deploy อย่างถูกต้อง

**CISA:** MFA เป็น "Cybersecurity Performance Goal" ที่สำคัญที่สุดสำหรับ critical infrastructure

---

## Implementation Checklist

```
Setup MFA:
  ✓ Generate cryptographically random secret (≥160 bits สำหรับ TOTP)
  ✓ QR code URL ใน otpauth:// format ที่ authenticator app parse ได้
  ✓ Verify user สแกน QR แล้ว ก่อน enable MFA (ให้กรอก code ยืนยัน)
  ✓ Generate backup codes และแสดงครั้งเดียว
  ✓ เก็บ secret และ hashed backup codes ใน DB — ไม่เก็บ plaintext backup codes

Verify MFA:
  ✓ ±1 window สำหรับ clock skew (Skew=1)
  ✓ Rate limit: max 5 attempts ต่อ user ต่อ 5 นาที
  ✓ Log failed attempts (ไม่ log code ที่ user กรอก)

Backup codes:
  ✓ Single-use: mark as used atomically หลัง verify สำเร็จ
  ✓ Hash ด้วย SHA-256 + constant-time comparison
  ✓ แสดงให้ user ครั้งเดียวตอน setup เท่านั้น

Disable MFA:
  ✓ Require sudo mode (re-authentication) ก่อน disable
  ✓ Invalidate backup codes ทั้งหมดเมื่อ MFA ถูก disable
  ✓ Send email notification เมื่อ MFA ถูก disable
```
