---
tier: digital-signature
difficulty: 1
concepts: [pem, pkcs8, key-storage, file-permissions, secret-management, encoding/pem, crypto/x509]
---

# Kata 03 — Key Storage

## Context

Generate key pair ได้แล้ว แต่ถ้า private key อยู่แค่ใน memory — ทุกครั้งที่ restart process ต้อง generate ใหม่ ซึ่งหมายความว่า signature ทุกอันที่เคยทำด้วย key เดิมจะ verify ไม่ได้อีก

Kata นี้สอนวิธี save/load key pair อย่างปลอดภัย:
- **Format**: PEM + PKCS#8 (มาตรฐาน, ใช้กับทุก tool ได้)
- **File permissions**: private key ต้องเป็น mode `0600` — อ่านได้แค่เจ้าของ
- **Refuse unsafe**: ถ้า file permissions ไม่ถูกต้อง ปฏิเสธการ load

## Real World Incidents

### Private Key ใน Git Repository (Plausible scenario ที่เกิดบ่อยมาก)

Git history scanner เช่น `truffleHog`, `gitleaks` พบ private key ที่ commit ไป Git เกิดขึ้นบ่อยมากในองค์กรทุกขนาด เมื่อ push ขึ้น GitHub/GitLab แม้จะ delete file ในภายหลัง private key ยังอยู่ใน git history ตลอดไป

Pattern ที่พบบ่อย:
```
private_key.pem ← commit โดยตั้งใจ ("just for testing")
.env            ← มี private key ฝังอยู่
config.json     ← hardcode key เพื่อ "ความสะดวก"
```

วิธีป้องกัน: ใช้ `.gitignore` + `pre-commit hook` + scan ใน CI pipeline

### World-Readable Private Key File

บน server production ระบบหนึ่งพบว่า private key ถูก generate ด้วย:

```bash
$ ls -la signing.key
-rw-r--r-- 1 app app 119 Jan  1 00:00 signing.key
# ← 644: ทุก user บนระบบอ่านได้!
```

ทุก process บน server รวมถึง compromised dependency ใดๆ สามารถอ่าน private key ได้โดยตรง

## The Naive Way

```go
// naive: save เป็น raw bytes หรือ base64 ธรรมดา
priv := generateKey()
os.WriteFile("key.bin", []byte(priv), 0644)  // ← สองปัญหา: format ไม่ standard + permissions ผิด

// naive: load โดยไม่ตรวจ permissions
priv, _ := os.ReadFile("key.bin")  // ← ไม่รู้ว่า key ถูก expose ไปหรือยัง
```

```go
// naive: hardcode key ใน source code
const privateKeyHex = "3c4a2b1d..."  // ← อยู่ใน git ตลอดไป
```

## Explore First

อ่าน documentation ก่อน:

- `crypto/x509` — `MarshalPKCS8PrivateKey()`, `ParsePKCS8PrivateKey()`, `MarshalPKIXPublicKey()`, `ParsePKIXPublicKey()`
- `encoding/pem` — `pem.Block`, `pem.Encode()`, `pem.Decode()`
  - `Type` field สำหรับ private key PKCS#8 คืออะไร? (`"PRIVATE KEY"` หรือ `"ED25519 PRIVATE KEY"`?)
  - `pem.Decode()` return อะไรถ้าไม่มี PEM block?
- `os` — `os.Stat()`, `fs.FileMode`, `FileInfo.Mode()`
  - ตรวจ file permissions ได้อย่างไร? (`mode & 0077`)
- `crypto/ed25519` — `ed25519.PrivateKey` เป็น `[]byte` หรือ struct?

คำถามชี้นำ:
- PEM vs DER ต่างกันอย่างไร? (hint: PEM = base64(DER) + header/footer)
- PKCS#8 คืออะไร? ทำไมไม่ save raw bytes ของ private key ตรงๆ?
- `ParsePKCS8PrivateKey()` return `any` — ต้อง type assert อย่างไรเพื่อได้ `ed25519.PrivateKey`?
- File permission `0600` หมายความว่าอะไร? (owner read+write, group none, other none)
- ทำไมต้อง "refuse to load" ถ้า permissions ผิด แทนที่จะแค่ log warning?

ห้ามดู example ก่อนลองคิดเอง

## Task

เขียนฟังก์ชัน:

```go
// Save private key เป็น PEM/PKCS#8 file, permissions 0600
func SavePrivateKey(path string, priv ed25519.PrivateKey) error

// Load private key จาก PEM/PKCS#8 file
// Error ถ้าไม่ใช่ PEM, ถ้าไม่ใช่ PKCS#8 Ed25519, หรือถ้า permissions ไม่ใช่ 0600
func LoadPrivateKey(path string) (ed25519.PrivateKey, error)

// Save public key เป็น PEM/PKIX file (permissions ไม่จำเป็นต้อง restrict)
func SavePublicKey(path string, pub ed25519.PublicKey) error

// Load public key จาก PEM/PKIX file
func LoadPublicKey(path string) (ed25519.PublicKey, error)
```

แล้วเขียน test ที่ครอบคลุม:

1. Save → Load round-trip: key ที่ได้กลับมาต้องเหมือนเดิมทุก bit
2. `LoadPrivateKey` บน file ที่มี permissions `0644` → error
3. `LoadPrivateKey` บน file ที่มี permissions `0640` → error
4. `LoadPrivateKey` บน file ที่มี permissions `0600` → สำเร็จ
5. Load file ที่ไม่ใช่ PEM → error ที่ชัดเจน

## Requirements

- Private key file ต้องมี PEM type `"PRIVATE KEY"` (PKCS#8 standard)
- Public key file ต้องมี PEM type `"PUBLIC KEY"` (PKIX standard)
- `SavePrivateKey` ต้อง set file permissions เป็น `0600` ณ ตอน create file
- `LoadPrivateKey` ต้อง check permissions: ถ้า `mode & 0077 != 0` (มี group หรือ other permission) ให้ return error
- `LoadPrivateKey` ต้อง type assert ผล `ParsePKCS8PrivateKey()` และ return error ถ้าไม่ใช่ `ed25519.PrivateKey`
- Error messages ต้องอธิบายสาเหตุ (เช่น "unsafe file permissions 0644, want 0600")

## Acceptance Criteria

- [ ] `SavePrivateKey` + `LoadPrivateKey` round-trip: loaded key == original key
- [ ] `SavePublicKey` + `LoadPublicKey` round-trip: loaded key == original key
- [ ] Key ที่ load กลับมาใช้ Sign + Verify ได้จริง (end-to-end test)
- [ ] `LoadPrivateKey` บน file permissions `0644` → error ที่ mention permissions
- [ ] `LoadPrivateKey` บน file permissions `0640` → error ที่ mention permissions
- [ ] `LoadPrivateKey` บน file permissions `0600` → สำเร็จ
- [ ] `LoadPrivateKey` บน non-PEM file → error ที่ mention invalid format
- [ ] Private key PEM type เป็น `"PRIVATE KEY"` (ตรวจด้วย `pem.Decode` แล้วดู `block.Type`)

## Concepts Involved

- **PEM format**: base64-encoded DER ที่มี `-----BEGIN TYPE-----` header/footer — human-readable, widely supported
- **PKCS#8**: มาตรฐาน container สำหรับ private key ที่รองรับหลาย algorithm (ต่างจาก PKCS#1 ที่ RSA-only)
- **PKIX**: มาตรฐาน format สำหรับ public key (SubjectPublicKeyInfo)
- **File permissions (Unix mode)**: octal notation, owner/group/other bits
- **Principle of least privilege**: private key ต้องอ่านได้แค่ process เจ้าของเท่านั้น

## Production Reality

ในระบบจริง:

- **File-based key** เหมาะกับ: development, low-risk internal tools, single-server deployment
- **Environment variable**: ดีกว่า file ในบาง deployment model (ไม่มี file บน disk) — แต่ยังต้องระวัง process list leak
- **Secret manager** (AWS Secrets Manager, HashiCorp Vault, GCP Secret Manager): ดีกว่าทั้งคู่สำหรับ production — versioning, rotation, audit log, access control
- **HSM/KMS**: private key ไม่เคยออกจาก hardware — signing ทำใน hardware ด้วย (ดู kata 26)
- **Key rotation**: ต้องมี plan ตั้งแต่แรก — ถ้า private key file เดียว hardcode ทุกที่ rotation จะเจ็บปวดมาก

สิ่งที่ Kata นี้สอน: **format ที่ถูกต้อง + permissions ที่ถูกต้อง** เป็น minimum bar — production ต้องการ secret manager หรือ HSM
