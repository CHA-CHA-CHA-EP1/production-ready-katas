---
tier: cloud-storage
difficulty: 2
concepts: [upload-confirmation, eventual-consistency, phantom-record, stat-object, db-s3-sync]
---

# Kata: Upload Confirm Pattern

## Context

เมื่อ frontend upload ตรงไปยัง S3 ผ่าน presigned URL backend ไม่รู้ว่า upload สำเร็จหรือไม่
วิธีที่ผิดคือสร้าง database record ก่อน upload — ถ้า upload fail, DB มี record ที่ชี้ไป S3 object ที่ไม่มีอยู่จริง
วิธีที่ถูกคือ verify ก่อน persist — ให้ client confirm หลัง upload สำเร็จ แล้ว backend ตรวจสอบว่า S3 object มีจริงและขนาดถูกต้องก่อน save DB
pattern นี้ป้องกัน phantom record และทำให้ DB กับ S3 sync กันเสมอ

## Real World Incidents

**Incident 1 — DB มี record แต่ S3 ว่าง ทำให้ application พัง (food delivery company)**
backend สร้าง restaurant menu image record ใน DB ก่อน generate presigned URL
user upload ล้มเหลว (network drop) แต่ DB record ยังอยู่
app แสดงรูปเมนูที่ 404 — customer เห็น broken image ทุกครั้งที่เปิดร้านนั้น
ปัญหาซ่อนอยู่นาน 3 เดือนจนมี complaint report เพราะ affected เฉพาะ restaurant ที่ network ไม่ดี

**Incident 2 — Phantom upload records ทำให้ storage quota salat (cloud storage service)**
service คิด quota จากจำนวน records ใน DB ไม่ใช่ actual S3 size
user upload fail บ่อย (เช่น ปิด browser กลางคัน) — record สร้างไว้แต่ upload ไม่เสร็จ
quota ถูกใช้ไปโดย phantom records ที่ไม่มี S3 object จริงๆ
user เต็ม quota ทั้งๆ ที่ actual data น้อยกว่าที่ควร — ร้องเรียนเข้ามาเป็น batch

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**

แบบ A — สร้าง DB record ก่อน:
```go
func prepareUpload(w http.ResponseWriter, r *http.Request) {
    // สร้าง record ใน DB ก่อน
    db.Insert("files", FileRecord{Key: key, Status: "pending"})
    // แล้วค่อย generate presigned URL
    url, _ := client.PresignedPutObject(ctx, bucket, key, 15*time.Minute)
    json.NewEncoder(w).Encode(url)
}
```

แบบ B — เชื่อ client ว่า upload สำเร็จ:
```go
func confirmUpload(w http.ResponseWriter, r *http.Request) {
    // client บอกว่า upload เสร็จแล้ว → update DB ทันที โดยไม่ verify S3
    db.Update("files", key, FileRecord{Status: "ready"})
}
```

**พังตอนไหน:**
- แบบ A: network drop ระหว่าง upload → DB มี record แต่ S3 ว่าง → app แสดง 404
- แบบ B: malicious client ส่ง confirm โดยไม่ upload จริง → DB record ชี้ไป non-existent object
- แบบ B: ใช้เป็น quota bypass — confirm upload ทุกครั้ง แต่ไม่ upload → ได้ quota ฟรี
- ทั้งสองแบบ: เมื่อเวลาผ่านไป DB และ S3 drift → ยิ่งนาน ยิ่งยากแก้

**Root cause:**
DB และ S3 เป็น two separate systems — ต้องมี verification step ที่ backend check S3 directly ก่อน trust client
"client บอกว่า upload เสร็จ" ไม่ใช่ source of truth — S3 object existence คือ source of truth

## Explore First

### Go

ก่อนเขียน code ให้เปิด SDK แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `client.StatObject(ctx, bucket, key string, opts minio.StatObjectOptions)` — return type คืออะไร? `minio.ObjectInfo` มี field อะไรที่บอกว่า object มีอยู่จริง และขนาดเท่าไหร่?
- hint: `minio.ObjectInfo.Size` — เป็น type อะไร? เทียบกับ `expectedSize int64` ได้ตรงๆ เลยไหม?
- hint: ถ้า object ไม่มีอยู่ `StatObject` จะ return error แบบไหน? จะแยกแยะ "object not found" กับ "network error" ได้ยังไง?
- hint: `minio.ToErrorResponse(err).Code` — ค่า Code อะไรที่หมายถึง object ไม่มีอยู่?
- `expectedSize = -1` ควร skip size check ได้ไหม? หรือบังคับต้องส่ง size เสมอ? trade-off คืออะไร?
- S3 eventual consistency — หลัง presigned PUT สำเร็จ จะ StatObject ได้ทันทีเลยไหม? หรืออาจต้องรอ?
- typed error vs sentinel error: ควร return error type ที่บอกว่า "not found" vs "size mismatch" vs "network error" ได้ยังไง?

## Task

implement `confirmUpload(client, bucket, key, expectedSize)` ที่:

1. ตรวจสอบว่า object ใน S3 มีอยู่จริง
2. ถ้า `expectedSize >= 0` ให้ตรวจสอบว่า object size ตรงกับที่คาด
3. return typed error ที่บอกสาเหตุได้ชัดเจน

```
// ตัวอย่าง error types ที่ควรสร้าง:
errObjectNotFound {
  Bucket string
  Key string
}

errSizeMismatch {
  Key string
  Expected number
  Actual number
}
```

## Requirements

- ใช้ `StatObject` ไม่ใช่ `GetObject` — ไม่ต้อง download content เพื่อ verify existence
- แยกแยะ error type: "object not found" vs "size mismatch" vs "S3 error" (network/permission)
- `expectedSize < 0` → skip size check, แค่ verify existence
- error message ต้องบอก bucket, key, และ expected/actual size ถ้า mismatch
- function ต้อง idempotent — เรียก confirm ซ้ำบน object เดิมได้โดยไม่มี side effect

## Acceptance Criteria

- [ ] object มีอยู่ + size ตรง → return nil
- [ ] object ไม่มีอยู่ → return `ErrObjectNotFound` (ไม่ใช่ generic error)
- [ ] object มีอยู่แต่ size ไม่ตรง → return `ErrSizeMismatch` พร้อม expected vs actual
- [ ] `expectedSize = -1` → return nil ถ้า object มีอยู่ (ไม่ check size)
- [ ] caller ใช้ error type inspection เพื่อ extract error type ได้
- [ ] network error จาก S3 → return error ที่ wrap ด้วย context

## Concepts Involved

- `upload-confirmation` — why verify matters, client ไม่ใช่ source of truth, backend verify pattern
- `stat-object` — HeadObject vs GetObject, ทำไม StatObject ถึงถูกกว่า GetObject สำหรับ verify
- `phantom-record` — DB record ที่ไม่มี backing data, วิธีป้องกันและ detect
- `db-s3-sync` — two-phase commit ใน distributed system (simplified), compensating transaction
- `typed-errors` — Go error types, `errors.As`, ทำไม typed error ดีกว่า string comparison

## Production Reality

- **ใช้จริง:** pattern คือ generate presigned URL → frontend upload → frontend POST /confirm → backend StatObject → backend INSERT to DB (transaction)
- **ทำ manual เมื่อ:** ต้องการ confirm size + checksum (MD5/SHA256) เพื่อ verify integrity ไม่ใช่แค่ existence
- **alternative:** ใช้ S3 Event Notification (SNS/SQS) แทน client-confirm — S3 push event เมื่อ object created, backend process จาก queue
- **kata สอนว่า:** ใน distributed system ต้องมี ground truth source เดียว — สำหรับ file existence นั้น S3 คือ source of truth ไม่ใช่ client, และ DB ต้องตามหลัง S3 เสมอ
