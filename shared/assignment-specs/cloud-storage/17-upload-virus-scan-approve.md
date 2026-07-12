---
tier: cloud-storage
difficulty: 3
concepts: [quarantine-pattern, s3-object-tagging, s3-copy-delete, security-scanning, access-control]
provider: aws-only
---

# Kata: Upload Quarantine + Virus Scan Gate

> **Provider:** AWS only — ต้องการ AWS account, IAM permissions, S3 bucket (quarantine + approved), Lambda, และ AWS SDK

## Context

เมื่อ user อัปโหลดไฟล์ขึ้น platform มีคำถามสำคัญ: **เมื่อไหร่ที่ไฟล์นั้นพร้อมให้ผู้อื่นเข้าถึง?**

วิธี naive คือให้ไฟล์ accessible ทันทีหลังอัปโหลด — แต่ถ้าไฟล์นั้นเป็น malware?
User อื่นที่ดาวน์โหลดไฟล์นั้นก็ติดเชื้อไปด้วย

pattern ที่ถูกต้องคือ **quarantine-then-approve**:
1. user อัปโหลดไปยัง `quarantine/` prefix ซึ่ง **ไม่ public** เลย
2. Lambda scan virus/malware
3. ถ้าสะอาด → copy ไปยัง `approved/` prefix แล้ว tag status
4. ถ้าพบ malware → delete และ notify

`quarantine/` prefix ต้อง lock down ด้วย bucket policy — ห้าม public access เด็ดขาด

## Real World Incidents

**Incident 1 — Malware แพร่ผ่าน file sharing platform (Multiple Platforms, 2020-2021)**
ช่วง COVID ที่ remote work เพิ่มขึ้น ทีม security พบว่า file sharing platform หลายแห่ง
ถูกใช้เป็นช่องทางแจกจ่าย malware โดยอาศัยความน่าเชื่อถือของ platform
ผู้โจมตีอัปโหลดไฟล์ที่ดูเหมือน PDF หรือ Office document แต่ฝัง macro/payload
platform ที่ไม่มี scan gate → ไฟล์ accessible ทันที → user คลิกโดยไม่รู้
platform ที่มี quarantine → ไฟล์ไม่ถูก serve จนกว่า scan จะผ่าน

**Incident 2 — Upload bypass ผ่าน race condition (Bug Bounty Report, 2022)**
ระบบ scan แบบ synchronous: อัปโหลด → scan → flag → serve
นักวิจัยพบว่าถ้าอัปโหลดเร็วพอและเรียก download ทันทีหลัง upload
สามารถ download ไฟล์ก่อนที่ scan จะเสร็จ (race condition ระหว่าง scan และ serve)
แก้โดยเปลี่ยน architecture ใหม่: ไฟล์ไม่มีทางเข้าถึงได้เลยจนกว่าจะ copy ไปยัง `approved/` — ไม่ใช่แค่ flag

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
func HandleUpload(w http.ResponseWriter, r *http.Request) {
    // 1. upload ขึ้น S3 ทันที (public accessible!)
    s3.PutObject(ctx, &s3.PutObjectInput{
        Bucket: &bucket,
        Key:    &key, // "files/user123/document.pdf"
        Body:   r.Body,
    })

    // 2. scan หลัง upload (ช้าไปแล้ว — ไฟล์ accessible แล้ว)
    if isMalware(key) {
        s3.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &bucket, Key: &key})
        // แต่ระหว่าง upload → scan มีช่องว่างเวลาที่ไฟล์ accessible
    }

    w.WriteHeader(http.StatusOK)
}
```

**พังตอนไหน:**
- Race condition: ไฟล์ accessible ทันทีหลัง upload ก่อน scan เสร็จ
- Scan fail (Lambda crash, timeout) → ไฟล์ค้างอยู่ใน accessible state โดยไม่ผ่าน scan
- Delete หลัง scan fail → ไฟล์หายแม้จะไม่ใช่ malware (false positive destroy data)
- ไม่มี audit trail ว่า scan ผล เป็นอะไร

**Root cause:**
ควบ "accessible" กับ "approved" เข้าด้วยกัน — ไฟล์ที่ upload แล้วไม่ควร accessible
จนกว่าจะผ่านขั้นตอนการตรวจสอบที่ชัดเจน

## Explore First

### AWS SDK (Go)
ก่อนเขียน code ให้เปิด AWS SDK docs แล้วตอบคำถามเหล่านี้ก่อน

- hint: `s3.CopyObject` — ใช้ copy object ระหว่าง key/bucket — `CopySource` format เป็นยังไง? encode character พิเศษยังไง?
- hint: `s3.DeleteObject` — delete หลัง copy เพื่อ "move" — ทำไม S3 ไม่มี native move operation?
- hint: `s3.PutObjectTagging` และ `types.Tagging` — tag object ด้วย key-value — ใช้ track scan status ยังไง?
- hint: `s3.GetObjectTagging` — อ่าน tag ปัจจุบัน — tag มี limit กี่ pair ต่อ object?
- Bucket Policy สามารถ deny access ตาม prefix ได้ไหม? เขียน condition ยังไง? หรือต้องใช้ ACL?
- ถ้าต้องการให้ `quarantine/` accessible เฉพาะ Lambda role เดียว — policy ต้องเขียนยังไง?

## Task

เขียน Lambda function สำหรับ virus scan gate:

```go
func ScanAndApprove(ctx context.Context, event events.S3Event) error
```

ฟังก์ชันต้องทำตามขั้นตอน:
1. รับ event จาก `quarantine/` prefix
2. download object จาก quarantine
3. ทำ scan (สำหรับ kata ให้ simulate ด้วย mock scanner ที่ตรวจหา magic bytes `X5O!P%@AP`)
4. ถ้าสะอาด: copy object ไปยัง `approved/` prefix แล้ว tag ด้วย `scan-status: clean`
5. ถ้าพบ threat: delete จาก quarantine แล้ว tag object ที่ delete แล้ว (บน copy ชั่วคราว) ด้วย `scan-status: malware`
6. log scan result พร้อม objectKey และ scan duration

เพิ่มเติม — เขียน helper:

```go
// MockScanner simulate virus scan (returns true ถ้าพบ malware)
func MockScanner(content []byte) bool

// moveToApproved copy จาก quarantine/ → approved/ แล้ว delete จาก quarantine
func moveToApproved(ctx context.Context, client *s3.Client, bucket, key string) error

// tagScanResult tag object ด้วย scan result
func tagScanResult(ctx context.Context, client *s3.Client, bucket, key, status string) error
```

## Requirements

- `quarantine/` prefix ต้อง lock ด้วย bucket policy — ห้าม public read ทุกกรณี
- `approved/` prefix เท่านั้นที่ serve ให้ end user ได้
- ทุก object ต้องได้รับ tag `scan-status` ก่อนที่จะ accessible (clean) หรือถูกลบ (malware)
- "move" ต้อง atomic enough: copy สำเร็จก่อนค่อย delete จาก quarantine — ไม่ใช่ delete ก่อน
- ถ้า copy สำเร็จแต่ delete fail → log error แต่ไม่ถือว่า scan fail — object อยู่ใน approved แล้ว
- log ต้องมี: objectKey, scanDuration, scanResult, finalLocation (approved หรือ deleted)

## Acceptance Criteria

- [ ] อัปโหลดไฟล์ปกติไปที่ `quarantine/` → Lambda scan → copy ไปยัง `approved/` → tag `scan-status: clean`
- [ ] อัปโหลดไฟล์ที่มี EICAR test string → Lambda scan → delete จาก quarantine → ไม่ปรากฏใน `approved/`
- [ ] ไฟล์ใน `quarantine/` ไม่สามารถ GET ได้โดย anonymous request → 403 (bucket policy บังคับ)
- [ ] ไฟล์ใน `approved/` มี tag `scan-status: clean` ทุกไฟล์
- [ ] `copy` เสร็จก่อน `delete` เสมอ — ไม่มีกรณีที่ object หายไปจาก quarantine โดยไม่อยู่ใน approved
- [ ] log แสดง scan duration และ result ทุก invocation

## Concepts Involved

- `quarantine-pattern` — แยก landing zone (quarantine) ออกจาก serving zone (approved) — ไม่มีทางเข้าถึงไฟล์ก่อนผ่าน gate
- `s3-object-tagging` — metadata key-value ที่แนบกับ object — ใช้ track status โดยไม่ต้องเก็บใน DB แยก
- `s3-copy-delete` — S3 ไม่มี native move — ต้อง copy แล้ว delete — sequence ของ operation สำคัญมาก
- `security-scanning` — validate content ก่อน serve — scan ที่ดีต้องอยู่ใน path ที่บังคับ ไม่ใช่ optional
- `access-control` — bucket policy เป็น policy ระดับ resource — ใช้ deny แบบ explicit สำหรับ quarantine

## Production Reality

- **ใช้จริง:** Dropbox, Box, Google Drive ทุกเจ้ามี quarantine layer — scan ด้วย service จริง เช่น ClamAV, VirusTotal API
- **scan latency:** scan อาจใช้เวลาหลายวินาทีถึงนาที — ควรแสดง UI "กำลังตรวจสอบ..." ให้ user รู้
- **false positive:** scan ที่ดีต้องมี manual review process สำหรับ false positive — อย่าลบทันทีโดยไม่มี backup
- **kata สอนว่า:** security gate ต้องอยู่ใน architecture ไม่ใช่ optional step — quarantine prefix เป็น architectural boundary ที่ enforce โดย bucket policy
