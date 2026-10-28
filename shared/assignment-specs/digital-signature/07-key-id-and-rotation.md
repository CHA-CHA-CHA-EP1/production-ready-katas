---
tier: digital-signature
difficulty: 3
concepts: [key-rotation, key-id, keyring, revocation, algorithm-pinning, algorithm-confusion, kid]
---

# Kata 07 — Key ID and Rotation

## Context

ระบบที่ใช้ private key เดียว hardcode มีปัญหาเมื่อต้องการ:

1. **Key rotation**: เปลี่ยน key ใหม่โดยไม่ทำให้ signature เก่า (ที่ยังอยู่ใน validity window) ใช้ไม่ได้
2. **Key compromise**: revoke key ที่ถูก compromise โดยไม่ต้อง reject signature ที่สร้างก่อนหน้า
3. **Algorithm migration**: เปลี่ยนจาก algorithm เก่า (เช่น RSA-2048) ไป Ed25519 แบบ gradual

Key ID (kid) แก้ปัญหาเหล่านี้ด้วยการทำให้ verifier รู้ว่าต้องใช้ public key ไหนในการ verify signature นี้ — โดยไม่ต้องลอง trial-and-error กับทุก key ใน keyring

แต่ **มีกับดักสำคัญ**: ถ้า signer ฝัง algorithm ไว้ใน signature blob แล้ว verifier เชื่อ algorithm จาก blob นั้น — attacker สามารถทำ algorithm confusion ได้ (เหมือน JWT `alg: none`)

## Real World Incidents

### JWT Algorithm Confusion (2015-2016, documented)

Server ที่ verify JWT ด้วย RS256 (RSA + SHA-256) ถูก trick ให้ accept token ที่ sign ด้วย HS256 (HMAC + SHA-256) โดยใช้ public key เป็น HMAC secret เพราะ server เชื่อ `alg` header จาก token แทนที่จะ pin algorithm ที่ตัวเองคาดหวัง

> ดู [`jwt.md`](../../concepts/jwt.md) สำหรับรายละเอียด — authentication/kata-06 ก็ cover ประเด็นนี้

### Rotation Outage (Plausible scenario)

ระบบ microservice ใช้ public key เดียวที่ hardcode ใน config ของทุก service เมื่อ security team ต้องการ rotate key (เพราะ private key อยู่บน server ที่ถูก decommission) พบว่าต้องอัปเดต config ทุก service พร้อมกัน ในช่วง transition มี window ที่ service บางตัวใช้ key ใหม่ บางตัวใช้ key เก่า ทำให้ requests ล้มเหลวสุ่ม

ระบบที่มี keyring รองรับ multiple public keys ตาม kid จะทำ rotation ได้แบบ zero-downtime

## The Naive Way

```go
// naive: hardcode public key + trust algorithm from signature blob
type Signature struct {
    Algorithm string `json:"alg"` // ← attacker ควบคุม field นี้ได้
    KeyID     string `json:"kid"` // OK ถ้าใช้แค่ lookup
    Value     []byte `json:"sig"`
}

func verify(sig Signature, msg []byte) bool {
    pub := getKey(sig.KeyID)
    switch sig.Algorithm { // ← trust algorithm from signature = DANGER
    case "ed25519":
        return ed25519.Verify(pub.(ed25519.PublicKey), msg, sig.Value)
    case "hmac-sha256":
        // ถ้า pub ถูก cast เป็น hmac key... algorithm confusion attack
        ...
    }
}
```

## Explore First

อ่าน documentation ก่อน:

- `crypto/ed25519` — `ed25519.PublicKey` เป็น type อะไร?
- `encoding/json` — JSON marshal/unmarshal สำหรับ `[]byte` (base64 auto-encoding)
- `sync` — `sync.RWMutex` สำหรับ thread-safe keyring

คำถามชี้นำ:
- "Algorithm pinning" หมายความว่าอะไร? ต่างจาก "trust alg from blob" อย่างไร?
- kid ควรถูก generate อย่างไร? (hint: `crypto/rand`, hex encoding, หรือ sha256 ของ public key bytes)
- "Revoked key" แตกต่างจาก "deleted key" อย่างไรในแง่ audit?
- ถ้า key ถูก revoke แล้ว signature เก่าที่สร้างด้วย key นั้น ควร valid หรือไม่? — ขึ้นอยู่กับ policy อะไร?
- Keyring ที่ thread-safe ต้องใช้ synchronization primitive อะไร?

ห้ามดู example ก่อนลองคิดเอง

## Task

```go
type KeyStatus string
const (
    KeyStatusActive  KeyStatus = "active"
    KeyStatusRevoked KeyStatus = "revoked"
)

type KeyEntry struct {
    KeyID     string
    PublicKey ed25519.PublicKey
    Status    KeyStatus
    CreatedAt time.Time
    RevokedAt *time.Time // nil ถ้ายังไม่ revoke
}

type Keyring struct {
    // thread-safe map จาก keyID → KeyEntry
}
```

เขียนฟังก์ชัน:

```go
// เพิ่ม key ใหม่ใน keyring (status = active)
func (kr *Keyring) AddKey(entry KeyEntry) error

// Mark key เป็น revoked (ไม่ลบ — ยังเก็บไว้สำหรับ audit)
func (kr *Keyring) RevokeKey(keyID string) error

// Verify signature โดย lookup kid จาก keyring
// Algorithm ถูก pin ที่ Ed25519 เสมอ — ไม่รับ algorithm จาก parameter ภายนอก
// Return error ถ้า key ไม่เจอ, revoked, หรือ signature ไม่ valid
func (kr *Keyring) Verify(keyID string, message, sig []byte) error
```

เขียนฟังก์ชัน sign ที่ embed kid:

```go
type SignedBlob struct {
    KeyID   string `json:"kid"`
    // หมายเหตุ: ไม่มี "alg" field — algorithm ถูก pin ที่ verifier ไม่ใช่ที่ blob
    Message []byte `json:"msg"`
    Sig     []byte `json:"sig"`
}

func Sign(priv ed25519.PrivateKey, keyID string, message []byte) SignedBlob
func (kr *Keyring) VerifyBlob(blob SignedBlob) error
```

เขียน test:
1. Sign + verify ด้วย active key → pass
2. Verify ด้วย revoked key → error "key revoked"
3. Verify ด้วย kid ที่ไม่มีใน keyring → error "key not found"
4. Sign ด้วย key A, verify ด้วย kid ของ key B → error (signature invalid)
5. Rotation scenario: add key2, revoke key1, verify signature เก่า (สร้างด้วย key1) → fail เพราะ key1 revoked

## Requirements

- `Keyring.Verify()` ต้อง pin algorithm เป็น Ed25519 เสมอ — ไม่รับ algorithm string จาก caller หรือจาก blob
- `RevokeKey` ต้อง set `RevokedAt` timestamp — ห้ามลบ key ออกจาก keyring
- KeyID ต้องเป็น random หรือ derived value — ห้ามใช้ sequential integer (1, 2, 3)
- `Keyring` ต้อง thread-safe (ทดสอบด้วย `-race` flag)

## Acceptance Criteria

- [ ] Sign + verify active key → nil
- [ ] Verify revoked key → error ที่ mention "revoked"
- [ ] Verify unknown kid → error ที่ mention "not found"
- [ ] Wrong key pair → error
- [ ] Rotation: add key2, revoke key1, VerifyBlob ด้วย key1 → error
- [ ] ไม่มี algorithm string ใน `SignedBlob` struct
- [ ] `go test -race ./...` ผ่าน (ทดสอบ concurrent access บน Keyring)
- [ ] `RevokedAt` ถูก set เมื่อ revoke — ไม่ใช่ nil

## Concepts Involved

- **Key ID (kid)**: identifier ที่ bind signature กับ specific key — ช่วย rotation และ multi-key support
- **Algorithm pinning**: verifier pin algorithm ที่ตัวเองยอมรับ — ไม่ trust algorithm จาก untrusted input
- **Key revocation**: mark key เป็น invalid โดยไม่ลบ — preserve audit trail
- **Keyring**: collection ของ trusted public keys พร้อม metadata
- **Thread safety**: concurrent signature verification ต้องใช้ proper synchronization

## Production Reality

ในระบบจริง:

- **JWKS (JSON Web Key Set)**: standard format สำหรับ publish keyring ผ่าน HTTP endpoint — ดู `jwt.md`
- **Key rotation policy**: rotate ทุก 90 วัน (หรือตาม compliance) + immediate rotation เมื่อ compromise suspected
- **Signature timestamp + revocation**: ถ้า key ถูก revoke หลังจาก signature ถูกสร้าง — policy ต้องกำหนดว่า signature นั้น valid หรือไม่ (trusted timestamp ช่วยได้ — ดู kata 08 และ scenario S3)
- **KMS**: ใน production AWS KMS, GCP KMS จัดการ key lifecycle ให้ — ไม่ต้อง implement keyring เอง (ดู kata 26)

สิ่งที่ Kata นี้สอน: **pin algorithm, never trust alg from blob** — และ rotation ต้องออกแบบตั้งแต่แรก
