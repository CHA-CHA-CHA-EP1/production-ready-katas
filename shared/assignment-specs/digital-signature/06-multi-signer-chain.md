---
tier: digital-signature
difficulty: 3
concepts: [multi-signature, chain-of-trust, append-only, ordering, tamper-detection, signer-chain]
---

# Kata 06 — Multi-Signer Chain

## Context

เมื่อต้องการลายเซ็นหลายคนบน document เดียวกัน (เช่น ระบบ approval หลายชั้น) มีสองวิธีที่ดูเหมือนใช้ได้:

**วิธีผิด (Naive):** แต่ละคน sign เฉพาะ document เดิม
```
sig1 = Sign(privKey1, hash(doc))
sig2 = Sign(privKey2, hash(doc))
sig3 = Sign(privKey3, hash(doc))
```
ปัญหา: ลบ `sig2` ออกก็ยังมี `sig1` และ `sig3` ที่ valid — ไม่มีทางรู้ว่า `sig2` เคยมีอยู่

**วิธีถูก (Chain):** signer แต่ละคน sign doc + ทุก signature ก่อนหน้า
```
sig1 = Sign(privKey1, hash(doc))
sig2 = Sign(privKey2, hash(doc + sig1))
sig3 = Sign(privKey3, hash(doc + sig1 + sig2))
```
ถ้าลบหรือสลับลำดับ signature ใดๆ — sig ที่ตามมาจะ verify ไม่ผ่าน

## Real World Incidents

### ลายเซ็นที่ถอดออกได้โดยไม่มีใครรู้ (Plausible scenario)

ระบบ procurement ขององค์กรต้องการลายเซ็นสองชั้น: manager + director ก่อน approve purchase order เกิน threshold ระบบ implement โดยให้แต่ละคน sign document เดิม แล้วเก็บ signature list ไว้ใน database

ต่อมาพบว่าคนวงในแก้ database โดยลบ `sig_manager` ออกจาก record หนึ่ง — document นั้นผ่านไปได้โดยมีแค่ director signature เพราะ verification code ตรวจแค่ว่า "มี signature อย่างน้อยหนึ่งอัน"

ถ้าใช้ chain signature — sig_director จะ verify ล้มเหลวทันทีเมื่อ sig_manager ถูกลบ

### PDF Signature Removal Attack (ประเด็นที่บันทึกไว้ใน academic research, 2019)

งานวิจัยจาก Ruhr University Bochum ("PDF Insecurity") แสดงให้เห็นว่า PDF ที่มีลายเซ็น incremental สามารถถูก manipulate ได้ในบางกรณีโดยไม่ invalidate signature เดิม เนื่องจาก PDF reader บางตัวไม่ verify ว่า byte range cover ทั้ง document

> TODO(verify): ตรวจสอบรายละเอียดงานวิจัยนี้ก่อน cite ใน production content

## The Naive Way

```go
// naive: แต่ละคน sign document เดิม — ลำดับและ completeness ไม่ได้รับการพิสูจน์
type MultiSig struct {
    Document   []byte
    Signatures []struct {
        SignerID string
        Sig      []byte
    }
}

func addSignature(ms *MultiSig, signerID string, priv ed25519.PrivateKey) {
    h := sha256.Sum256(ms.Document)
    sig := ed25519.Sign(priv, h[:])
    ms.Signatures = append(ms.Signatures, ...)
}

// ปัญหา: ลบ Signatures[1] ออก → Signatures[0] และ [2] ยังคง valid
// ปัญหา: สลับ Signatures[0] กับ [1] → ทั้งคู่ยังคง valid
// ปัญหา: ไม่มีทางพิสูจน์ว่า signer เห็น document version ไหน
```

## Explore First

อ่าน documentation ก่อน:

- `crypto/sha256` — streaming hash จาก kata 04
- `bytes` — `bytes.NewReader()`, `bytes.Buffer`
- `io` — `io.MultiReader()` — รวม reader หลายตัวเข้าด้วยกัน

คำถามชี้นำ:
- ถ้า `sig2 = Sign(hash(doc + sig1))` แล้วลบ `sig1` ออก — ทำไม `sig2` ถึง verify ล้มเหลว?
- ถ้าสลับลำดับ `sig1` กับ `sig2` — `sig3` จะ verify ผ่านหรือไม่? ทำไม?
- "Append-only" หมายความว่าอะไรในบริบทนี้?
- Signer คนสุดท้าย "guarantee" อะไรเกี่ยวกับ signer ก่อนหน้า?
- ถ้า signer ลำดับที่ 2 ไม่เห็น `sig1` ตอน sign — จะ verify อย่างไร? ใครต้องส่ง `sig1` ให้?

ห้ามดู example ก่อนลองคิดเอง

## Task

```go
type SignatureEntry struct {
    SignerID  string
    PublicKey ed25519.PublicKey
    Sig       []byte // Sign(hash(doc + sig1 + sig2 + ... + sig_{n-1}))
}

type SignatureChain struct {
    Document   []byte
    Signatures []SignatureEntry
}
```

เขียนฟังก์ชัน:

```go
// เพิ่ม signature ของ signer คนต่อไปใน chain
// payload = hash(Document + Sig[0] + Sig[1] + ... + Sig[n-1])
func AppendSignature(chain *SignatureChain, signerID string, priv ed25519.PrivateKey, pub ed25519.PublicKey) error

// Verify ทุก signature ใน chain ตามลำดับ
// ถ้า signature ใดๆ ไม่ valid หรือลำดับผิด → return error
func VerifyChain(chain *SignatureChain) error
```

เขียน test ที่แสดงให้เห็น:
1. Chain 3 signer: verify ผ่านทั้งหมด
2. ลบ sig ตรงกลาง (sig2): sig3 verify ล้มเหลว
3. สลับ sig1 กับ sig2: sig3 verify ล้มเหลว (และ sig2 verify ล้มเหลวด้วย)
4. แก้ document 1 byte: sig1 ล้มเหลว (และ ทุก sig ถัดไป ด้วย)
5. Chain 1 signer: verify ผ่าน

## Requirements

- Payload ของ signer ลำดับ `n` คือ `sha256(doc || sig[0] || sig[1] || ... || sig[n-1])`
- ใช้ `io.MultiReader` หรือ `bytes.Buffer` เพื่อ concatenate document + signatures ก่อน hash — ห้าม allocate `[]byte` ขนาด `len(doc) + len(all sigs)` ทั้งหมด
- `VerifyChain` ต้อง verify ทุก entry ตามลำดับ index — ห้าม verify ในลำดับสุ่ม
- `AppendSignature` ต้อง include PublicKey ใน SignatureEntry เพื่อให้ verifier ใช้ verify ได้
- Error message ต้องระบุว่า signature ลำดับไหนที่ fail

## Acceptance Criteria

- [ ] 3-signer chain: `VerifyChain` return nil
- [ ] ลบ `Signatures[1]` แล้ว `VerifyChain` fail โดย mention index 1 หรือ 2
- [ ] สลับ `Signatures[0]` กับ `Signatures[1]` → `VerifyChain` fail
- [ ] แก้ `Document` 1 byte → `VerifyChain` fail ที่ signature index 0
- [ ] 1-signer chain: `VerifyChain` return nil
- [ ] ไม่มี allocation `make([]byte, len(doc)+totalSigLen)` ใน payload computation — ใช้ streaming

## Concepts Involved

- **Append-only chain**: signature ลำดับหลัง commit ทุก signature ก่อนหน้า — ลบ/เพิ่ม/สลับลำดับไม่ได้
- **Ordering guarantee**: `sig[n]` พิสูจน์ว่า signer n เห็น signer 1..n-1 แล้ว
- **Completeness guarantee**: ถ้า sig ใดๆ หายไป verifier สุดท้าย detect ได้ทันที
- **io.MultiReader**: concatenate streams โดยไม่ copy data

## Production Reality

ในระบบจริง:

- **PDF PAdES multi-signer**: PDF revision model ทำ multi-signer ผ่าน incremental update — แต่ละ revision ครอบคลุม byte range ของ revision ก่อนหน้า
- **Document workflow systems**: DocuSign, Adobe Sign ใช้หลักการคล้ายกัน — ลายเซ็นแต่ละอันอ้างอิง state ของ document ณ เวลาที่เซ็น
- **Blockchain**: Merkle chain เป็น conceptual extension ของ idea เดียวกัน — แต่ละ block commit ประวัติทั้งหมด
- **Role vs identity**: kata นี้ sign ด้วย identity (private key) — ใน production ยังต้องตรวจว่า identity นั้นมีสิทธิ์ตาม role หรือไม่ (ดู scenario S2)

สิ่งที่ Kata นี้สอน: **multi-signer requires chain** — ไม่ใช่แค่ list of independent signatures
