# Concept: Session Management

## Stateful Sessions vs Stateless Tokens

สองวิธีหลักในการ track ว่า "user คนนี้ยืนยันตัวตนแล้ว":

### Stateful Session (Server-side)

```
client                    server                    storage
  │── POST /login ────────►│                              │
  │                        │── validate credentials       │
  │                        │── generate session ID ──────►│ store {session_id: user_data}
  │◄── Set-Cookie: sid=abc ─│                              │
  │                        │                              │
  │── GET /profile ────────►│                              │
  │   Cookie: sid=abc       │── lookup session_id ────────►│
  │                        │◄── {user: ..., expires: ...} ─│
  │◄── 200 OK ──────────── │                              │
```

**ข้อดี:**
- Revoke ได้ทันที — ลบ session ออกจาก storage แล้ว user logout ทันที
- Session data เก็บ server-side — ไม่มีใน token ที่ client อ่านได้
- Server รู้ทุก active session ของ user

**ข้อเสีย:**
- ต้องการ shared storage (Redis, DB) — scaling ยากขึ้นใน distributed system
- Storage เป็น single point of failure

### Stateless Token (JWT)

```
client                    server
  │── POST /login ────────►│
  │                        │── validate credentials
  │                        │── sign JWT {user_id, exp, ...}
  │◄── JWT token ──────────│
  │                        │
  │── GET /profile ────────►│
  │   Authorization: Bearer  │── verify signature
  │   <jwt>                 │── check exp claim
  │◄── 200 OK ─────────── │
```

**ข้อดี:**
- Stateless — server ไม่ต้องเก็บ state, scale ง่าย
- Payload readable โดย client (base64 ไม่ใช่ encrypted) — client รู้ user info ได้โดยไม่ต้อง round-trip

**ข้อเสีย:**
- Revoke ยาก — ต้องมี blocklist หรือรอให้ expire (ถ้า revoke ทันทีต้องใช้ server-side state อยู่ดี)
- Token ขนาดใหญ่กว่า session ID มาก (อาจถึง 500+ bytes)
- Payload ที่ client อ่านได้ → ห้ามเก็บ sensitive data ใน payload

---

## Cookie Flags

Cookie flag คือ attribute ที่บอก browser ว่า "ส่ง cookie นี้เมื่อไหร่" และ "JavaScript อ่านได้ไหม"

### HttpOnly

```
Set-Cookie: session=abc123; HttpOnly
```

- **บอก browser:** JavaScript (document.cookie, fetch, XHR) แตะ cookie นี้ไม่ได้
- **ป้องกัน:** XSS ที่พยายาม steal session cookie
- **ไม่ป้องกัน:** CSRF — browser ยังส่ง cookie ไปกับทุก request ไปยัง domain นั้น

```javascript
// ถ้าไม่มี HttpOnly:
document.cookie  // → "session=abc123; other=xyz"

// ถ้ามี HttpOnly:
document.cookie  // → "other=xyz"  (session ไม่ปรากฏ)
```

### Secure

```
Set-Cookie: session=abc123; Secure
```

- **บอก browser:** ส่ง cookie นี้เฉพาะกับ HTTPS requests เท่านั้น
- **ป้องกัน:** Network sniffing บน HTTP connections, man-in-the-middle ที่ดัก HTTP traffic
- **ควรใช้เสมอ** บน production ที่ใช้ HTTPS

### SameSite

```
Set-Cookie: session=abc123; SameSite=Strict
Set-Cookie: session=abc123; SameSite=Lax
Set-Cookie: session=abc123; SameSite=None; Secure
```

| Flag | Cookie ส่งไปกับ | Use case |
|------|----------------|----------|
| `Strict` | เฉพาะ navigation จาก same site เท่านั้น | Admin panel, banking — ไม่ต้องการ cross-site navigation |
| `Lax` | top-level navigation (คลิกลิงก์) + same-site requests | Default ใน modern browsers — ดี for most apps |
| `None; Secure` | ทุก cross-origin request | Embedded widgets, third-party auth flows |

**SameSite=Strict vs Lax:**
```
ผู้ใช้อยู่ที่ evil.com แล้วคลิกลิงก์ไปยัง bank.com/transfer:

Strict: cookie ไม่ถูกส่ง → ผู้ใช้ต้อง login ใหม่ที่ bank.com (annoy แต่ปลอดภัย)
Lax:    cookie ถูกส่ง → ผู้ใช้เห็นหน้า transfer โดยยัง login อยู่ (UX ดีกว่า ยัง protect CSRF form submission)
```

SameSite=Lax ป้องกัน CSRF form submission ได้ (POST จาก cross-site ไม่ส่ง cookie) แต่ไม่ป้องกัน GET-based CSRF

### Path และ Domain

```
Set-Cookie: admin_session=xyz; Path=/admin; Domain=example.com
```

- `Path=/admin` — browser ส่ง cookie นี้เฉพาะ request ที่ path ขึ้นต้นด้วย `/admin`
- `Domain=example.com` — browser ส่ง cookie ไปยัง `example.com` และ subdomain ทั้งหมด (`api.example.com`, `admin.example.com`)
- ถ้าไม่ระบุ `Domain` — cookie ใช้ได้เฉพาะ exact domain ที่ set (ไม่รวม subdomain)

### MaxAge vs Expires

```
Set-Cookie: session=abc; MaxAge=3600           # หมดอายุใน 3600 วินาที (1 ชั่วโมง)
Set-Cookie: session=abc; Expires=Thu, 01 Jan 2026 00:00:00 GMT  # หมดอายุตาม absolute datetime
```

- `MaxAge` ใช้ relative time — แนะนำให้ใช้มากกว่า เพราะไม่ขึ้นกับ clock ของ client
- `Expires` ใช้ absolute datetime — อาจผิดถ้า clock client ต่างจาก server
- ไม่ระบุทั้งคู่ → session cookie (หายเมื่อปิด browser tab)

---

## Session Fixation

### ทำงานอย่างไร

1. Attacker เข้า `https://bank.com/login` แล้วได้ session ID (ก่อน login): `sid=ATTACKER_KNOWN_ID`
2. Attacker ส่งลิงก์ให้ victim: `https://bank.com/login?sid=ATTACKER_KNOWN_ID` (บาง app อ่าน session ID จาก URL parameter)
3. Victim login สำเร็จ — ถ้า app ไม่ rotate session ID, session `ATTACKER_KNOWN_ID` กลายเป็น authenticated session ของ victim
4. Attacker ใช้ `sid=ATTACKER_KNOWN_ID` เข้าถึง account ของ victim ได้ทันที

### การป้องกัน: Rotate Session ID หลัง Login

```go
// ❌ ไม่ดี: ใช้ session ID เดิมหลัง login
func Login(w http.ResponseWriter, r *http.Request) {
    sessionID := getSessionID(r)  // session ID ที่มีอยู่แล้ว
    session := store.Get(sessionID)
    session.UserID = authenticatedUserID
    store.Save(sessionID, session)
    // attacker ที่รู้ sessionID ก็เข้าได้
}

// ✅ ดี: สร้าง session ID ใหม่หลัง authenticate สำเร็จ
func Login(w http.ResponseWriter, r *http.Request) {
    oldSessionID := getSessionID(r)
    store.Delete(oldSessionID)  // ลบ session เก่า

    newSessionID := generateSecureRandomID()  // session ID ใหม่ที่ attacker ไม่รู้
    store.Save(newSessionID, Session{UserID: authenticatedUserID})
    setSessionCookie(w, newSessionID)
}
```

---

## Session Hijacking

### วิธีที่ attacker steal session

1. **XSS** — inject JavaScript ที่อ่าน `document.cookie` แล้วส่งออกไป
   - ป้องกันด้วย `HttpOnly` flag — JS อ่าน cookie ไม่ได้

2. **Network Sniffing** — ดัก HTTP traffic บน shared network (WiFi สาธารณะ)
   - ป้องกันด้วย `Secure` flag + HTTPS เท่านั้น

3. **Sub-domain cookie theft** — ถ้า `Domain=example.com`, malicious.example.com อ่าน cookie ได้
   - ป้องกันด้วยไม่ set `Domain` (จำกัดเฉพาะ exact host)

4. **Session fixation** — ดูข้างบน

5. **Log exposure** — cookie value ปรากฏใน access log
   - ป้องกันด้วยการ mask `Cookie` header ใน logging config

---

## CSRF (Cross-Site Request Forgery)

### ทำงานอย่างไร

```
victim กำลัง login อยู่ที่ bank.com (มี valid session cookie)

attacker ส่ง email มีลิงก์ไปยัง evil.com/attack.html:

<form action="https://bank.com/transfer" method="POST" id="f">
  <input name="to" value="attacker_account">
  <input name="amount" value="10000">
</form>
<script>document.getElementById('f').submit()</script>

browser ของ victim auto-submit form นี้ พร้อมส่ง bank.com cookie ไปด้วย
→ transfer เกิดขึ้นโดย victim ไม่รู้ตัว
```

### การป้องกัน

**1. SameSite=Lax/Strict cookie**
- `Strict`: ไม่ส่ง cookie กับ cross-site request เลย (รวม navigation)
- `Lax`: ไม่ส่ง cookie กับ cross-site POST/PUT/DELETE แต่ส่งกับ GET navigation
- ป้องกัน form submission CSRF ได้ดีมาก

**2. CSRF Token (Double-Submit Cookie Pattern)**
```
server set สอง cookie:
  - session=abc (HttpOnly) — JS อ่านไม่ได้
  - csrf_token=xyz123 (readable) — JS อ่านได้

client ต้องส่ง csrf_token ใน X-CSRF-Token header ด้วย

attacker จาก evil.com อ่าน csrf_token cookie ของ bank.com ไม่ได้ (SameSite / same-origin policy)
→ ไม่สามารถ construct request ที่ valid ได้
```

**3. Origin/Referer Header Check**
```go
func checkOrigin(r *http.Request) bool {
    origin := r.Header.Get("Origin")
    if origin == "" {
        referer := r.Header.Get("Referer")
        // parse referer URL
        return strings.HasPrefix(referer, "https://myapp.com")
    }
    return origin == "https://myapp.com"
}
```

---

## Session Lifecycle

### Login: Issue New Session

```
1. validate credentials
2. delete old session (ป้องกัน session fixation)
3. generate cryptographically random session ID (≥128 bits)
4. store session server-side: {user_id, created_at, last_active, ip, user_agent}
5. set session cookie: HttpOnly + Secure + SameSite=Lax
```

### During Session: Validate + Extend

```
1. read session ID from cookie
2. lookup in storage — ถ้าไม่เจอ → ไม่ valid (deleted หรือ expired)
3. check absolute timeout: if created_at + MAX_AGE < now → expired, delete
4. check idle timeout: if last_active + IDLE_TIMEOUT < now → expired, delete
5. update last_active timestamp
6. attach user info to request context
```

### Logout: Invalidate Server-Side

```go
// ❌ ไม่ดี: clear cookie เฉพาะ client-side
// attacker ที่ copy session ID ไว้ก่อน logout ยังใช้ได้

// ✅ ดี: ลบ session จาก server ก่อน แล้วค่อย clear cookie
func Logout(w http.ResponseWriter, r *http.Request) {
    sessionID := getSessionID(r)
    store.Delete(sessionID)  // invalidate server-side ก่อน

    http.SetCookie(w, &http.Cookie{
        Name:    "session",
        Value:   "",
        MaxAge:  -1,  // browser delete cookie ทันที
        HttpOnly: true,
        Secure:  true,
    })
}
```

### Timeout: สองชั้น

| Type | Definition | Typical Value | Purpose |
|------|------------|---------------|---------|
| **Idle timeout** | นับจาก last activity | 30 นาที | ปิด session ที่ user ทิ้งไว้ |
| **Absolute timeout** | นับจาก session creation | 8-24 ชั่วโมง | บังคับ re-login แม้ user active อยู่ |

ต้องมีทั้งสองแบบ:
- Idle-only: user ที่ keep refreshing ไม่ต้อง re-login ไม่ต้อง — session อยู่ตลอดไป
- Absolute-only: user ที่ไม่ active แต่ session ยังไม่ครบ absolute limit ก็ยังถูก hijack ได้นาน
