---
tier: authentication
difficulty: 2
concepts: [user-enumeration, timing-attack, dummy-hash, generic-error-message]
---

# Kata: User Enumeration Prevention

## Context

Login endpoint ที่ดูธรรมดาสามารถเปิดเผย username ที่ valid ในระบบได้โดยไม่ตั้งใจ
attacker สามารถ enumerate account ที่มีอยู่จริงจาก error message หรือ response time ที่ต่างกัน
ข้อมูล "account นี้มีอยู่" มีค่ามากสำหรับ credential stuffing และ targeted phishing

## Real World Incidents

**Incident 1 — Password Reset Enumeration (หลายแพลตฟอร์ม, 2010s)**
เว็บไซต์ e-commerce หลายแห่งมี password reset ที่คืน "email นี้ไม่มีในระบบ" เมื่อกรอก email ที่ไม่มีอยู่
attacker เขียน script วน loop ทดสอบ email จาก breached list — รู้ว่า account ไหนมีอยู่จริง
ข้อมูลนี้ถูกขายใน dark web ในรูป "validated email list" ที่มีราคาสูงกว่า raw email list
แก้ด้วยการคืน generic message "ถ้า email นี้มีในระบบ เราจะส่ง link ไปให้" ไม่ว่า email จะมีหรือไม่มี

**Incident 2 — Login Timing Difference (Internal audit findings, ทั่วไป)**
Login endpoint ที่ query user จาก DB แล้ว return ทันทีถ้าไม่พบ user — ทำให้ request ใช้เวลา ~5ms
ถ้าพบ user แต่ password ผิด — bcrypt comparison ใช้เวลา ~300ms
attacker วัด response time ได้แม่นยำมากพอที่จะแยกแยะ "user ไม่มี" กับ "password ผิด"
pattern นี้ถูกพบใน security audit ซ้ำๆ และมักถูก report เป็น medium severity finding

## The Naive Way (และทำไมมันพัง)

**วิธีที่คนมักเขียนครั้งแรก:**
```go
func Login(db DB, username, password string) (*User, error) {
    user, err := db.FindUser(username)
    if err != nil {
        return nil, errors.New("user not found")  // ❌ error ต่างกัน
    }

    if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)); err != nil {
        return nil, errors.New("wrong password")  // ❌ error ต่างกัน
    }

    return user, nil
}
```

**พังตอนไหน:**
- error message ต่างกัน → attacker รู้ว่า account มีอยู่หรือไม่
- "user not found" return ใน ~5ms, "wrong password" return ใน ~300ms → timing attack
- แม้แก้ error message แล้วแต่ยังไม่แก้ timing → ยังโดน enumerate ได้

**Root cause:**
การ skip bcrypt เมื่อ user ไม่พบทำให้ response time ต่างกันมากเกินไป
attacker ไม่ต้องการ error message — แค่ response time ก็พอ
การ fix ต้องทำทั้งสองอย่างพร้อมกัน: error message เดียวกัน + เวลาเท่ากัน

## Explore First

### Go

ก่อนเขียน code ให้เปิด docs แล้วตอบคำถามเหล่านี้ก่อน (ห้ามดู example)

- hint: `bcrypt.CompareHashAndPassword` — ใช้เวลาเท่าไหร่โดยประมาณที่ cost 12? จะ simulate เวลานี้เมื่อ user ไม่พบได้ยังไง?
- hint: dummy hash — ถ้าต้อง compare กับ "ไม่มีอะไร" จะสร้าง hash dummy สำหรับ compare ได้ยังไงที่ใช้เวลาใกล้เคียงกัน?
- การ hardcode dummy hash เป็น constant มี risk อะไร? ทำไมถึงควร pre-compute ตอน startup แทน?
- `time.Sleep` เป็นวิธีที่ดีสำหรับ constant time ไหม? มีปัญหาอะไรเมื่อ compare กับวิธี dummy hash?
- error ที่ return ออกนอกฟังก์ชันควรเป็นอะไร? ควร log error จริงๆ ไว้ไหม และ log ที่ไหน?

## Task

เขียนฟังก์ชัน:

```go
type DB interface {
    FindUser(username string) (*User, error)
}

type User struct {
    ID           string
    Username     string
    PasswordHash string
}

func Login(db DB, username, password string) (*User, error)
```

`Login` ตรวจสอบ credential และคืน `*User` เมื่อสำเร็จ
ต้องคืน error เดียวกันและใช้เวลาใกล้เคียงกันไม่ว่า username จะมีอยู่หรือไม่

## Requirements

- ต้อง run bcrypt comparison เสมอ ไม่ว่า user จะพบหรือไม่ (ใช้ dummy hash ถ้าไม่พบ)
- ต้อง return error message เดียวกันสำหรับทุก failure case: `"invalid credentials"`
- response time สำหรับ "user not found" และ "wrong password" ต้องต่างกันไม่เกิน 10ms
- ห้ามใช้ `time.Sleep` เป็น primary mechanism — ใช้ dummy hash comparison แทน
- dummy hash ต้องถูก pre-compute ตอน init ไม่ใช่ hardcode string constant
- log error ที่ unexpected (เช่น DB error) ได้ แต่ห้าม log username + password ร่วมกัน

## Acceptance Criteria

- [ ] login ด้วย username ที่ไม่มีในระบบ คืน `"invalid credentials"` error
- [ ] login ด้วย username ที่มีแต่ password ผิด คืน `"invalid credentials"` error (error เดียวกัน)
- [ ] login ด้วย credential ถูกต้อง คืน `*User` ที่ถูกต้อง
- [ ] response time สำหรับ "not found" และ "wrong password" ต่างกันไม่เกิน 10ms เมื่อวัด 100 ครั้ง
- [ ] ไม่มีข้อมูล "user exists" รั่วออกมาผ่าน error type หรือ error message
- [ ] DB error ที่ unexpected ถูก handle gracefully — ไม่ panic ไม่ expose internal error

## Concepts Involved

- `timing-attack` — response time สามารถเป็น side channel ได้, วิธีทำ constant-time operation → `shared/concepts/password-hashing.md`
- `user-enumeration` — ทำไม account existence เป็น sensitive info, generic error message pattern → (concept doc ยังไม่มี)

## Production Reality

- **ใช้จริง:** AWS Cognito, Auth0, และ authentication service ชั้นนำทุกเจ้าใช้ generic error message และ dummy computation
- **ข้อควรระวัง:** บาง use case จำเป็นต้องบอก user ว่า "email นี้ยังไม่ได้ลงทะเบียน" — trade-off ระหว่าง UX กับ security ต้องตัดสินใจตาม threat model
- **kata สอนว่า:** security ไม่ได้อยู่แค่ logic — performance characteristic ของ code ก็เป็น attack surface ได้
