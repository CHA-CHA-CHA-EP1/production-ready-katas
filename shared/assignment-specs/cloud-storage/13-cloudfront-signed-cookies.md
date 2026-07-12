---
tier: cloud-storage
difficulty: 3
concepts: [cloudfront-signed-cookies, rsa-signing, cdn-access-control, hls-streaming, private-content]
provider: aws-only
---

# Kata: CloudFront Signed Cookies

> **Provider:** AWS only — ต้องการ AWS account, IAM permissions, CloudFront distribution, และ AWS SDK

## Context

เวลาต้องการให้ user เข้าถึง private content บน CloudFront วิธีที่คนนึกถึงอันดับแรกคือ presigned URL —
แต่ presigned URL ทำงานได้แค่ file เดียวต่อ URL หนึ่งอัน

ปัญหาเกิดตอนทำ video streaming ด้วย HLS (HTTP Live Streaming) ซึ่ง video หนึ่งตัว
ถูกแยกออกเป็น segment จำนวนมาก ได้แก่ playlist file (`.m3u8`) และ video segments (`.ts`) หลาย segment
ถ้าใช้ presigned URL ต้อง generate URL ใหม่ทุก segment ซึ่งอาจได้ 100-300 URL ต่อ video — verbose, ช้า, และยาก manage

CloudFront Signed Cookies แก้ปัญหานี้โดยให้ access ต่อ resource หลายอัน
ด้วย cookie ชุดเดียว โดยใช้ wildcard pattern เช่น `https://cdn.example.com/videos/123/*`
user browser จะแนบ cookie ไปกับทุก request ต่อ domain นั้นโดยอัตโนมัติ

## Real World Incidents

**Incident 1 — Video streaming พัง เพราะ presigned URL หมดอายุระหว่างดู (Streaming Platform, 2021)**
ทีมทำ OTT platform ใช้ presigned URL สำหรับ HLS video segment แต่ละ segment
เซ็ต expiry ไว้ที่ 5 นาที เพราะกลัว URL รั่ว
ผู้ใช้เริ่มดูวิดีโอ — ช่วงแรกโหลดได้ปกติ แต่พอดูถึงนาทีที่ 6 เล่นต่อไม่ได้
เพราะ HLS player โหลด segment ล่วงหน้าตาม playlist แต่ URL ของ segment ท้ายๆ หมดอายุไปแล้ว
แก้โดยเปลี่ยนมาใช้ CloudFront Signed Cookie ที่ครอบคลุมทั้ง path `videos/movieID/*`
ด้วย expiry 6 ชั่วโมงต่อ session — ไม่ต้อง generate URL ต่อ segment อีก

**Incident 2 — HLS Playlist อ้างถึง segment ที่ไม่มี signed URL (Media Company, 2022)**
ระบบ generate presigned URL สำหรับ `.m3u8` playlist แต่ลืม generate URL สำหรับ `.ts` segment
เพราะคิดว่า player จะ "ตาม" playlist แล้วได้ segment มาเอง
ผล: player โหลด playlist ได้ แต่โหลด segment ไม่ได้ — ได้ 403 Forbidden ทุก segment
support ticket ระเบิดเพราะทุก video เล่นไม่ได้
root cause คือ developer ไม่เข้าใจว่า HLS player request segment แยกจาก playlist
แก้โดยเปลี่ยนไป signed cookies ที่ครอบคลุม `/*` ของ distribution path นั้น

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// generate presigned URL ทีละ segment
for _, segment := range videoSegments {
    url, _ := s3Client.PresignGetObject(ctx, &s3.GetObjectInput{
        Bucket: &bucket,
        Key:    &segment,
    }, func(o *s3.PresignOptions) {
        o.Expires = 5 * time.Minute
    })
    urls = append(urls, url.URL)
}
```

**พังตอนไหน:**
- Video 90 นาที มี ~540 segment × presign overhead = ช้ามาก
- URL แต่ละอัน expire คนละเวลา — segment ท้ายๆ expire ก่อนที่ user จะดูถึง
- HLS player prefetch segment ล่วงหน้า บาง URL expire ก่อน request จริง
- response payload ใหญ่มากถ้าต้องส่ง URL ครบทุก segment ไปยัง client

**Root cause:**
presigned URL ออกแบบมาสำหรับ access แบบ one-off ต่อ resource เดียว
ไม่เหมาะกับ use case ที่ต้อง access หลาย resource พร้อมกันในช่วงเวลาเดียว

## Explore First

### AWS SDK (Go)
ก่อนเขียน code ให้เปิด AWS SDK docs แล้วตอบคำถามเหล่านี้ก่อน

- hint: `github.com/aws/aws-sdk-go-v2/feature/cloudfront/sign` — package นี้ต่างจาก S3 presign ยังไง? ใช้ key อะไรในการ sign?
- hint: `sign.NewCookieSigner(keyID, privKey)` — `keyID` คือ CloudFront Key Pair ID ไม่ใช่ IAM key — หาได้ที่ไหนใน AWS Console?
- hint: `signer.Sign(url, policy)` vs `signer.SignWithPolicy(customPolicy)` — ต่างกันยังไง? `CannedPolicy` vs `CustomPolicy` มีข้อจำกัดอะไร?
- hint: resource URL ใน signed cookie รองรับ wildcard `*` — `https://cdn.example.com/videos/123/*` หมายความว่าอะไร? ต่างจากการ sign ทีละ file ยังไง?
- cookie ที่ได้กลับมาจาก `signer.Sign()` มีกี่อัน? ชื่ออะไรบ้าง? ทำไมถึงต้องส่งครบทุกอัน?
- RSA private key โหลดจาก PEM file ยังไง? ใช้ `x509.ParsePKCS1PrivateKey` หรือ `x509.ParsePKCS8PrivateKey`?

## Task

เขียนฟังก์ชัน `GenerateSignedCookies` สำหรับ private video streaming:

```go
func GenerateSignedCookies(
    privateKey *rsa.PrivateKey,
    keyPairID string,
    resourceURL string,  // e.g. "https://cdn.example.com/videos/123/*"
    expiry time.Time,
) (map[string]string, error)
```

ฟังก์ชันควร return map ของ cookie name → cookie value ที่ client ต้องแนบไปกับทุก request
เช่น `{"CloudFront-Key-Pair-Id": "...", "CloudFront-Signature": "...", "CloudFront-Expires": "..."}`

นอกจากนี้ให้เขียน helper สำหรับ load private key จาก PEM:

```go
func LoadPrivateKey(pemPath string) (*rsa.PrivateKey, error)
```

## Requirements

- ต้องใช้ CloudFront signing package — ห้าม implement RSA signing เอง
- `resourceURL` ต้องรองรับ wildcard pattern เช่น `https://cdn.example.com/videos/movieID/*`
- expiry ต้องไม่อยู่ในอดีต — return error ถ้า `expiry.Before(time.Now())`
- private key ต้องโหลดจาก PEM file ได้ — ไม่ hardcode ใน code
- return error ที่มี context ชัดเจน เช่น `"GenerateSignedCookies: sign failed: invalid key"`
- ต้อง return cookie ครบทุกอัน (`CloudFront-Key-Pair-Id`, `CloudFront-Signature`, `CloudFront-Expires`)

## Acceptance Criteria

- [ ] `GenerateSignedCookies` return map ที่มี key ครบ 3 อัน: `CloudFront-Key-Pair-Id`, `CloudFront-Signature`, `CloudFront-Expires`
- [ ] cookie ใช้งานได้กับ CloudFront distribution จริง — browser ส่ง request พร้อม cookie แล้ว GET resource สำเร็จ
- [ ] wildcard resource URL `https://cdn.example.com/videos/123/*` cover ทุก segment ในโฟลเดอร์นั้น
- [ ] expiry ที่อยู่ในอดีต return error ทันที — ไม่ generate cookie ที่ใช้ไม่ได้
- [ ] `LoadPrivateKey` โหลด PKCS1 RSA private key จาก PEM ได้ถูกต้อง
- [ ] ถ้า private key ผิด format — return error ที่ชัดเจน ไม่ panic

## Concepts Involved

- `cloudfront-signed-cookies` — คือ HTTP cookie ที่ CloudFront ใช้ verify access แทน query string parameter ใน presigned URL
- `rsa-signing` — CloudFront ใช้ RSA-SHA1 signature — private key อยู่ที่เรา, public key upload ไปที่ CloudFront
- `cdn-access-control` — การควบคุม access ผ่าน CDN layer แทน origin — ลด load บน origin และเร็วกว่า
- `hls-streaming` — HTTP Live Streaming ทำงานโดย split video เป็น segment และส่ง playlist — access control ต้องครอบคลุมทุก segment
- `wildcard-resource` — pattern `/*` ใน signed cookie หมายถึง allow access ทุก path ที่ match — ต้อง scope ให้แคบพอ

## Production Reality

- **ใช้จริง:** Netflix, Disney+, และ OTT platform ขนาดใหญ่ใช้ signed cookies สำหรับ video content — generate ครั้งเดียวต่อ session
- **key rotation:** CloudFront Key Pair มี lifecycle — ต้อง rotate และ support หลาย active key ID พร้อมกัน
- **cookie scope:** ระวัง `Domain` และ `Path` attribute ของ cookie — ถ้าตั้งกว้างเกินไป cookie อาจรั่วไปยัง path อื่น
- **kata สอนว่า:** presigned URL และ signed cookies ไม่ใช่ "อันเดียวกันแต่ต่างรูปแบบ" — มี use case คนละแบบ รู้จักเลือกใช้ให้ถูก
