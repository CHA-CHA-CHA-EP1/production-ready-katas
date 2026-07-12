---
tier: cloud-storage
difficulty: 2
concepts: [exponential-backoff, jitter, idempotent-retry, context-cancellation, s3-error-handling]
---

# Kata: Upload with Retry

## Context

S3-compatible storage ไม่ได้รับประกัน 100% availability — AWS S3 SLA อยู่ที่ 99.9% ซึ่งหมายความว่า error เกิดขึ้นได้ทุกเมื่อ โดยเฉพาะ 503 SlowDown ที่ S3 ส่งกลับมาเมื่อ request rate เกิน limit
ปัญหาคือ upload ที่ fail แล้วไม่ retry = data หาย แต่ retry ที่ไม่มี backoff = ยิ่งทำให้ S3 โหลดหนักขึ้นไปอีก ซึ่งทำให้ error เพิ่มขึ้นเรื่อยๆ จนเป็น retry storm
การทำ retry อย่างถูกต้องต้องมีทั้ง exponential backoff, jitter เพื่อกระจาย load, และ context-aware cancellation

## Real World Incidents

**Incident 1 — Silent data loss ระหว่าง traffic spike (Shopify, 2021)**
ช่วง Black Friday, S3 ส่ง 503 SlowDown กลับมาเป็น batch ใหญ่เมื่อ request rate พุ่งพร้อมกัน
upload code เดิมไม่มี retry — error ถูก log แล้ว silently drop
product image หลายพันรูปหายไปจาก CDN โดยไม่มี alert
ทีมรู้ตอนลูกค้า report ว่า image แสดงไม่ขึ้น — ต้องทำ re-upload ใหม่ทั้งหมด

**Incident 2 — Retry storm ทำให้ outage ยาวขึ้นสามเท่า (Slack, 2018)**
S3 region เกิด partial outage — error rate พุ่งขึ้นกะทันหัน
upload service มี retry แต่ไม่มี backoff — retry ทันทีทุก attempt
server ทั้ง cluster ยิง request ซ้ำในเวลาเดียวกัน ทำให้ S3 โหลดหนักขึ้นแทนที่จะลด
outage ที่น่าจะหายใน 10 นาทีกลายเป็น 30+ นาที เพราะ retry storm ยังคงกด S3 ต่อเนื่อง

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
_, err := client.PutObject(ctx, bucket, key, r, size, minio.PutObjectOptions{})
if err != nil {
    return err  // upload fail = data หาย
}
```

**พังตอนไหน:**
- S3 ส่ง 503 SlowDown กลับมาระหว่าง traffic spike → upload fail ทันที ไม่มี second chance
- network blip ชั่วคราว 200ms → upload หาย ทั้งๆ ที่ retry ครั้งเดียวก็รอด
- retry แบบไม่มี backoff: `for { client.PutObject(...) }` → ยิงซ้ำทันที ทำให้ S3 โหลดหนักขึ้น → retry storm

**Root cause:**
S3 error เกือบทั้งหมดเป็น transient — 503 หมายความว่า "ช้าลงหน่อย" ไม่ใช่ "ไฟล์นี้ upload ไม่ได้"
retry ที่ดีต้องแยกแยะ retryable error ออกจาก permanent error และต้องรอนานขึ้นเรื่อยๆ พร้อม random jitter เพื่อไม่ให้ทุก client retry พร้อมกัน

## Explore First

### Go

ก่อนเขียน code ให้เปิด SDK แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `minio.ToErrorResponse(err)` — return type คืออะไร? field `Code` มีค่าอะไรบ้างที่หมายถึง retryable error? (`SlowDown`, `RequestTimeout`, `InternalError`)
- hint: `io.ReadSeeker` — มี method อะไรที่ใช้ reset position ก่อน retry? `Seek(0, io.SeekStart)` ทำงานยังไง?
- hint: `time.Sleep(d time.Duration)` — ถ้า context cancel ระหว่าง sleep จะเกิดอะไรขึ้น? จะทำให้ sleep cancel ได้ยังไง?
- hint: `context.Done()` — channel นี้ทำงานยังไง? จะใช้ใน select statement ร่วมกับ time.After ได้ยังไง?
- `rand.Int63n` — ทำไม jitter ต้องเป็น random? ถ้าไม่มี jitter แล้ว client 1000 ตัว retry พร้อมกัน จะเกิดอะไรขึ้น?
- HTTP status code 429 กับ 503 ต่างกันยังไงในบริบทของ S3? ควร retry ทั้งคู่ไหม?

## Task

เขียนฟังก์ชัน `UploadWithRetry(client *minio.Client, bucket, key string, r io.ReadSeeker, maxAttempts int) error` ที่:

1. upload object ไปยัง S3-compatible storage
2. retry เมื่อเจอ retryable error (503, 429, network timeout) โดยใช้ exponential backoff
3. เพิ่ม random jitter ใน wait time เพื่อป้องกัน thundering herd
4. reset reader position ก่อนทุก retry attempt (ใช้ `ReadSeeker`)
5. หยุด retry ทันทีเมื่อ context ถูก cancel

## Requirements

- backoff ต้องเป็น exponential: attempt 1 = ~1s, attempt 2 = ~2s, attempt 3 = ~4s (base * 2^attempt)
- jitter ต้องเป็น random ± 20% ของ wait time เพื่อกระจาย request
- ต้อง reset `r` ด้วย `Seek(0, io.SeekStart)` ก่อนทุก retry — เพราะ partial read ทำให้ reader อยู่กลางไฟล์
- แยกแยะ retryable vs non-retryable error: `NoSuchBucket`, `AccessDenied` = ไม่ retry
- return error ที่บอกได้ว่า attempt ครบกี่ครั้ง เช่น `"upload failed after 3 attempts: 503 SlowDown"`
- context cancel ต้อง interrupt sleep ระหว่าง backoff ด้วย — ไม่ใช่แค่ check ก่อน upload

## Acceptance Criteria

- [ ] upload สำเร็จในครั้งแรกถ้า S3 ตอบ 200
- [ ] retry และสำเร็จใน attempt ที่ 2 เมื่อ attempt แรก 503
- [ ] ไม่ retry เมื่อ error เป็น `NoSuchBucket` หรือ `AccessDenied`
- [ ] reader position reset ก่อนทุก retry (ทดสอบด้วย mock reader ที่ track Seek calls)
- [ ] context cancel ระหว่าง sleep → return error ทันที ไม่รอ backoff จบ
- [ ] หยุดเมื่อครบ maxAttempts แม้ error ยังเป็น retryable

## Concepts Involved

- `exponential-backoff` — ทำไม fixed retry interval ถึงแย่, formula คืออะไร, cap ที่เท่าไหร่ดี
- `jitter` — thundering herd problem, full jitter vs equal jitter, AWS whitepaper แนะนำอะไร
- `idempotent-retry` — S3 upload ด้วย same key = safe to retry, แต่ append-based storage ไม่ใช่
- `context-cancellation` — deadline propagation, cancel ระหว่าง sleep ทำยังไง
- `s3-error-codes` — ErrorResponse.Code, retryable vs permanent errors

## Production Reality

- **ใช้จริง:** AWS SDK for Go v2 มี built-in retry ด้วย `aws.RetryerV2` — configure ผ่าน `aws.Config`
- **ทำ manual เมื่อ:** ใช้ minio client หรือต้องการ custom retry logic เฉพาะทาง (เช่น retry บาง key pattern เท่านั้น)
- **kata สอนว่า:** retry ไม่ใช่แค่ `for { ... }` — backoff + jitter + context + idempotency ทุกอย่างต้องครบ ขาดอันเดียวก็พังได้
