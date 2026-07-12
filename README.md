# production-ready-katas

A collection of hands-on coding exercises for engineers who already know how to code — but want to understand what's *really* happening when their code runs in production.

---

## Who this is for

Senior engineers who are fluent in one language and picking up another (e.g. Go, Rust, Zig), but find that tutorials and AI-generated code leave gaps in their mental model of:

- What the OS is actually doing when you open a file
- Why the naive approach works locally but breaks in production
- How to read stdlib documentation instead of copying examples

If you've ever shipped code that passed all local tests but caused a `too many open files` at 2am — this is for you.

---

## Philosophy

**1. See the problem before the solution**

Every kata starts with the naive approach and why it breaks. You don't get the "right way" until you understand the failure mode.

**2. Real incidents, not toy examples**

Each exercise is grounded in real production incidents — OOM loops, fd leaks, symlink attacks. The context is always "this actually happened."

**3. Read the source, not the tutorial**

The `Explore First` section in each kata gives you method names to look up in the stdlib — not examples to copy. You're expected to open `go to definition` and read.

**4. One spec, multiple languages**

Problem definitions live in `shared/` and are language-agnostic. Each language has its own implementation folder. Same kata, different idioms — good for comparison.

---

## Structure

```
production-ready-katas/
├── shared/
│   ├── concepts/          # Background reading: OS behavior, memory, I/O
│   ├── assignment-specs/  # Language-agnostic kata definitions
│   │   ├── file-handling/
│   │   ├── compression-encryption/
│   │   ├── networking/
│   │   ├── cloud-storage/  # S3-compatible (MinIO) + AWS-specific katas
│   │   ├── concurrency/
│   │   ├── data-handling/
│   │   ├── resilience-and-consistency/
│   │   └── system-design/ # Architecture & system design katas
│   └── scenarios/         # End-to-end exercises combining multiple katas
├── skills/                # AI review skills (kata-review, system-design-review)
├── go/                    # Go implementations
├── rust/                  # Rust implementations
└── zig/                   # Zig implementations
```

### Kata spec format

Each kata follows this structure:

| Section | Purpose |
|---|---|
| **Context** | Why this problem matters in real systems |
| **Real World Incidents** | Actual production failures caused by this mistake |
| **The Naive Way** | What most people write first, and exactly where it breaks |
| **Explore First** | Method names to look up in stdlib — no examples, just hints |
| **Task** | What you need to build |
| **Requirements** | Constraints that prevent you from taking shortcuts |
| **Acceptance Criteria** | Testable checklist — all must pass |
| **Concepts Involved** | Links to background reading in `shared/concepts/` |

---

## Domains

Katas are grouped by domain. Numbering within each group goes from naive baseline (01) to increasingly complex patterns — not overall difficulty.

| Domain | Description |
|---|---|
| `file-handling` | Read patterns, write patterns, encoding, resource management, edge cases, integrity, testing |
| `compression-encryption` | Stream-based compress/decompress, encrypt/decrypt for large files |
| `networking` | Download with retry/resume, upload/multipart, pipe without temp files |
| `cloud-storage` | S3/GCS-style object storage — upload/download, multipart, presigned URLs, Lambda pipelines, encryption |
| `concurrency` | File locking, TOCTOU race conditions |
| `data-handling` | datetime, timezone, encoding, parsing |
| `resilience-and-consistency` | Atomic writes, crash recovery, consistency guarantees |
| `system-design` | Architecture katas — design distributed systems from real incidents |
| `authentication` | Password hashing, JWT, OAuth2, MFA, WebAuthn/Passkeys |

### Cloud-storage provider note

Katas marked **S3-compatible** run on [MinIO](https://min.io/) locally (no AWS account needed).
Katas marked **AWS only** require an AWS account and IAM credentials.

---

## Start here

Not sure where to begin? Read these in order:

1. **[Whole-File Read kata](shared/assignment-specs/file-handling/01-read-patterns/01-whole-file-read.md)** — the first kata, a good example of the full format
2. **[fd-lifecycle](shared/concepts/fd-lifecycle.md)** — background reading referenced by the kata above
3. Pick a language folder (`go/`, `rust/`, `zig/`) and implement it

The kata spec tells you what to build. `Explore First` tells you where to look. The concept docs explain the *why*.

---

## Current content

### Katas available

#### file-handling
| Kata | Difficulty |
|---|---|
| [Whole-File Read](shared/assignment-specs/file-handling/01-read-patterns/01-whole-file-read.md) | 1 |

#### resilience-and-consistency
| Kata | Difficulty |
|---|---|
| [Atomic Write](shared/assignment-specs/resilience-and-consistency/01-write-patterns/01-atomic-write.md) | 2 |

#### cloud-storage (S3-compatible — runs on MinIO)
| Kata | Difficulty |
|---|---|
| [Streaming Upload](shared/assignment-specs/cloud-storage/01-streaming-upload.md) | 1 |
| [Streaming Download](shared/assignment-specs/cloud-storage/02-streaming-download.md) | 1 |
| [Upload with Checksum](shared/assignment-specs/cloud-storage/03-upload-with-checksum.md) | 2 |
| [Multipart Upload](shared/assignment-specs/cloud-storage/04-multipart-upload.md) | 2 |
| [Resumable Upload](shared/assignment-specs/cloud-storage/05-resumable-upload.md) | 3 |
| [Upload with Retry](shared/assignment-specs/cloud-storage/06-upload-with-retry.md) | 2 |
| [Concurrent Upload](shared/assignment-specs/cloud-storage/07-concurrent-upload.md) | 2 |
| [Orphaned Part Cleanup](shared/assignment-specs/cloud-storage/08-orphaned-part-cleanup.md) | 2 |
| [Presigned Upload (PUT)](shared/assignment-specs/cloud-storage/09-presigned-upload.md) | 1 |
| [Presigned Download (GET)](shared/assignment-specs/cloud-storage/10-presigned-download.md) | 1 |
| [Presigned POST](shared/assignment-specs/cloud-storage/11-presigned-post.md) | 2 |
| [Upload Confirm Pattern](shared/assignment-specs/cloud-storage/12-upload-confirm-pattern.md) | 2 |
| [Client-side Encrypt Upload](shared/assignment-specs/cloud-storage/22-client-side-encrypt-upload.md) | 2 |
| [Stream Decrypt Download](shared/assignment-specs/cloud-storage/23-stream-decrypt-download.md) | 2 |

#### cloud-storage (AWS only)
| Kata | Difficulty |
|---|---|
| [CloudFront Signed Cookies](shared/assignment-specs/cloud-storage/13-cloudfront-signed-cookies.md) | 3 |
| [S3 Event → Webhook](shared/assignment-specs/cloud-storage/14-s3-event-webhook.md) | 2 |
| [Lambda Authorizer + Presigned URL](shared/assignment-specs/cloud-storage/15-lambda-authorizer-presigned.md) | 2 |
| [Post-upload Processing](shared/assignment-specs/cloud-storage/16-post-upload-processing.md) | 2 |
| [Upload → Virus Scan → Approve](shared/assignment-specs/cloud-storage/17-upload-virus-scan-approve.md) | 3 |
| [Multi-step Pipeline with Status](shared/assignment-specs/cloud-storage/18-multi-step-pipeline-status.md) | 3 |
| [S3 Object Lambda](shared/assignment-specs/cloud-storage/19-s3-object-lambda.md) | 3 |
| [SSE-S3 vs SSE-KMS](shared/assignment-specs/cloud-storage/20-sse-s3-vs-sse-kms.md) | 1 |
| [Envelope Encryption](shared/assignment-specs/cloud-storage/21-envelope-encryption.md) | 3 |

#### system-design
| Kata | Difficulty |
|---|---|
| [Config Distribution Service](shared/assignment-specs/system-design/01-config-distribution-service.md) | 1 |

#### authentication
| Kata | Difficulty |
|---|---|
| [Password Hashing](shared/assignment-specs/authentication/01-password-hashing.md) | 1 |
| [API Key Storage](shared/assignment-specs/authentication/02-api-key-storage.md) | 2 |
| [User Enumeration Prevention](shared/assignment-specs/authentication/03-user-enumeration-prevention.md) | 2 |
| [Secure Cookie Flags](shared/assignment-specs/authentication/04-secure-cookie-flags.md) | 1 |
| [JWT Validation](shared/assignment-specs/authentication/05-jwt-validation.md) | 2 |
| [JWT Algorithm Confusion](shared/assignment-specs/authentication/06-jwt-algorithm-confusion.md) | 3 |
| [Token Refresh Pattern](shared/assignment-specs/authentication/07-token-refresh-pattern.md) | 2 |
| [Token Revocation](shared/assignment-specs/authentication/08-token-revocation.md) | 3 |
| [Basic Auth](shared/assignment-specs/authentication/09-basic-auth.md) | 1 |
| [Bearer Token Storage](shared/assignment-specs/authentication/10-bearer-token-storage.md) | 2 |
| [TOTP / MFA](shared/assignment-specs/authentication/11-totp-mfa.md) | 3 |
| [Re-auth for Sensitive Ops](shared/assignment-specs/authentication/12-reauth-sensitive-ops.md) | 2 |
| [OAuth2 State Parameter](shared/assignment-specs/authentication/13-oauth2-state-parameter.md) | 2 |
| [PKCE Flow](shared/assignment-specs/authentication/14-pkce-flow.md) | 3 |
| [WebAuthn / Passkeys](shared/assignment-specs/authentication/15-webauthn-passkeys.md) | 3 |

### Concept docs available

| Concept | Description |
|---|---|
| [fd-lifecycle](shared/concepts/fd-lifecycle.md) | File descriptors, OS limits, `/proc`, fork inheritance, strace |
| [error-wrapping](shared/concepts/error-wrapping.md) | `%w`, `errors.Is/As`, errno, syscall error chain |
| [memory-allocation](shared/concepts/memory-allocation.md) | Heap, page cache, virtual memory, OOM Killer, mmap |
| [datetime-timezone](shared/concepts/datetime-timezone.md) | UTC storage, timezone conversion, parse formats |
| [password-hashing](shared/concepts/password-hashing.md) | bcrypt/argon2, work factor, salt, timing attacks |
| [jwt](shared/concepts/jwt.md) | JWT structure, claims, signing algorithms, algorithm confusion |
| [session-management](shared/concepts/session-management.md) | Cookie flags, session fixation, CSRF, session lifecycle |
| [mfa](shared/concepts/mfa.md) | TOTP algorithm, backup codes, MFA fatigue, SMS vs hardware key |
| [oauth2](shared/concepts/oauth2.md) | OAuth2 flows, PKCE, state parameter, token types |
| [webauthn](shared/concepts/webauthn.md) | Passkeys, public key crypto, phishing-resistance, sign counter |

### Skills (AI review guides)

| Skill | Description |
|---|---|
| [kata-review](skills/kata-review.md) | Review code implementation against kata spec |
| [kata-challenge](skills/kata-challenge.md) | Spot-the-Bug challenge after kata review |
| [review-system-design-kata](skills/review-system-design-kata.md) | Review system design diagram + decisions |

---

## Roadmap

### Near term
- [ ] Go implementations for cloud-storage katas (MinIO-based)
- [ ] MinIO local setup guide (`go/cloud-storage/README.md`)
- [ ] Kata: `02-streaming-read` — reading large files without loading into memory
- [ ] Concept doc: what "stream" actually means (not just files — stdin, network, pipe)
- [ ] Concept doc: bytes, characters, and encoding fundamentals

### Medium term
- [ ] GitHub Actions CI — auto-run tests per language on push
- [ ] Rust implementations for file-handling katas
- [ ] First scenario: "process a large file from S3, resume if interrupted"
- [ ] More system-design katas (rate limiter, log aggregation pipeline)

### Open decisions
- Kata template: lean (4 sections) vs full (all sections) — currently using full for all
- Scenario prerequisites: hard gate or soft recommendation?
- TDD starter tests: provide failing tests per kata, or let engineers write their own?

---

## Contributing

If you want to add a kata, concept doc, or language implementation:

1. Kata specs go in `shared/assignment-specs/<domain>/` — keep them language-agnostic
2. Follow the section format above — especially `Real World Incidents` and `Explore First`
3. Concept docs go in `shared/concepts/` — include both approachable explanation and OS-level depth
4. Implementations go in `<language>/<domain>/` mirroring the spec path
