---
tier: cloud-storage
difficulty: 3
concepts: [kms, asymmetric-signing, sign-verify, key-never-leaves-kms, aws-kms, non-repudiation]
provider: aws-only
---

# Kata 26 — KMS Asymmetric Signing (Key Never Leaves KMS)

## Context

Kata 03 สอนการเก็บ private key ใน file ด้วย permissions ที่ถูกต้อง — แต่ private key ยังอยู่ใน file system ที่ OS อ่านได้ถ้ามีสิทธิ์

AWS KMS ให้ทางเลือกที่ดีกว่า: **asymmetric KMS key สำหรับ SIGN_VERIFY** — private key อยู่ใน HSM ภายใน KMS ตลอดไป application เห็นแค่ signature result ไม่เคยเห็น private key เลย

Kata นี้ใช้ AWS KMS Sign API เพื่อ sign object ก่อน upload (pattern จาก kata 24) โดยที่ private key ไม่เคยออกจาก KMS

อ้างอิง: kata 21 (envelope encryption ด้วย KMS) สำหรับ pattern ของ KMS key management

## Real World Incidents

### Private Key บน Compromised EC2 Instance (Plausible scenario)

Application บน EC2 เก็บ private key ใน `/etc/app/signing.key` เมื่อ instance ถูก compromise ผ่าน vulnerability ใน dependency ผู้โจมตีอ่านและขโมย private key ได้โดยตรง จากนั้น sign malicious artifact โดยใช้ key เดิม — ผ่าน verification ทุกระบบ

ถ้าใช้ KMS: แม้ instance ถูก compromise ก็ไม่สามารถขโมย private key ออกมาได้ attacker ได้แค่ KMS API credential ซึ่ง revoke ได้ทันทีผ่าน IAM

### SolarWinds Supply Chain (2020, documented)

Malicious build pipeline sign software update ด้วย SolarWinds' own code signing certificate signature ผ่าน verification ของทุกระบบ เพราะ certificate เป็น certificate จริงของ SolarWinds

ถ้า signing key อยู่ใน HSM/KMS ที่ access controlled อย่างเข้มงวด การ compromise build pipeline จะไม่ได้ signing key โดยตรง (แต่ก็ยังสามารถ call Sign API ได้ถ้า credential ถูก compromise — KMS ลด attack surface แต่ไม่ใช่ silver bullet)

> Source: Microsoft/MSRC SolarWinds analysis, 2020; CISA Alert AA20-352A

## The Naive Way

```go
// naive: private key อยู่ใน environment variable หรือ file — ออกจาก secure boundary
func signWithLocalKey(msg []byte) ([]byte, error) {
    keyPEM := os.Getenv("SIGNING_PRIVATE_KEY")  // ← key อยู่ใน env, อ่านได้จาก process list
    // หรือ
    keyPEM, _ := os.ReadFile("/etc/app/signing.key")  // ← อยู่บน disk

    block, _ := pem.Decode([]byte(keyPEM))
    key, _ := x509.ParsePKCS8PrivateKey(block.Bytes)
    priv := key.(ed25519.PrivateKey)
    return ed25519.Sign(priv, msg), nil
    // private key ผ่าน RAM ของ process — memory dump = key leak
}
```

## Explore First

อ่าน documentation ก่อน:

- `github.com/aws/aws-sdk-go-v2/service/kms` — KMS SDK v2
  - `kms.CreateKey()` — `KeySpec: types.KeySpecEcc_nist_p256` หรือ `types.KeySpecRsa_2048` สำหรับ asymmetric signing
  - `kms.Sign()` — รับ `Message`, `MessageType`, `SigningAlgorithm`, `KeyId`
  - `kms.Verify()` — สำหรับ verify ด้วย KMS (หรือ verify locally ด้วย public key ที่ดึงมา)
  - `kms.GetPublicKey()` — ดึง public key จาก asymmetric KMS key เพื่อ verify locally
  - `types.MessageType` — `Raw` vs `Digest` ต่างกันอย่างไร?
  - `types.SigningAlgorithmSpec` — algorithm ที่รองรับมีอะไรบ้างสำหรับ ECC และ RSA?

- Kata 21 — KMS envelope encryption pattern; IAM role-based access

คำถามชี้นำ:
- `MessageType: Raw` กับ `MessageType: Digest` ต่างกันอย่างไร? KMS hash ให้เองไหม?
- KMS Sign API มี message size limit ไหม? ถ้าต้องการ sign ไฟล์ใหญ่ต้องทำอย่างไร?
- `GetPublicKey()` return public key ในรูปแบบอะไร? DER? PEM? ต้อง parse อย่างไร?
- Verify ด้วย KMS Verify API กับ verify locally ด้วย public key ที่ download มา — ต่างกันด้านอะไร? (cost, latency, dependency)
- IAM permission ที่จำเป็นสำหรับ Sign vs Verify vs GetPublicKey — แยก role กันได้อย่างไร?

ห้ามดู example ก่อนลองคิดเอง

## Task

เขียนฟังก์ชัน:

```go
type KMSSigner struct {
    Client *kms.Client
    KeyID  string // KMS Key ARN หรือ alias
}

// Sign message ด้วย KMS asymmetric key
// message ต้องผ่านการ hash ก่อน (MessageType = Digest) — hash locally, sign digest via KMS
// Return signature bytes ใน DER format
func (s *KMSSigner) Sign(ctx context.Context, digest []byte) ([]byte, error)

// Verify signature ด้วย public key ที่ดึงจาก KMS
// ไม่ call KMS Verify API — verify locally เพื่อลด cost และ latency
func (s *KMSSigner) VerifyLocally(ctx context.Context, digest, sig []byte) error

// ดึง public key จาก KMS เป็น *ecdsa.PublicKey หรือ *rsa.PublicKey
func (s *KMSSigner) GetPublicKey(ctx context.Context) (crypto.PublicKey, error)
```

แล้วรวม `KMSSigner` กับ pattern จาก kata 24:

```go
// Sign object content ด้วย KMS แล้ว upload + .sig object
func KMSSignAndUpload(
    ctx context.Context,
    s3Client *minio.Client,
    kmsClient *kms.Client,
    kmsKeyID string,
    bucket, objectKey string,
    content io.Reader,
    contentSize int64,
) error
```

## Requirements

- Sign ต้องใช้ `MessageType: Digest` — hash locally ด้วย SHA-256, ส่งแค่ digest ไป KMS (ไม่ใช่ raw content — KMS มี message size limit 4096 bytes สำหรับ Raw)
- Verify ต้องทำ locally ด้วย public key ที่ดึงจาก `GetPublicKey()` — ไม่ call `kms.Verify()` เพื่อลด cost
- IAM permission ที่จำเป็น: `kms:Sign` บน KMS key ARN; `kms:GetPublicKey` อยู่แยก role ได้
- Public key ต้อง cache ได้ — `GetPublicKey()` ควรเรียกครั้งเดียวไม่ใช่ทุก verify call
- Error handling: distinguish KMS service error จาก signature invalid error

## Acceptance Criteria

- [ ] `KMSSigner.Sign()` เรียก `kms.Sign` ด้วย `MessageType: Digest`
- [ ] `KMSSigner.VerifyLocally()` ไม่เรียก `kms.Verify` — verify locally เท่านั้น
- [ ] `GetPublicKey()` parse DER public key จาก KMS response เป็น `crypto.PublicKey`
- [ ] `KMSSignAndUpload()` สร้างทั้ง object และ `.sig` object บน S3
- [ ] Sign + verify round-trip สำเร็จ (integration test กับ LocalStack หรือ real AWS)
- [ ] ถ้า content ถูกแก้ 1 byte: `VerifyLocally` fail
- [ ] Error type ต่างกันระหว่าง "KMS API error" กับ "signature invalid"

## Concepts Involved

- **HSM-backed key**: private key อยู่ใน hardware ภายใน KMS — ไม่เคยออกมา software
- **SIGN_VERIFY key usage**: KMS asymmetric key ที่ตั้งใจสำหรับ sign — ต่างจาก ENCRYPT_DECRYPT
- **MessageType Digest**: hash locally แล้วส่ง digest ไป KMS — ลด data transfer และ ทำงานกับไฟล์ใหญ่ได้
- **Verify locally**: ลด latency และ KMS API cost โดยดึง public key ครั้งเดียวแล้ว verify locally
- **IAM as access control**: revoke signing capability โดยแก้ IAM policy — ไม่ต้อง rotate key

## Production Reality

ในระบบจริง:

- **KMS Key ARN ใน config**: เก็บใน environment variable หรือ parameter store — ไม่ hardcode ใน code
- **Key Alias**: ใช้ `alias/signing-key` แทน ARN เพื่อให้ rotation ไม่ต้อง update code
- **Audit log**: ทุก KMS Sign call ถูก log ใน CloudTrail โดยอัตโนมัติ — non-repudiation ฟรี
- **Cost**: KMS Sign API มี cost ต่อ request — cache public key และ verify locally ลด cost ลงมาก
- **Multi-region**: KMS key replication ข้าม region สำหรับ disaster recovery

สิ่งที่ Kata นี้สอน: **key never leaves HSM** คือ gold standard สำหรับ signing ที่ต้องการ non-repudiation สูง — tradeoff คือ latency และ cost ต่อ sign operation
