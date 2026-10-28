---
tier: digital-signature
difficulty: 1
concepts: [integrity, authenticity, sha256, hash, digital-signature, trust-model]
---

# Kata 01 — Checksum Is Not Authentication

## Context

เวลา download ซอฟต์แวร์หรือไฟล์สำคัญ หลายองค์กรให้ผู้ใช้ตรวจ SHA-256 checksum เพื่อยืนยันว่าไฟล์ไม่เสียหาย — แต่มี **ข้อสมมติที่ซ่อนอยู่** ที่วิศวกรส่วนใหญ่มองข้าม

Hash พิสูจน์ได้แค่ว่า **ไฟล์ที่คุณได้รับตรงกับไฟล์ที่ระบุใน checksum file** เท่านั้น
แต่ไม่สามารถพิสูจน์ได้ว่า **checksum file นั้นมาจากแหล่งที่คุณเชื่อถือ**

Kata นี้สอนให้เห็นช่องว่างระหว่าง integrity กับ authenticity — และทำไม digital signature ถึงเป็น solution ที่ถูกต้อง

## Real World Incidents

### Linux Mint Website Compromise (กุมภาพันธ์ 2016)

ผู้โจมตีใช้ช่องโหว่ใน WordPress ของเว็บไซต์ linuxmint.com เข้าถึง web server ได้ จากนั้นเปลี่ยน download link ให้ชี้ไปยัง server ของตัวเองที่โฮสต์ ISO ที่ฝัง backdoor (Tsunami botnet)

**ประเด็นสำคัญ:** เมื่อผู้โจมตีควบคุม server ได้ พวกเขาควบคุม**ทั้ง** ไฟล์ที่ให้ download **และ** checksum ที่แสดงบนหน้าเว็บเดียวกัน — การตรวจ SHA-256 จากหน้าเว็บเดียวกันจึงไม่สามารถตรวจจับการโจมตีได้

Linux Mint ให้ GPG-signed checksum ไว้แยกต่างหาก แต่ไม่ได้ถูก emphasize อย่างชัดเจน การโจมตีนี้จึงทำให้ทีม Linux Mint ต้องปรับ workflow การ verify ทั้งหมด

> Source: Official Linux Mint blog announcement, กุมภาพันธ์ 2016 (blog.linuxmint.com/?p=2994);
> Technical analysis: Micah Lee (micahflee.com/2016/02/backdoored-linux-mint-and-the-perils-of-checksums/)

### การกระจาย Firmware ในองค์กร (Plausible scenario — ไม่ใช่ incident ที่บันทึกไว้)

ทีม IT ขององค์กรหนึ่งแจกจ่าย firmware update ผ่าน internal file share พร้อม `.sha256` file ที่วางไว้ข้างๆ เมื่อ engineer รายหนึ่งนำไฟล์เก่าที่ล้าสมัยมาแทน (โดยไม่ได้ตั้งใจจะโจมตี) เขาก็อัปเดต `.sha256` ไปพร้อมกัน — ระบบ verify ผ่านทั้งหมด แต่ firmware เวอร์ชันเก่าถูกติดตั้งไปหลายเดือน

## The Naive Way

```go
// naive: วาง .sha256 ไว้ข้างๆ ไฟล์บน server เดียวกัน
// "ถ้า hash ตรง แสดงว่าไฟล์ OK"

func verifyFile(filePath, checksumPath string) error {
    data, _ := os.ReadFile(filePath)
    expected, _ := os.ReadFile(checksumPath)

    actual := fmt.Sprintf("%x", sha256.Sum256(data))
    if actual != strings.TrimSpace(string(expected)) {
        return errors.New("checksum mismatch")
    }
    return nil // ✓ แต่... ใครสร้าง checksumPath นี้?
}
```

**ปัญหา:** ถ้าผู้โจมตีแก้ไขทั้ง `filePath` และ `checksumPath` พร้อมกัน ฟังก์ชันนี้จะ return `nil` — ผ่าน verify ทุกครั้ง

## Explore First

ก่อนเขียน code ให้อ่าน:

- `crypto/sha256` — `sha256.New()`, `sha256.Sum256()` ต่างกันอย่างไร?
- `crypto/ed25519` — `ed25519.GenerateKey()`, `ed25519.Sign()`, `ed25519.Verify()` มี signature อย่างไร?
- `encoding/hex` — `hex.EncodeToString()`, `hex.DecodeString()`

คำถามชี้นำ:
- Hash พิสูจน์อะไรได้บ้าง? พิสูจน์อะไรไม่ได้?
- Verify ผ่าน hash เทียบกับ verify ผ่าน signature ต่างกันอย่างไรในแง่ trust model?
- ถ้าผู้โจมตีสามารถแก้ไขทั้งไฟล์และ checksum ได้ มีอะไรที่พวกเขาทำไม่ได้?
- Private key ของ publisher ทำหน้าที่อะไรในโมเดลนี้?

ห้ามดู example ก่อนลอง — อ่าน godoc แล้วคิดเอง

## Task

เขียนฟังก์ชันสองชุด:

```go
// ชุดที่ 1: Hash-based (naive)
func WriteChecksumFile(filePath string) error           // เขียน .sha256 ข้างๆ ไฟล์
func VerifyWithChecksum(filePath, checksumPath string) error

// ชุดที่ 2: Signature-based (correct)
func SignFile(filePath string, priv ed25519.PrivateKey) ([]byte, error)  // return signature bytes
func VerifyFileSignature(filePath string, sig []byte, pub ed25519.PublicKey) error
```

แล้วเขียน demo ที่แสดงให้เห็นว่า:
1. Hash-based verify ผ่านแม้ attacker แก้ทั้งไฟล์และ checksum
2. Signature-based verify **ล้มเหลว** เมื่อ attacker แก้ไฟล์ (แม้สร้าง fake signature ใหม่ได้ เพราะไม่มี private key)

## Requirements

- `SignFile` ต้อง hash ไฟล์ก่อน (`sha256.New()` + streaming) แล้วค่อย sign digest — ห้าม read ไฟล์ทั้งหมดใส่ memory เพื่อ sign โดยตรงผ่าน `ed25519.Sign` (เข้าใจว่าทำไม: เพราะ Ed25519 ต้องการ `[]byte` ทั้งหมด)
- `VerifyFileSignature` ต้อง return error ที่อธิบายได้ ไม่ใช่แค่ `false`
- Demo ต้องพิมพ์ผลลัพธ์ชัดเจนว่า pass/fail พร้อมบอกเหตุผล

## Acceptance Criteria

- [ ] `VerifyWithChecksum` ผ่านเมื่อไฟล์และ checksum ตรงกัน
- [ ] `VerifyWithChecksum` **ผ่านเช่นกัน** เมื่อ attacker เปลี่ยนทั้งไฟล์และ checksum พร้อมกัน (แสดงให้เห็น weakness)
- [ ] `VerifyFileSignature` ผ่านเมื่อ signature ถูกต้อง
- [ ] `VerifyFileSignature` **fail** เมื่อไฟล์ถูกแก้ไข แม้ 1 byte
- [ ] `VerifyFileSignature` **fail** เมื่อ signature ถูกแก้ไข
- [ ] `VerifyFileSignature` **fail** เมื่อใช้ public key ผิดคู่
- [ ] Code ไม่ใช้ `sha256.Sum256()` ใน `SignFile`/`VerifyFileSignature` — ต้องใช้ streaming hash

## Concepts Involved

- **Integrity vs Authenticity**: hash พิสูจน์ integrity; signature พิสูจน์ทั้ง integrity และ origin
- **Trust anchor**: ความแตกต่างระหว่าง "hash ตรง" กับ "hash ตรงและ source เชื่อถือได้"
- **Ed25519**: asymmetric signing algorithm ที่ใช้ใน modern systems (เร็ว, safe-by-default)
- **SHA-256**: cryptographic hash function — one-way, collision-resistant

## Production Reality

ในระบบจริง:

- **Software distribution**: ผู้ publish ใช้ GPG หรือ Sigstore/cosign เพื่อ sign release — ผู้ download verify ด้วย public key ที่ได้จากแหล่งที่ไว้วางใจ (ไม่ใช่จาก server เดิม)
- **Package managers**: `apt`, `npm`, `go mod` ทุกตัวมี signature verification ในตัว — ไม่ได้ใช้แค่ hash
- **Internal systems**: เมื่อ deploy artifact จาก CI/CD ให้ sign ใน build pipeline แล้ว verify ก่อน deploy — hash อย่างเดียวไม่พอถ้า registry ถูก compromise

สิ่งที่ Kata นี้สอน: **checksum เป็น sanity check ไม่ใช่ security control** — ถ้าต้องการ security ต้องใช้ signature
