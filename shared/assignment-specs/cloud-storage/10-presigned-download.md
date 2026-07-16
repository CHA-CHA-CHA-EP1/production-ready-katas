---
tier: cloud-storage
difficulty: 1
concepts: [presigned-url, access-control, content-disposition, temporary-access, bandwidth-cost]
---

# Kata: Presigned Download URL

## Context

ไฟล์ที่เก็บใน S3 มักเป็น private — ใครก็ตามที่ request URL โดยตรงควรได้รับ 403 Access Denied
แต่บางครั้งต้องให้ user ที่ authenticated แล้วสามารถ download ได้ชั่วคราว — เช่น report PDF, invoice, หรือ video ที่ซื้อมา
วิธีผิดมีสองทาง: make bucket public (security nightmare) หรือ proxy download ผ่าน backend (bandwidth cost สูง)
presigned GET URL แก้ทั้งสองปัญหา — ให้ access เฉพาะ file นั้น เฉพาะช่วงเวลาที่กำหนด

## Real World Incidents

**Incident 1 — ข้อมูลผู้ป่วยรั่วจาก bucket public (healthcare app, 2022)**
ทีม dev ไม่รู้วิธีทำ presigned URL — ตัดสินใจทำ bucket public เพื่อให้ app แสดงรูปภาพได้
bucket เก็บทั้ง profile picture และผลตรวจเลือด, ใบ LAB ของผู้ป่วย
S3 URL pattern เดาได้: `https://bucket.s3.amazonaws.com/patient-123/report.pdf`
researcher ค้นพบใน 2 ชั่วโมงหลัง launch โดย enumerate patient ID
ต้องแจ้ง PDPA breach ทันที, ค่าปรับ และความเสียหายต่อชื่อเสียง

**Incident 2 — Bandwidth bill จากการ proxy video download (streaming platform)**
platform ส่ง video ผ่าน backend แทนที่จะ redirect ไปยัง S3
server อ่านจาก S3 แล้วส่งต่อให้ client แบบ streaming
เดือนที่ user เพิ่ม 10x เสียค่า EC2 bandwidth เพิ่ม 8x — S3 download ฟรี แต่ EC2 egress ไม่ฟรี
เปลี่ยนมาใช้ presigned URL + redirect ทำให้ bandwidth cost ลด 90% ในสัปดาห์เดียว

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**

ทางเลือก A — make bucket public:
```
s3://my-bucket → ACL: public-read
// แล้วส่ง direct URL ให้ user
```

ทางเลือก B — proxy ผ่าน backend:
```go
func downloadHandler(w http.ResponseWriter, r *http.Request) {
    obj, _ := client.GetObject(ctx, bucket, key, opts)
    defer obj.Close()
    io.Copy(w, obj)  // stream จาก S3 ผ่าน server ไปยัง client
}
```

**พังตอนไหน:**
- ทางเลือก A: user ทุกคนในโลก access ไฟล์ได้ — ไม่ต้อง login, ไม่ต้องจ่ายเงิน
- ทางเลือก B: 1,000 user download พร้อมกัน → 1,000 goroutine ค้างอยู่ใน io.Copy → server memory/goroutine exhausted
- ทางเลือก B: เสียค่า bandwidth ซ้ำซ้อน — download จาก S3 + upload ไปยัง client

**Root cause:**
การ control access และ serve content เป็นคนละเรื่องกัน
backend ควร control access (ตรวจสอบว่า user นี้มีสิทธิ์ download file นี้ไหม)
แต่ S3 ควร serve content โดยตรง — นั่นคือสิ่งที่ presigned URL ทำ

## Explore First

### Go

ก่อนเขียน code ให้เปิด SDK แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example — ดูได้แค่ godoc / go to definition)

- hint: `client.PresignedGetObject(ctx, bucket, key string, expiry time.Duration, reqParams url.Values)` — parameter สุดท้าย `reqParams` ใช้ทำอะไร? ใส่ค่าอะไรเพื่อควบคุม response header?
- hint: `url.Values` — เป็น type อะไร? จะ set `response-content-disposition` ยังไง?
- `Content-Disposition` header — format ของ `attachment; filename="example.pdf"` คืออะไร? ต่างกับ `inline` ยังไง?
- filename ที่มี space หรือ unicode — ต้องทำอะไรกับ filename ก่อนใส่ใน Content-Disposition? RFC 5987 บอกว่าอะไร?
- presigned GET URL vs presigned PUT URL — ต่างกันยังไงในแง่ของ HTTP method ที่ใช้?
- ถ้า S3 object ไม่มีอยู่ แต่ generate presigned URL ได้สำเร็จ — error จะเกิดตอนไหน?

## Task

implement `generateDownloadURL(client, bucket, key, expiry, filename)` ที่:

1. generate presigned GET URL สำหรับ download object จาก S3-compatible storage
2. ถ้า `filename` ไม่ว่าง ให้ set `Content-Disposition: attachment; filename="<filename>"` ผ่าน `reqParams`
3. ทำให้ browser download file พร้อม filename ที่กำหนด แทนที่จะแสดง S3 key

## Requirements

- ใช้ `reqParams` ของ `PresignedGetObject` เพื่อ set response header — ไม่ใช่แก้ object metadata
- validate `expiry` ต้องอยู่ในช่วง 1 วินาที ถึง 7 วัน
- ถ้า `filename` เป็น empty string — ไม่ต้อง set Content-Disposition (optional download filename)
- filename ที่มี `"` (double quote) ต้อง escape ก่อนใส่ใน header value
- return error ที่บอก context ได้

## Acceptance Criteria

- [ ] return URL ที่ใช้ GET request download ไฟล์ได้
- [ ] ถ้าระบุ filename — response มี `Content-Disposition: attachment; filename="..."` ตามที่กำหนด
- [ ] ถ้าไม่ระบุ filename — URL ยังใช้งานได้ (ไม่ error)
- [ ] expiry = 0 → return error
- [ ] URL expire หลังจาก expiry duration

## Concepts Involved

- `presigned-url` — GET variant, reqParams สำหรับ override response headers
- `content-disposition` — `attachment` vs `inline`, filename parameter, RFC 5987 encoding
- `access-control` — temporary access ต่างจาก public access อย่างไร, หลักการ least privilege
- `bandwidth-cost` — ทำไม presigned URL ถึง redirect ไปยัง S3 แทน proxy, S3 data transfer pricing

## Production Reality

- **ใช้จริง:** backend check permission → generate presigned URL → return URL → frontend redirect หรือ `window.location.href = url`
- **ทำ manual เมื่อ:** ต้องการ log download event, rate limit downloads, หรือ revoke access ก่อน expiry (ต้องใช้ S3 Object Lock หรือเปลี่ยน key)
- **kata สอนว่า:** presigned URL เป็น delegation of access ไม่ใช่การ bypass security — backend ยังต้องตรวจสอบ authorization ก่อน generate URL ทุกครั้ง
