---
tier: digital-signature
difficulty: 1
concepts: [ed25519, sign, verify, key-pair, tamper-detection, crypto/ed25519]
---

# Kata 02 — Sign and Verify Bytes

## Context

Kata นี้เป็น "hello world" ของ digital signature — เรียนรู้ workflow พื้นฐาน:

1. Generate key pair
2. Sign message
3. Verify signature
4. ทดสอบว่า 1-byte tamper ทำให้ verification ล้มเหลว

เป้าหมายคือสร้าง intuition ที่ถูกต้องก่อนไปยัง kata ที่ซับซ้อนกว่า — โดยเฉพาะความเข้าใจว่า `Verify()` return value ต้องถูก **handle อย่างจริงจัง** ไม่ใช่แค่ ignore

## Real World Incidents

### การ Ignore Return Value ของ Verify (Plausible scenario — ไม่ใช่ incident ที่บันทึกไว้)

ในการ audit codebase ของ internal tool บริษัทแห่งหนึ่ง พบโค้ดลักษณะนี้:

```go
ed25519.Verify(pub, msg, sig)  // ← return value ไม่ถูกเก็บ
// ดำเนินการต่อเสมอ...
processDocument(msg)
```

Developer เข้าใจผิดว่า verify แล้วจะ "panic ถ้าผิด" — แต่ `ed25519.Verify()` แค่ return `bool` — ไม่ panic, ไม่ error
ผลคือ tampered document ถูก process ต่อโดยที่ไม่มีใครรู้

### OpenSSL CVE-2016-7052 / Signature Malleability Issues

ใน implementation ที่ไม่ถูกต้อง การ verify ที่ "ผ่าน" อาจไม่ได้หมายความว่า signature ถูกต้อง — ขึ้นอยู่กับว่า library handle edge case (เช่น all-zero signature, oversized input) อย่างไร

Go's `crypto/ed25519` ถูก implement อย่างระมัดระวัง แต่ developer ยังต้องรับผิดชอบในการ check return value และไม่ใช้ hand-rolled implementation

## The Naive Way

```go
// naive: sign แต่ไม่ verify — หรือ verify แต่ไม่สนใจผล

func processSignedData(pub ed25519.PublicKey, msg, sig []byte) {
    ed25519.Verify(pub, msg, sig)  // ← ลืม check return value!
    process(msg)  // ดำเนินการกับ tampered data โดยไม่รู้
}
```

```go
// naive: hand-rolled signing (อย่าทำ)
func mySign(key []byte, data []byte) []byte {
    h := sha256.Sum256(append(key, data...))
    return h[:]  // ← ไม่ใช่ digital signature จริงๆ
}
// ปัญหา: ใครที่รู้ key ก็ verify ได้ → ไม่ใช่ asymmetric
// ปัญหา: ใครที่รู้ key ก็ sign ได้เหมือนกัน → ไม่มี private key concept
```

## Explore First

อ่าน documentation ก่อน:

- `crypto/ed25519` — `GenerateKey`, `Sign`, `Verify`, `VerifyWithOptions`
  - `GenerateKey(rand io.Reader)` — ใช้ `nil` ได้ไหม?
  - `Sign(privateKey, message)` — return อะไร?
  - `Verify(publicKey, message, sig)` — return อะไร? panic เมื่อไหร่?
- `crypto/rand` — `rand.Reader` คืออะไร?

คำถามชี้นำ:
- `ed25519.Verify()` return `bool` — ต่างจาก `error` อย่างไรในการ design?
- ถ้า message ยาว 1 MB แต่ signature ยาวแค่ 64 bytes เป็นไปได้อย่างไร?
- ทำไมถึงต้องส่ง `message` ให้ `Verify()` ด้วย ทั้งที่ signature "มี" ข้อมูลนั้นอยู่แล้ว?
- Public key ขนาด 32 bytes ปลอดภัยได้อย่างไร? (hint: elliptic curve)

ห้ามดู example ก่อนลองคิดเอง

## Task

เขียนฟังก์ชัน:

```go
// Sign message ด้วย private key; return signature
func Sign(priv ed25519.PrivateKey, message []byte) []byte

// Verify signature; return nil ถ้า valid, error ถ้า invalid
func Verify(pub ed25519.PublicKey, message, sig []byte) error
```

แล้วเขียน test/demo ที่ครอบคลุม:

1. **Happy path**: sign แล้ว verify → pass
2. **Tampered message**: เปลี่ยน byte ตำแหน่งกลางของ message → fail
3. **Last byte tamper**: เปลี่ยน byte สุดท้ายของ message → fail
4. **Tampered signature**: เปลี่ยน 1 byte ใน signature → fail
5. **Wrong key pair**: verify ด้วย public key ของ key pair อื่น → fail

## Requirements

- `Verify` ต้อง return `error` ที่มี message อธิบาย — ไม่ใช่แค่ wrap `false`
- ห้ามใช้ `if !ed25519.Verify(...)` แล้วไม่ทำอะไรกับผล — ต้อง propagate error
- ห้าม implement signing algorithm เอง — ใช้ `crypto/ed25519` จาก stdlib
- Key generation ต้องใช้ `crypto/rand` — ห้ามใช้ `math/rand` หรือ hardcode key
- Demo ต้องพิมพ์ผลลัพธ์แต่ละ case ชัดเจน (PASS/FAIL พร้อมเหตุผล)

## Acceptance Criteria

- [ ] Happy path: `Verify()` return `nil`
- [ ] Tampered message (ทุก position ที่ test): `Verify()` return error
- [ ] Tampered signature (1 byte): `Verify()` return error
- [ ] Wrong public key: `Verify()` return error
- [ ] `Verify` ไม่ panic ใน 5 test cases ข้างต้น
- [ ] ไม่มี `ed25519.Verify()` call ที่ return value ถูก discard (ตรวจด้วย static analysis หรือ code review)
- [ ] Key generation ใช้ `crypto/rand` เสมอ

## Concepts Involved

- **Asymmetric key pair**: private key sign, public key verify — สองคนละบทบาท
- **Ed25519**: Edwards-curve digital signature algorithm — 32-byte public key, 64-byte signature
- **Signature as commitment**: signature ผูก message กับ private key — เปลี่ยนอย่างใดอย่างหนึ่งทำให้ signature ไม่ valid
- **Defensive programming**: return value ของ security function ต้อง handle เสมอ

## Production Reality

ในระบบจริง:

- **ใช้ high-level library**: เช่น `golang.org/x/crypto/nacl/sign` หรือ library ที่มี API ที่บังคับให้ verify ก่อน process — ลด chance ของ "forget to verify"
- **Sign message ที่มี context**: message ควรมี domain/purpose binding ไม่ใช่แค่ raw bytes (ดู kata 05)
- **Ed25519 ใน production**: ใช้กันแพร่หลายใน SSH keys, TLS 1.3, JWT (EdDSA), Sigstore
- **`Verify()` return `bool`**: ใน Go stdlib เป็น design choice ที่ถกเถียงได้ — ใน library อื่นเช่น `nacl/sign` จะ return `([]byte, bool)` ซึ่งบังคับให้ handle

สิ่งที่ Kata นี้สอน: **Verify ก่อน process เสมอ** และ return value ของ security check ห้าม ignore
