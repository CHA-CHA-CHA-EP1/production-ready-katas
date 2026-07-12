---
tier: cloud-storage
difficulty: 2
concepts: [worker-pool, bounded-concurrency, error-collection, goroutine-leak, errgroup]
---

# Kata: Concurrent Upload

## Context

migration งาน หรือ bulk upload มักต้องอัป file หลายพันไฟล์ไปยัง S3
sequential upload 10,000 ไฟล์ที่ละ 100ms = 1,000 วินาที ≈ 16 นาที ในขณะที่ concurrent upload ด้วย 50 workers อาจเสร็จใน 20 วินาที
แต่ unbounded concurrency ก็อันตราย — สร้าง goroutine 10,000 ตัวพร้อมกัน = memory พุ่ง, S3 throttle, network saturation
pattern ที่ถูกต้องคือ worker pool ที่ bounded — จำนวน goroutine คงที่ไม่ว่าจะมีไฟล์กี่ไฟล์

## Real World Incidents

**Incident 1 — Data migration ใช้เวลา 3 วัน แทนที่จะเป็น 2 ชั่วโมง (Dropbox, 2016)**
ทีมย้ายข้อมูลจาก datacenter เก่าไปยัง S3 โดยใช้ sequential loop
script คาดว่าจะใช้เวลา 2 ชั่วโมง กลายเป็น 3 วัน
ค้นพบปัญหาเมื่อ deadline กำลังจะพลาด — ต้องเขียน parallel version ฉุกเฉิน
เสียเวลา downtime เพิ่มเพราะต้องรอ migration ซ้ำ

**Incident 2 — OOM crash จาก unbounded goroutine (startup บน GCP)**
นักพัฒนาแก้ปัญหา sequential upload ด้วยการสร้าง goroutine ต่อไฟล์ทันที
```go
for _, f := range files {
    go upload(f)  // สร้าง goroutine 50,000 ตัวพร้อมกัน
}
```
goroutine แต่ละตัวกินหน่วยความจำ ~8KB stack (initial) — 50,000 ตัว = 400MB เฉพาะ stack
บวกกับ S3 connection buffer ต่อ goroutine ทำให้ container OOM ก่อนที่จะ upload เสร็จแม้แต่ไฟล์เดียว

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
// version 1: sequential — ช้าเกินไป
for _, f := range files {
    client.PutObject(ctx, bucket, f.Key, f.Reader, -1, opts)
}

// version 2: goroutine ต่อไฟล์ — OOM
var wg sync.WaitGroup
for _, f := range files {
    wg.Add(1)
    go func(f FileEntry) {
        defer wg.Done()
        client.PutObject(...)
    }(f)
}
wg.Wait()
```

**พังตอนไหน:**
- version 1: 10,000 ไฟล์ × 100ms = 16 นาที → timeout ก่อนเสร็จ
- version 2: goroutine 10,000 ตัว → RSS พุ่ง → OOM kill → ไม่รู้ว่า upload ไหนสำเร็จ
- version 2: error จาก goroutine แรกที่ fail ไม่ถูก collect → ไม่รู้ว่าไฟล์ไหนพัง

**Root cause:**
ไม่มี mechanism ควบคุมจำนวน goroutine ที่ active พร้อมกัน และไม่มีวิธี collect error จาก goroutine ย่อยกลับมาที่ caller

## Explore First

### Go

ก่อนเขียน code ให้เปิด SDK แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `make(chan struct{}, n)` — buffered channel ขนาด n ใช้เป็น semaphore ได้ยังไง? ทำไม `struct{}` แทน `bool`?
- hint: `golang.org/x/sync/errgroup` — `Group.Go()` ต่างจาก `go func()` ยังไง? `Group.Wait()` return อะไร?
- hint: `sync.WaitGroup` — `Add`, `Done`, `Wait` ต้องเรียกในลำดับอะไร? ถ้า `Add` หลัง goroutine start จะเกิดอะไร?
- channel ที่ใช้ส่ง jobs ระหว่าง goroutine — ถ้าไม่ close channel, worker goroutine จะรู้ว่า work หมดแล้วได้ยังไง?
- `sync.Mutex` กับ goroutine-safe slice — ถ้า goroutine หลายตัว append errors พร้อมกัน จะต้องทำอะไร?
- goroutine leak คืออะไร? goroutine ค้างอยู่ใน blocked channel receive จะ GC ได้ไหม?

## Task

เขียนฟังก์ชัน `ConcurrentUpload(client *minio.Client, bucket string, files []FileEntry, workers int) []UploadError` ที่:

1. upload ไฟล์ทั้งหมดใน `files` แบบ concurrent โดยใช้ worker pool ขนาด `workers`
2. จำนวน goroutine ที่ active พร้อมกันต้องไม่เกิน `workers` เสมอ ไม่ว่า `files` จะมีกี่ตัว
3. collect errors จากทุก goroutine — ไม่หยุดทำงานเมื่อ error แรกเกิดขึ้น
4. return รายการ error ทุกตัว พร้อมบอกว่า file ไหนพัง

```go
type FileEntry struct {
    Key    string
    Reader io.ReadSeeker
    Size   int64
}

type UploadError struct {
    Key string
    Err error
}
```

## Requirements

- จำนวน concurrent goroutine ต้องไม่เกิน `workers` — ทดสอบได้ด้วย runtime.NumGoroutine
- ต้อง collect error ทุกตัว — ไม่ใช่แค่ error แรก
- ถ้า `workers <= 0` ให้ใช้ค่า default เช่น `runtime.NumCPU()`
- ไม่มี goroutine leak หลัง function return — worker ทุกตัวต้อง exit
- ลำดับใน return slice ไม่จำเป็นต้องตรงกับ input (concurrent upload = non-deterministic order)
- ถ้า `files` เป็น empty slice ให้ return empty slice (ไม่ panic)

## Acceptance Criteria

- [ ] upload ครบทุกไฟล์เมื่อไม่มี error
- [ ] จำนวน goroutine ขณะ upload ไม่เกิน `workers + overhead` (เช่น main + workers)
- [ ] ถ้า 3 ไฟล์ fail ใน 10 ไฟล์ → return `[]UploadError` ขนาด 3, upload ที่เหลืออีก 7 ยังทำงานต่อ
- [ ] ไม่มี goroutine leak หลัง function return (ทดสอบด้วย goleak)
- [ ] ไม่มี data race (ทดสอบด้วย `-race` flag)
- [ ] `workers = 1` ทำงานเหมือน sequential upload

## Concepts Involved

- `worker-pool` — pattern สำหรับ bounded concurrency, jobs channel, N fixed workers
- `bounded-concurrency` — semaphore pattern ด้วย buffered channel, ทำไมไม่สร้าง goroutine ต่อ item
- `error-collection` — goroutine-safe error accumulation ด้วย mutex-protected slice หรือ error channel
- `goroutine-leak` — goroutine ที่ block บน channel ตลอดไป, ผลต่อ memory, ตรวจสอบด้วย pprof
- `errgroup` — `golang.org/x/sync/errgroup` สำหรับ fan-out pattern พร้อม error propagation

## Production Reality

- **ใช้จริง:** `golang.org/x/sync/errgroup` ร่วมกับ semaphore pattern — หรือใช้ library เช่น `conc` (sourcegraph/conc)
- **ทำ manual เมื่อ:** ต้องการ per-item progress reporting, partial retry, หรือ streaming results
- **kata สอนว่า:** "concurrent" ไม่ได้แปลว่า "goroutine ต่อ item" — worker pool คือ pattern ที่ใช้จริงเพราะ predictable resource usage
