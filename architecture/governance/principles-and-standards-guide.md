# How to Write Architecture Principles and Standards

*Guide สำหรับ practice — เน้น short, actionable, enforceable*

---

## Principles vs Standards

| | Principle | Standard |
|---|---|---|
| **ความหมาย** | เป้าหมายหรือค่านิยมระดับสูง | กฎเฉพาะเจาะจงที่ enforce ได้ |
| **ตัวอย่าง** | "Design for failure" | "ทุก RDS ต้องเปิด Multi-AZ" |
| **วัดได้ไหม** | ไม่ตรงๆ | ได้ — pass หรือ fail |
| **เปลี่ยนบ่อยแค่ไหน** | เปลี่ยนน้อย — foundation | เปลี่ยนบ้างตามเทคโนโลยี |

ทั้งสองสิ่งนี้ต้องการ — principle อธิบาย "why" และ standard อธิบาย "what exactly"

---

## The Test of a Good Standard

Standard ที่ดีผ่านทุก test เหล่านี้:

1. **Testable:** reviewer สามารถ check ได้ชัดเจนว่า comply หรือไม่ — ไม่มี grey area
2. **Actionable:** บอกได้ว่าต้องทำอะไร ไม่ใช่แค่บอกว่าต้อง "ดี" หรือ "เหมาะสม"
3. **Scoped:** บอกชัดว่า apply กับ workload ไหน — ไม่ใช่ universal ทุกอย่าง
4. **Justified:** บอกได้ว่าทำไม — ถ้า teams ไม่เข้าใจ reason พวกเขาจะ resent หรือ bypass

---

## Standard Format

```markdown
## STD-[NNN]: [Short title]

**Statement:** [กฎ 1-2 ประโยค — อ่านแล้วรู้ทันทีว่า comply หรือ fail]

**Applies to:** [workload type, environment, service class]

**Rationale:** [เหตุผล 2-3 ประโยค — ทำไมถึงมีกฎนี้? มี incident อะไรที่ drive นี้?]

**How to comply:** [bullet points — ทำอะไรให้ได้ตาม standard]

**How to verify:** [คำถามหรือ check ที่ reviewer ใช้ verify]

**Exceptions:** [ถ้ามี legitimate exception — process คืออะไร? ดู exception-waiver-template.md]

**Last reviewed:** YYYY-MM-DD
```

---

## Examples of Good vs Bad Standards

### ❌ Bad standard (too vague)

> "All systems must implement appropriate security measures."

ปัญหา: "appropriate" คืออะไร? ใครเป็นคน judge? ไม่ testable ไม่ actionable

### ✅ Good standard

> **STD-001: Secrets must not be stored in code, configuration files, or environment variables**
>
> **Statement:** Credentials, API keys, database passwords, and private keys must be stored in AWS Secrets Manager or AWS SSM Parameter Store (SecureString). Storing these in environment variables, code, or `.env` files is not permitted.
>
> **Applies to:** All ECS tasks, Lambda functions, EC2 instances in production and UAT environments.
>
> **Rationale:** Secrets in env vars are visible in ECS task definitions, CloudTrail, and memory dumps. Rotation requires redeployment. Secrets Manager provides automatic rotation, audit trail, and encryption at rest.
>
> **How to comply:** Use `secrets` field in ECS task definition referencing Secrets Manager ARN. Lambda: use `AWS_SECRETS_MANAGER_ENDPOINT` or direct SDK call.
>
> **How to verify:** Check ECS task definition has no plaintext secrets in `environment` array. Check Lambda env vars for patterns matching `*_PASSWORD`, `*_SECRET`, `*_KEY`.

---

## Common Pitfalls When Writing Standards

**Too broad scope:** "All services must..." — มี legitimate exception มากเกินไปจน enforce ไม่ได้
→ Fix: ระบุ service class, environment, หรือ condition ที่ apply

**No rationale:** teams follow the letter not spirit → bypass ด้วย creative interpretation
→ Fix: ใส่ "why" เสมอ อ้างถึง incident ได้ถ้ามี

**No exception process:** teams encounter legitimate edge case → ต้อง break rule แบบ informal
→ Fix: ระบุ exception process ชัดๆ ใน standard

**Stale standards:** technology เปลี่ยนแต่ standard ไม่ update → team ignore เพราะรู้ว่า outdated
→ Fix: ระบุ "last reviewed" date และ review ทุก 12 เดือน

---

## Principle Examples for Practice

ลองเขียน standard สำหรับ principle เหล่านี้:

1. **"Design for failure"** — principle สูง แต่ standard ที่ testable จะพูดถึงอะไร?
2. **"Data encryption at rest"** — standard ที่ดีจะ specify อะไร? SSE-S3 vs SSE-KMS กำหนดเมื่อไร?
3. **"No single points of failure"** — testable standard สำหรับ database tier?
