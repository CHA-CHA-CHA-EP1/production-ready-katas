---
tier: digital-signature
difficulty: 3
concepts: [x509, certificate, ca, chain-of-trust, key-usage, self-signed, crypto/x509, encoding/pem]
---

# Kata 08 — Mini CA and X.509 Chain Verification

## Context

Kata 01-07 ใช้ raw public key โดยตรง — แต่ใน production ปัญหาคือ: **verifier รู้ได้อย่างไรว่า public key นั้นเชื่อถือได้?**

X.509 certificate แก้ปัญหานี้ด้วยการให้ Certificate Authority (CA) รับรองว่า "public key X เป็นของ entity Y" — โดย CA sign certificate ของ Y ด้วย private key ของ CA เอง

Kata นี้ implement "toy CA" เพื่อเข้าใจกลไกทั้งหมด:
1. สร้าง self-signed Root CA certificate
2. Issue certificate สำหรับ end-entity (doctor, device, service) ที่ signed โดย CA
3. Verify certificate chain: end-entity cert → Root CA cert → trust anchor
4. ตรวจ expiry, KeyUsage, และ self-signed vs trusted

## Real World Incidents

### Trust The Certificate Inside The Signature (Plausible scenario)

ระบบ IoT ตรวจสอบ firmware signature โดยดึง certificate จากภายใน firmware bundle แล้ว verify signature ด้วย public key ในนั้น — โดยไม่ตรวจว่า certificate นั้นถูก sign โดย CA ที่เชื่อถือได้หรือไม่

ผู้โจมตีสร้าง self-signed certificate ของตัวเอง sign firmware malicious แล้ว bundle certificate ไปด้วย — ระบบ verify ผ่านเพราะ signature valid กับ certificate ที่แนบมา แม้ certificate ไม่มีใครรับรอง

**หลัก**: certificate ที่ verified signature ต้อง chain ไปถึง trust anchor ที่เราเชื่อ — ไม่ใช่แค่ "valid ในตัวเอง"

### DigiNotar CA Compromise (2011, documented)

DigiNotar ซึ่งเป็น Dutch CA ถูก compromise ทำให้ attacker ออก rogue certificates สำหรับ `*.google.com` และ domain อื่นๆ ได้ browsers/OS ต้องรีบ revoke trust ต่อ DigiNotar CA ทั้งหมด — ทำให้ certificate ที่ออกโดย DigiNotar ทุกใบใช้ไม่ได้

เหตุการณ์นี้แสดงให้เห็นว่า trust model ของ X.509 ดี แต่ "trust anchor" (Root CA) ต้องน่าเชื่อถือจริงๆ

> Source: Dutch Government report on DigiNotar, 2012; NIST documentation

## The Naive Way

```go
// naive: ดึง public key จาก cert ที่แนบมาใน signature blob แล้ว verify โดยตรง
func verifyWithEmbeddedCert(msg, sig []byte, certDER []byte) error {
    cert, _ := x509.ParseCertificate(certDER)
    pub := cert.PublicKey.(ed25519.PublicKey)
    if !ed25519.Verify(pub, msg, sig) {
        return errors.New("invalid signature")
    }
    return nil // ← ไม่ตรวจว่า cert ออกโดยใคร!
}
```

**ปัญหา**: attacker สร้าง cert เองได้ฟรี — ถ้าแค่ verify signature กับ public key ใน cert โดยไม่ chain verify ก็ไม่มีความหมาย

## Explore First

อ่าน documentation ก่อน:

- `crypto/x509`
  - `x509.Certificate` struct — fields ไหนที่สำคัญ: `Subject`, `Issuer`, `NotBefore`, `NotAfter`, `KeyUsage`, `IsCA`, `BasicConstraints`
  - `x509.CreateCertificate(rand, template, parent, pub, priv)` — `template` กับ `parent` ต่างกันอย่างไรสำหรับ self-signed?
  - `x509.ParseCertificate(der []byte)` — return `*x509.Certificate`
  - `x509.NewCertPool()`, `pool.AddCert()`, `cert.Verify(opts)` — ใช้ chain verify อย่างไร?
  - `x509.KeyUsage` constants: `KeyUsageDigitalSignature`, `KeyUsageCertSign`, `KeyUsageCRLSign`
- `encoding/pem` — PEM type สำหรับ certificate คืออะไร? (`"CERTIFICATE"`)
- `math/big` — `big.NewInt()` สำหรับ serial number
- `crypto/rand` — `rand.Int(rand.Reader, max)` สำหรับ random serial number

คำถามชี้นำ:
- Self-signed certificate คืออะไร? `template == parent` ใน `CreateCertificate` หมายความว่าอะไร?
- Root CA cert ต้องมี `KeyUsage` อะไรบ้าง? ต่างจาก end-entity cert?
- `BasicConstraints.IsCA = true` สำคัญอย่างไรใน chain verification?
- `x509.Certificate.Verify()` ตรวจอะไรบ้าง? (hint: chain, expiry, key usage)
- Serial number ใน certificate มีหน้าที่อะไร? ทำไมต้องเป็น unique?

ห้ามดู example ก่อนลองคิดเอง

## Task

```go
// สร้าง self-signed Root CA certificate + key pair
func CreateRootCA(subject pkix.Name, validity time.Duration) (*x509.Certificate, ed25519.PrivateKey, error)

// Issue certificate สำหรับ end-entity ที่ signed โดย CA
// endEntityPub คือ public key ของ entity ที่จะใช้ sign documents
func IssueEntityCert(
    ca *x509.Certificate,
    caPriv ed25519.PrivateKey,
    subject pkix.Name,
    validity time.Duration,
    entityPub ed25519.PublicKey,
) (*x509.Certificate, error)

// Verify ว่า cert chain ไปถึง trusted root CA
// ตรวจ: chain valid, expiry, KeyUsage.DigitalSignature
func VerifyCertChain(entityCert, rootCACert *x509.Certificate) error

// Sign message ด้วย private key พร้อม embed entity certificate
type CertifiedSignature struct {
    Message     []byte
    Sig         []byte
    CertDER     []byte // DER-encoded entity certificate
}

func SignWithCert(priv ed25519.PrivateKey, cert *x509.Certificate, message []byte) CertifiedSignature

// Verify CertifiedSignature โดย:
// 1. Parse entity certificate
// 2. Verify cert chain กับ trusted root CA
// 3. Verify signature ด้วย public key ใน cert
func VerifyCertifiedSignature(cs CertifiedSignature, trustedRoot *x509.Certificate) error
```

เขียน test:
1. Sign + verify ด้วย properly-issued cert → pass
2. Sign ด้วย self-signed cert (ไม่มี CA) → chain verify fail
3. Cert หมดอายุ → fail
4. Entity cert มี `KeyUsage` แค่ `CertSign` (ไม่มี `DigitalSignature`) → fail
5. Cert ออกโดย CA อื่น (ไม่ใช่ trusted root) → fail

## Requirements

- Root CA cert ต้องมี `BasicConstraints.IsCA = true` และ `KeyUsage` ที่รวม `KeyUsageCertSign`
- Entity cert ต้องมี `KeyUsage` ที่รวม `KeyUsageDigitalSignature` แต่ **ไม่มี** `KeyUsageCertSign`
- Serial number ต้องเป็น random (ไม่ hardcode 1)
- `VerifyCertifiedSignature` ต้องทำทั้ง 3 ขั้นตอนตามลำดับ: parse → chain verify → sig verify
- ห้าม verify signature ก่อน chain verification ผ่าน

## Acceptance Criteria

- [ ] Root CA cert: `IsCA = true`, `KeyUsageCertSign` set
- [ ] Entity cert: `IsCA = false`, `KeyUsageDigitalSignature` set, `KeyUsageCertSign` ไม่ set
- [ ] Entity cert signed โดย Root CA: `VerifyCertChain` return nil
- [ ] Self-signed entity cert (ไม่ผ่าน CA): `VerifyCertChain` fail
- [ ] Expired entity cert: `VerifyCertifiedSignature` fail
- [ ] `KeyUsage` ผิด (ไม่มี `DigitalSignature`): `VerifyCertifiedSignature` fail
- [ ] Cert จาก CA อื่น: `VerifyCertifiedSignature` fail
- [ ] Sign + verify with valid cert chain: pass end-to-end

## Concepts Involved

- **X.509 Certificate**: structure มาตรฐานที่ bind public key กับ identity, signed โดย CA
- **Self-signed cert**: Issuer == Subject — ใช้เป็น Root CA trust anchor หรือใน dev เท่านั้น
- **Certificate chain**: end-entity → (intermediate CA →) Root CA; verifier trust Root CA
- **KeyUsage**: กำหนดว่า key pair นี้ใช้ทำอะไรได้บ้าง — enforcement สำคัญมาก
- **Trust anchor**: Root CA ที่ verifier เลือก trust — ไม่มีหลักฐานทางคณิตศาสตร์ว่า root CA น่าเชื่อถือ

## Production Reality

ในระบบจริง:

- **ไม่ต้อง implement CA เอง**: ใช้ Let's Encrypt (TLS certs), AWS Private CA, หรือ internal enterprise CA ที่มีอยู่แล้ว
- **Certificate pinning**: บาง application pin certificate (หรือ public key hash) แทนที่จะ trust chain ทั้งหมด — ลด attack surface แต่ทำ rotation ยากขึ้น
- **OCSP / CRL**: กลไก revoke certificate — golang.org/x/crypto/ocsp สำหรับ OCSP
- **Short-lived certs**: trend ล่าสุด (e.g. SPIFFE/SPIRE) ออก cert อายุ 24 ชั่วโมงแทนที่จะมี revocation — ถ้า cert หมดอายุไวก็ไม่ต้องการ revoke mechanism

สิ่งที่ Kata นี้สอน: **certificate ไม่มีค่าถ้าไม่ verify chain** — public key ที่ "bundled" ไม่ใช่ trust anchor
