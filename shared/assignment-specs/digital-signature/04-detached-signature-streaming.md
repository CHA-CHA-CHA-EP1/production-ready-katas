---
tier: digital-signature
difficulty: 2
concepts: [streaming, detached-signature, sha256, io.Copy, heap, ed25519, large-file]
---

# Kata 04 — Detached Signature for Large Files (Streaming)

## Context

Kata 01 และ 02 ทำงานกับ `[]byte` ในหน่วยความจำ — ใช้ได้สำหรับ message เล็กๆ แต่ถ้าต้องการ sign ไฟล์ขนาด 2 GB (เช่น database backup, medical imaging, video) การ load ทั้งไฟล์เข้า RAM ก่อน sign จะทำให้ process ล่มหรือ OOM

Kata นี้สอน:
1. ทำไม Ed25519 ถึงต้องการ full message ใน memory — และ workaround ที่ถูกต้อง
2. Sign/verify large file โดยใช้ memory **O(1)** ผ่าน streaming hash
3. Detached signature format — `.sig` file แยกจากไฟล์ต้นฉบับ

## Real World Incidents

### OOM ระหว่าง Signing Backup ใหญ่ (Plausible scenario)

ระบบ backup ของโรงพยาบาลแห่งหนึ่ง (ข้อมูลสังเคราะห์) ใช้ฟังก์ชัน sign ที่รับ `[]byte` ทำงานได้ดีกับ file < 100 MB แต่เมื่อ backup database เติบโตเป็น 8 GB พบว่า signing process ใช้ RAM พุ่งขึ้น 8 GB แล้ว OOM kill ก่อนที่จะ sign เสร็จ ผลคือ backup ที่ไม่มี signature ถูก offload ขึ้น storage — และ verification step ล้มเหลวทั้งหมด

ทีม dev แก้โดยเปลี่ยนไป stream hash ก่อน แล้ว sign เฉพาะ digest — ใช้ RAM คงที่ไม่ว่าไฟล์จะใหญ่แค่ไหน

### Naming Collision ของ .sig File (Plausible scenario)

ระบบ sign ไฟล์แล้วเขียน signature เป็น `{filename}.sig` โดยไม่ตรวจว่า `.sig` มีอยู่แล้วหรือเปล่า เมื่อ sign ไฟล์เดิมซ้ำ signature เก่าถูก overwrite โดยไม่มี warning ทำให้ audit trail ขาดหาย

## The Naive Way

```go
// naive: load ทั้งไฟล์เข้า memory ก่อน sign
func signFile(path string, priv ed25519.PrivateKey) ([]byte, error) {
    data, err := os.ReadFile(path)  // ← 8 GB file = 8 GB RAM
    if err != nil {
        return nil, err
    }
    return ed25519.Sign(priv, data), nil  // ← Ed25519 ต้องการ full []byte
}
```

**ปัญหา:**
- File 8 GB → ต้องการ RAM ≥ 8 GB สำหรับ operation นี้เพียงอย่างเดียว
- บน server ที่มี RAM 4 GB → process crash
- ถ้ามีหลาย concurrent sign operation → RAM พุ่งหลายเท่า

## Explore First

อ่าน documentation ก่อน:

- `crypto/sha256` — `sha256.New()` return `hash.Hash`; `hash.Hash` implement `io.Writer`
  - จะ stream ไฟล์เข้า hash ได้อย่างไรโดยไม่ต้อง load ทั้งหมด?
- `io` — `io.Copy(dst io.Writer, src io.Reader)` — ทำอะไร? ใช้ buffer ขนาดเท่าไร?
- `crypto/ed25519` — `ed25519.Sign()` signature เป็นอย่างไร? รับ `[]byte` ขนาดเท่าไร?
  - Ed25519 ต้องการ full message จริงไหม? (อ่าน godoc อย่างละเอียด)
  - ถ้า sign เฉพาะ SHA-256 digest (32 bytes) แทน full message ปลอดภัยไหม?

คำถามชี้นำ:
- `sha256.New()` กับ `sha256.Sum256()` ต่างกันอย่างไรในแง่ streaming?
- ทำไม sign เฉพาะ digest แล้ว attacker จึงแก้ไฟล์ไม่ได้?
- Detached signature (ไฟล์ `.sig` แยก) มีข้อดี/เสียอะไรเทียบกับ embedded?
- ถ้า `.sig` หายไป เกิดอะไรขึ้น? ควร handle อย่างไร?
- `io.Copy` ใช้ buffer ขนาดเท่าไรโดย default? (ดู source หรือ godoc)

ห้ามดู example ก่อนลองคิดเอง

## Task

เขียนฟังก์ชัน:

```go
// Sign ไฟล์ขนาดใดก็ได้ โดย:
// 1. Stream hash ไฟล์ผ่าน sha256 โดยไม่ load ทั้งไฟล์
// 2. Sign เฉพาะ digest (32 bytes)
// 3. เขียน signature ลงไฟล์ path+".sig"
// Memory usage ต้อง O(1) ไม่ขึ้นกับขนาดไฟล์
func SignFileDetached(path string, priv ed25519.PrivateKey) error

// Verify ไฟล์กับ detached signature โดย:
// 1. อ่าน signature จาก path+".sig"
// 2. Stream hash ไฟล์ต้นฉบับ
// 3. Verify digest กับ signature
// Return nil ถ้า valid, error ถ้าไม่ valid (รวมถึง .sig ไม่มี)
func VerifyFileDetached(path string, pub ed25519.PublicKey) error
```

เขียน benchmark เพื่อพิสูจน์ว่า memory ไม่โตตามขนาดไฟล์:

```go
func BenchmarkSignFile1MB(b *testing.B)   // สร้าง 1 MB temp file
func BenchmarkSignFile100MB(b *testing.B) // สร้าง 100 MB temp file
// heap allocs ต้อง ~เท่ากันทั้งสอง benchmark
```

## Requirements

- `SignFileDetached` ต้อง hash file ผ่าน `sha256.New()` + `io.Copy()` — ห้ามใช้ `os.ReadFile()`
- Signature ต้องเก็บเป็น binary file `{path}.sig` (64 bytes raw Ed25519 signature)
- `VerifyFileDetached` ต้อง return error ที่ชัดเจนถ้า `.sig` ไม่มี (ไม่ใช่ panic หรือ generic error)
- `VerifyFileDetached` ต้อง return error ถ้า signature ขนาดไม่ใช่ 64 bytes (Ed25519 signature size)
- Benchmark ต้องแสดง heap allocations (`-benchmem`) — allocs ต้อง O(1) ไม่ใช่ O(filesize)

## Acceptance Criteria

- [ ] `SignFileDetached` สำเร็จกับ 1-byte file
- [ ] `SignFileDetached` สำเร็จกับ 50 MB file โดยไม่ crash (ทดสอบบนเครื่องที่ RAM จำกัด)
- [ ] `VerifyFileDetached` ผ่านสำหรับ file ที่ sign ถูกต้อง
- [ ] `VerifyFileDetached` fail เมื่อ file content ถูกแก้ 1 byte
- [ ] `VerifyFileDetached` fail เมื่อ `.sig` ถูกแก้ 1 byte
- [ ] `VerifyFileDetached` return ชัดเจน (ไม่ใช่ generic error) เมื่อ `.sig` ไม่มี
- [ ] `BenchmarkSignFile1MB` และ `BenchmarkSignFile100MB` มี heap allocs ต่างกันไม่เกิน 2x (แสดง O(1) memory)
- [ ] ไม่มี `os.ReadFile(path)` หรือ `io.ReadAll(...)` ใน `SignFileDetached`

## Concepts Involved

- **Streaming hash**: `hash.Hash` implement `io.Writer` → ใช้ `io.Copy` hash file โดยไม่ load ทั้งหมด
- **Ed25519 memory requirement**: `ed25519.Sign()` ต้องการ full `[]byte` — workaround คือ sign digest แทน
- **Detached signature**: `.sig` file แยก — ไฟล์ต้นฉบับไม่ถูกแก้ไข
- **O(1) memory**: algorithm ที่ใช้ memory คงที่ไม่ว่า input จะใหญ่แค่ไหน
- **Benchmark vs profiling**: วัด heap allocs ด้วย `testing.B` + `-benchmem`

## Production Reality

ในระบบจริง:

- **ทำไมต้อง hash ก่อน**: ไม่ใช่แค่เรื่อง memory — SHA-256 ก็เป็น commitment ที่ collision-resistant ทำให้ attacker ไม่สามารถหา document อื่นที่มี hash เดียวกันได้
- **Streaming ใน pipeline**: การออกแบบ streaming ตั้งแต่ต้นทำให้ sign ได้ตั้งแต่ data ยัง flow ผ่าน pipe — ไม่ต้องรอ buffer ทั้งหมด
- **`.sig` ใน practice**: `gpg --detach-sign`, `minisign`, `cosign` ทุกตัวใช้ detached signature แบบนี้
- **Signature algorithm selection**: Ed25519 เป็น default ที่ดีสำหรับ new systems — เร็ว, key เล็ก, safe-by-default

สิ่งที่ Kata นี้สอน: **hash ก่อน sign** ไม่ใช่แค่ optimization — เป็น pattern ที่ถูกต้องสำหรับ file signing
