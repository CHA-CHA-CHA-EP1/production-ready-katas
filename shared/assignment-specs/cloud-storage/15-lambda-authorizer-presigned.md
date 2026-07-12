---
tier: cloud-storage
difficulty: 2
concepts: [lambda-authorizer, presigned-url, credential-security, sts-assume-role, api-gateway]
provider: aws-only
---

# Kata: Lambda Authorizer + Presigned URL Generation

> **Provider:** AWS only — ต้องการ AWS account, IAM permissions, S3, Lambda, API Gateway, และ AWS SDK

## Context

เวลา user ต้องอัปโหลดไฟล์ขึ้น S3 มีสองวิธีหลัก:
1. ส่งไฟล์ผ่าน backend → backend upload ไป S3 (ช้า, เปลือง bandwidth ของ backend)
2. frontend upload ตรงไป S3 ด้วย presigned URL (เร็วกว่า, ไม่ผ่าน backend)

วิธีที่ 2 ดีกว่าในแง่ performance แต่มีคำถามสำคัญ: **ใครเป็นคน generate presigned URL?**

ถ้าให้ frontend generate เองต้องมี AWS credentials ใน browser/app — นั่นคือ **credential leak**
วิธีที่ถูกต้องคือ Lambda เป็น "gate" — รับ request จาก frontend, validate permission, แล้ว generate presigned URL แล้วส่งกลับ
Frontend ได้ URL แล้วค่อย upload ตรงไป S3 — AWS credentials ไม่เคยออกจาก backend

## Real World Incidents

**Incident 1 — AWS credentials ใน mobile app ถูก extract (Uber, 2014)**
Uber embed AWS access key ใน iOS app เพื่อให้ app upload ตรงไป S3
นักวิจัยด้าน security decompile app และพบ credentials ใน binary โดยตรง
credentials มี permission เขียน S3 bucket ที่เก็บ driver document ทั้งหมด
ผู้ไม่หวังดีสามารถอ่านข้อมูล driver ทุกคนได้
บทเรียน: credentials ใน client-side code ถือว่า compromised เสมอ

**Incident 2 — S3 bucket เปิด public เพราะ misconfig ACL (GitLab + Twitch, ต่างกรรมต่างวาระ)**
ทีม dev เปิด S3 bucket เป็น public เพราะ "ง่ายกว่า" ไม่ต้องทำ auth
คิดว่าไม่มีใครรู้ bucket name — แต่ bucket name ถูก enumerate ได้จาก HTTP response header
ข้อมูล user รวมถึง profile picture และ document ถูก access โดยไม่ต้อง auth
การ fix ต้องย้าย object ทั้งหมด เปลี่ยน ACL และ rotate credentials — ใช้เวลาหลายวัน

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```javascript
// ใน React/mobile app — AWS credentials ใน client
import AWS from 'aws-sdk';
AWS.config.update({
    accessKeyId: 'AKIAIOSFODNN7EXAMPLE', // hardcoded ใน code!
    secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
});
const s3 = new AWS.S3();
const url = s3.getSignedUrl('putObject', { Bucket: 'my-bucket', Key: key });
```

**พังตอนไหน:**
- App ถูก decompile → credentials ถูก extract
- Credentials ใน git history → ถูก scan โดย bot ภายในนาทีที่ push
- App version เก่ายังใช้ credentials เดิม → revoke แล้วแต่ app เก่า break
- ใช้ credentials เดิมกันทุก user → ไม่มี per-user audit trail

**Root cause:**
AWS credentials เป็น long-lived secret ที่ให้ permission ระดับ AWS account
ไม่ควรออกจาก backend ไม่ว่ากรณีไหน — presigned URL คือ "token" ที่ expire แล้วมี scope จำกัด

## Explore First

### AWS SDK (Go)
ก่อนเขียน code ให้เปิด AWS SDK docs แล้วตอบคำถามเหล่านี้ก่อน

- hint: `s3.NewPresignClient(client)` — ต่างจาก `s3.NewFromConfig` ยังไง? ใช้ร่วมกันยังไง?
- hint: `presignClient.PresignPutObject(ctx, input, optFns...)` — return type คืออะไร? มี field อะไรบ้าง? URL มีอายุได้นานสุดเท่าไหร่?
- hint: `stscreds.NewAssumeRoleProvider` — ใช้ทำอะไร? ต่างกับ static credentials ยังไง? ทำไมถึงปลอดภัยกว่า?
- hint: `events.APIGatewayProxyRequest` — อ่าน Authorization header จาก field ไหน? validate JWT ยังไง?
- presigned URL สำหรับ `PutObject` มี permission อะไร? user ที่ได้ URL นี้ไปทำอะไรได้บ้าง? ทำอะไรไม่ได้?
- จะ limit ให้ presigned URL ใช้ได้กับ content type เฉพาะ (เช่น `image/jpeg` เท่านั้น) ทำได้ไหม? ยังไง?

## Task

เขียน Lambda handler ที่ทำหน้าที่เป็น auth gate สำหรับ presigned URL:

```go
func Handler(
    ctx context.Context,
    req events.APIGatewayProxyRequest,
) (events.APIGatewayProxyResponse, error)
```

handler ต้องทำตามขั้นตอน:
1. อ่าน `Authorization` header จาก request
2. validate token (สำหรับ kata นี้ ให้ validate ว่า header ไม่ว่างเปล่าและขึ้นต้นด้วย `Bearer `)
3. extract `filename` และ `content_type` จาก query parameters หรือ request body
4. generate presigned `PutObject` URL ด้วย expiry 15 นาที
5. return URL ใน JSON response

เพิ่มเติม — เขียน helper:

```go
func generatePresignedUploadURL(
    ctx context.Context,
    cfg aws.Config,
    bucket, key, contentType string,
    expiry time.Duration,
) (string, error)
```

## Requirements

- ถ้า Authorization header ขาดหรือ format ผิด → return 401 Unauthorized พร้อม error message
- presigned URL ต้องมี expiry ไม่เกิน 15 นาที — ไม่รับ expiry ที่ยาวกว่านั้น
- `key` ต้องมี prefix เป็น userID หรือ session ID เพื่อป้องกัน path traversal เช่น `uploads/{userID}/{filename}`
- ห้าม log presigned URL ใน full — อาจมี credential ใน query string
- return JSON response ที่มี `upload_url` และ `expires_at`

## Acceptance Criteria

- [ ] request ที่ไม่มี Authorization header → 401 response
- [ ] request ที่มี valid header → return JSON ที่มี `upload_url` และ `expires_at`
- [ ] presigned URL ใช้งานได้จริง — PUT request ด้วย URL นี้ไปที่ S3 สำเร็จ
- [ ] presigned URL expire หลัง 15 นาที — PUT ด้วย URL เดิมหลัง expire → 403
- [ ] `key` ใน presigned URL มี prefix ที่ถูกต้อง — ไม่ใช่ root ของ bucket
- [ ] AWS credentials ไม่ปรากฏใน response body หรือ log

## Concepts Involved

- `lambda-authorizer` — Lambda ทำหน้าที่ validate identity ก่อน grant access — separation of concern ระหว่าง auth และ storage
- `presigned-url` — URL ที่มี temporary credential ฝังอยู่ใน query string — expire แล้วมี scope จำกัดกว่า long-lived credentials
- `credential-security` — AWS credentials ไม่ควรออกจาก backend — presigned URL คือ safe alternative สำหรับ client-side upload
- `sts-assume-role` — Lambda ได้ credentials จาก IAM Role ที่ assume — temporary, rotate อัตโนมัติ, มี least privilege
- `path-scoping` — กำหนด S3 key prefix ให้ชัดเจน เพื่อป้องกันไม่ให้ user เขียนทับ object ของ user อื่น

## Production Reality

- **ใช้จริง:** pattern นี้เป็น standard สำหรับ direct-to-S3 upload — frontend ไม่เคยเห็น AWS credentials
- **post-upload validation:** presigned URL ป้องกัน unauthorized write แต่ไม่ validate content — ต้องใช้ S3 Event + Lambda ตรวจสอบ content หลัง upload (ดู kata 14)
- **content-type enforcement:** เพิ่ม `x-amz-content-sha256` หรือ server-side validation ป้องกัน content type spoofing
- **kata สอนว่า:** presigned URL ไม่ใช่ "ให้ client generate เอง" — Lambda เป็น gate ที่ validate แล้ว delegate ต่างหาก
