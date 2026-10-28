---
tier: digital-signature
difficulty: 2
concepts: [context-binding, canonical-form, replay-attack, anti-rollback, manifest, json, encoding/json]
---

# Kata 05 — Context Binding and Anti-Rollback

## Context

Kata 02 สอนการ sign/verify bytes — แต่ใน production ถ้าคุณ sign เฉพาะ raw content โดยไม่มี context เพิ่มเติม จะเกิดช่องโหว่สองอย่าง:

1. **Replay attack**: signature ที่ valid ของ document version 1 สามารถนำมา "replay" แทน version 2 ได้ — ถ้า schema ยังตรงกัน
2. **Cross-context reuse**: signature ที่ทำสำหรับ document A สามารถนำมาแนบกับ document B ได้ — ถ้า content ตรงกันพอดี

วิธีแก้คือ sign **canonical manifest** ที่รวม metadata บอก purpose, version, และเวลา — ไม่ใช่ sign raw bytes เท่านั้น

## Real World Incidents

### JWT Algorithm Confusion (2015-2016, documented)

นี่ไม่ใช่ replay attack โดยตรง แต่เป็นตัวอย่างที่ชัดเจนของ "context ที่ขาดหาย" ทำให้ signature reuse ได้ — JWT ที่ sign ด้วย RS256 (asymmetric) ถูก reuse กับ server ที่ accept `alg: none` หรือ HS256 เพราะ server ไม่ verify algorithm ก่อน verify signature

สาเหตุเดียวกัน: ไม่มี binding ระหว่าง signature กับ context ที่ควรใช้

> ดู [`jwt.md`](../../concepts/jwt.md) สำหรับรายละเอียด algorithm confusion

### Firmware Rollback Attack (Plausible scenario)

Device firmware system เซ็น firmware image ด้วย private key ของ manufacturer แล้ว verify ก่อน flash แต่ไม่ได้ bind signature กับ version number — ผู้โจมตีที่ครอบครอง device สามารถ flash firmware version เก่าที่มีช่องโหว่ที่แก้แล้วได้ เพราะ signature ยังคง valid

ระบบที่ถูกต้องต้องเก็บ "minimum allowed version" และ reject signature ที่ bind กับ version ต่ำกว่า

## The Naive Way

```go
// naive: sign เฉพาะ content bytes — ไม่มี version, ไม่มี purpose binding
func signDocument(priv ed25519.PrivateKey, content []byte) []byte {
    h := sha256.Sum256(content)
    return ed25519.Sign(priv, h[:])
}

// ปัญหา 1: replay — signature ของ content@v1 valid กับ content@v1 ที่ถูก replay มาแทน v2
// ปัญหา 2: cross-doc reuse — ถ้า content เหมือนกัน signature ก็ใช้แทนกันได้
// ปัญหา 3: "signedAt" มาจากที่ไหน? ถ้า client ส่งมา client อาจ backdate ได้
```

## Explore First

อ่าน documentation ก่อน:

- `encoding/json` — `json.Marshal()`, `json.Unmarshal()`
  - JSON marshal ของ Go มี deterministic field order ไหม? (hint: map vs struct)
  - ทำไม `map[string]any` จึง dangerous สำหรับ canonical form?
- `time` — `time.Now().UTC()`, `time.Time.UnixMilli()`
  - ใช้ time จาก server (code ที่ run ฝั่ง signer) หรือ time จาก request? ทำไม?
- `crypto/sha256` — streaming hash จาก kata 04

คำถามชี้นำ:
- "Canonical form" หมายความว่าอะไร? ทำไม field order ถึงสำคัญใน JSON?
- Manifest ควรมีข้อมูลอะไรบ้างเพื่อป้องกัน replay?
- ถ้า `signedAt` มาจาก request body ของ client — ปัญหาคืออะไร?
- "Version" ใน manifest หมายถึงอะไร? ควรเป็น version ของ document หรือ version ของ schema?
- ถ้า signer เซ็น manifest แต่ content ไม่ได้อยู่ใน manifest — verifier จะ verify content ได้ไหม?

ห้ามดู example ก่อนลองคิดเอง

## Task

ออกแบบและ implement **SignedManifest** — structure ที่ sign แทนการ sign raw bytes:

```go
type SignedManifest struct {
    // Content metadata
    ContentSHA256 string `json:"contentSha256"` // hex-encoded SHA-256 ของ content
    ContentName   string `json:"contentName"`   // ชื่อเอกสาร/ไฟล์
    ContentSize   int64  `json:"contentSize"`   // bytes
    // Anti-replay
    Version       int    `json:"version"`       // document version number
    SignedAt      int64  `json:"signedAt"`       // Unix milliseconds — ต้องมาจาก server clock
    // Binding
    Purpose       string `json:"purpose"`        // e.g. "discharge-summary", "approval"
    // Signature (ไม่ได้อยู่ใน signed payload)
    Signature     string `json:"signature,omitempty"` // hex-encoded, append หลัง sign
    SignerKeyID   string `json:"signerKeyId,omitempty"`
}
```

เขียนฟังก์ชัน:

```go
// สร้างและเซ็น manifest — SignedAt มาจาก server clock (time.Now())
func CreateSignedManifest(
    content []byte,
    name string,
    version int,
    purpose string,
    priv ed25519.PrivateKey,
    keyID string,
) (*SignedManifest, error)

// Verify manifest signature + ตรวจ freshness (ไม่เก่ากว่า maxAge)
func VerifyManifest(m *SignedManifest, content []byte, pub ed25519.PublicKey, maxAge time.Duration) error
```

เขียน test ที่แสดงให้เห็น:
1. Valid manifest → pass
2. Content tampered → fail
3. Version เปลี่ยน (rollback) → fail
4. Purpose เปลี่ยน (cross-context) → fail
5. SignedAt เก่าเกิน maxAge → fail

## Requirements

- Payload ที่ sign ต้องเป็น canonical JSON ของ manifest **ที่ไม่มี Signature field** — ใช้ struct ที่ omit signature field
- `SignedAt` ต้องมาจาก `time.Now().UTC()` ใน `CreateSignedManifest` — ห้ามรับ timestamp จาก parameter
- `ContentSHA256` ต้องคำนวณจาก `content` จริงๆ — ห้ามรับจาก caller
- `VerifyManifest` ต้องตรวจทั้ง: signature valid, content hash ตรง, maxAge ไม่เกิน
- Canonical form ต้องใช้ struct (ไม่ใช่ map) เพื่อ deterministic field order

## Acceptance Criteria

- [ ] Valid manifest + valid content: `VerifyManifest` return nil
- [ ] Content เปลี่ยน 1 byte: fail (ContentSHA256 ไม่ตรง)
- [ ] `Version` field ถูกเปลี่ยนใน manifest: signature fail (payload เปลี่ยน)
- [ ] `Purpose` field ถูกเปลี่ยน: signature fail
- [ ] `SignedAt` เก่ากว่า maxAge: fail (freshness check)
- [ ] Manifest ที่ sign สำหรับ purpose "approval" ไม่ผ่าน verify สำหรับ purpose "discharge-summary"
- [ ] ไม่มี timestamp parameter ใน `CreateSignedManifest` — ใช้ `time.Now()` เท่านั้น
- [ ] Signature ไม่รวมอยู่ใน payload ที่ sign (ตรวจด้วย test: marshal manifest ที่มี Signature แล้ว verify → ต้อง fail)

## Concepts Involved

- **Context binding**: รวม metadata (purpose, version, docID) ใน signed payload เพื่อป้องกัน reuse ข้าม context
- **Anti-rollback**: version ใน manifest ป้องกัน replay version เก่า
- **Canonical form**: signed payload ต้อง deterministic — struct JSON ไม่ใช่ map
- **Server clock**: timestamp สำหรับ security ต้องมาจาก server — client clock ไม่ trust ได้
- **Freshness check**: ตรวจ `signedAt` เพื่อ reject signature ที่เก่าเกินไป

## Production Reality

ในระบบจริง:

- **JWT ใช้ pattern เดียวกัน**: `iss`, `sub`, `aud`, `exp` คือ context binding ใน JWT — ดู `jwt.md`
- **sigstore/cosign**: ใช้ "bundle" ที่รวม certificate, timestamp, transparency log entry — context binding ที่สมบูรณ์กว่า
- **Document ID binding**: ในระบบจริงควรมี document UUID ใน manifest เพื่อป้องกัน signature ถูกย้ายไปแนบกับ document อื่น (ดู scenario S2)
- **ล้มเหลวอย่างปลอดภัย**: `VerifyManifest` ต้อง reject ถ้า ANY check ล้มเหลว — ไม่ใช่ผ่านถ้า "ส่วนใหญ่ผ่าน"

สิ่งที่ Kata นี้สอน: **sign context ไม่ใช่แค่ content** — manifest ที่ดีทำให้ replay และ cross-context reuse เป็นไปไม่ได้
