---
name: kata-review
description: Generic review template for any kata implementation — read this before reviewing code
---

# Kata Review Guide

## How to use

**Required inputs:**
1. **Language** — `go`, `rust`, or `zig` (determines which idioms and checks apply)
2. **Kata spec path** — e.g. `shared/assignment-specs/file-handling/01-read-patterns/01-whole-file-read.md`
3. **Implementation file(s)** — the code to review

**Usage:**
```
"Read skills/kata-review.md first, then review <file> against kata spec <spec-path> (language: <lang>)"
```

The AI will load the kata spec, review the code against the dimensions below, and present findings in an easy-to-read format.

---

## Review Dimensions

### 1. Correctness
- Does the logic match the kata **Task** and **Requirements**?
- Are all edge cases specified in the kata handled?
- Is the output correct (byte-for-byte or matching the spec)?
- **Acceptance Criteria check:** Go through each criterion in the kata spec and verify pass/fail explicitly.

### 2. Resource Management
- Are file descriptors, memory, and background tasks released on every path (both success and error)?
- **Go:** Is `defer` placed correctly — after the error check, not before?
- **Rust:** Is ownership/borrowing correct? Any `ManuallyDrop` or `mem::forget` that could leak?
- **Zig:** Is `defer` / `errdefer` used correctly? What happens if `openFile` fails — does `defer` still run?
- Any resources that could leak under concurrent usage?

### 3. Error Handling
- Are all error paths covered?
- Do error messages provide enough context (not just "failed")?
- **Go:** Is error wrapping correct — does `%w` preserve the chain so `errors.Is` / `errors.As` still work?
- **Rust:** Is `ErrorKind` used for classification? Does `.context()` from anyhow/thiserror add useful info?
- **Zig:** Are error switches exhaustive? Are OS errors mapped to meaningful domain errors?

### 4. Concurrency Safety
- Is there any shared mutable state?
- If so, is it guarded?
  - **Go:** mutex, channel, atomic
  - **Rust:** `Mutex`, `RwLock`, `Atomic*`, channel — or does the borrow checker enforce it at compile time?
  - **Zig:** `std.Thread.Mutex`, atomic operations
- Is the function safe to call from multiple threads simultaneously?

### 5. Security
- **Symlink validation:** Does the code validate that a user-supplied path is not a symlink before reading? (relevant when path comes from external input)
- **Path traversal:** Could a user-controlled path escape the intended directory? (e.g. `../../../etc/passwd`)
- **Error message information leak:** Does any error message expose file content, internal paths, or environment variables that shouldn't be visible to the caller?
- **TOCTOU race conditions:** Is there a gap between checking a condition (e.g. file size) and acting on it, where the file could change in between?

### 6. Language Idioms
- Does naming follow the language's conventions?
- Is the stdlib used appropriately, or is there logic that duplicates what stdlib already provides?
- Does anything feel unidiomatic?
  - **Go:** returning concrete types instead of interfaces, naked goroutines without lifecycle control, missing `context.Context`
  - **Rust:** unnecessary `clone()`, `unwrap()` in library code, `String` where `&str` suffices
  - **Zig:** ignoring error sets (using `catch unreachable`), missing `errdefer` for cleanup on error, allocating where a slice would suffice

### 7. Testability & Observability
- Are error paths tested, or only the happy path?
- Can failure modes be tested without real OS side effects? (e.g. temp dir, mock filesystem, permission test)
- Are there tests for the acceptance criteria from the kata spec?
- In production, would you be able to detect this failure? (log, metric, alert — or silent failure?)

### 8. Production Gap
- In what real-world scenarios would this code fail in production?
- Are there assumptions that hold in dev but break in prod (e.g. file size, concurrent access, network conditions, container filesystem)?
- Is this the pattern production systems actually use, or is there a better pattern or library for this use case?
- Compare against the **Production Reality** section in the kata spec — does the implementation align?

### 9. Kata Quality
- Is the kata spec still accurate and relevant, or has the stdlib / ecosystem moved on?
- Do the Acceptance Criteria cover all important cases, or are there cases worth adding?
- Is any part of the spec misleading or ambiguous — should any questions be revised?

---

## Concept Doc Reference

When a finding falls into one of these categories, link to the relevant concept doc for deeper understanding:

| Finding category | Concept doc | When to reference |
|---|---|---|
| fd leak, `too many open files`, `defer` placement | `shared/concepts/fd-lifecycle.md` | Any resource management issue with file descriptors |
| error wrapping, `%w`, `errors.Is/As`, errno | `shared/concepts/error-wrapping.md` | Any error handling or error chain issue |
| OOM, heap allocation, whole-file read size | `shared/concepts/memory-allocation.md` | Any memory-related finding or size validation issue |
| timezone, UTC storage, parse format | `shared/concepts/datetime-timezone.md` | Any datetime-related kata |

---

## After Review: Reinforce Understanding

After presenting all dimensions, always do both of the following:

### 10. Explain It Back
Pick the 1-2 most important findings from the review and ask the user to explain them in their own words.

The goal is not to quiz — it's to surface gaps between "I followed the fix" and "I actually understand why."

**Example questions (Go):**
- "Why does `LimitReader` need `+1` instead of just `MAX_FILE_SIZE`?"
- "What would happen if you called `defer file.Close()` before the error check?"
- "Why does `rename` give us atomicity but `write` doesn't?"

**Example questions (Rust):**
- "Why does `File` not need an explicit `close()` — what happens when it goes out of scope?"
- "What's the difference between `?` and `unwrap()` here — why does this kata require `?`?"
- "If `read_to_end` returns `Ok(buf)`, who owns `buf` and when does it get freed?"

**Example questions (Zig):**
- "What happens if `openFile` fails — does `defer` still execute? Why or why not?"
- "Why does Zig require an explicit allocator here — what would happen with a hidden allocator?"
- "What's the difference between `defer` and `errdefer` — when would you need `errdefer` instead?"

If the user explains correctly — confirm and move on.
If the explanation is off — clarify the concept, link to the relevant concept doc in `shared/concepts/`.

### 11. Pattern Connections
If any finding in this review resembles something from a previous kata, call it out explicitly.

Example:
- "This is the same fd leak pattern from `01-whole-file-read` — `defer` in the wrong place"
- "The size check issue here is the TOCTOU problem — same class of bug as what `LimitReader` was added to fix"
- "The error wrapping here is the same pattern from `error-wrapping.md` — missing `%w` breaks `errors.Is`"

Also connect findings to **concept docs** when relevant:
- "This fd leak → read `shared/concepts/fd-lifecycle.md` section on 'FD Leak คืออะไร'"
- "This OOM risk → read `shared/concepts/memory-allocation.md` section on 'OOM Killer'"

Connecting patterns across katas and concept docs builds a mental model, not just isolated fixes.

---

## Output Format

Present each dimension like this:

```
## Review: [kata name] (language: [go/rust/zig])

### [Dimension] [✅ / ⚠️ / ❌]
[Short summary — pass or what the issue is]
[If issue — include line number and what to fix]

### Acceptance Criteria
- [x] criterion 1 — passed
- [ ] criterion 2 — FAILED: [reason]
- [x] criterion 3 — passed

---
Must fix before prod: [N] items
Fix when you can: [N] items
Kata spec suggestions: [yes / none]
Concept docs to read: [list relevant docs]
```

**Legend:**
- ✅ Pass — nothing to change
- ⚠️ Should improve — not critical but worth fixing
- ❌ Must fix — will break in production
