---
kata: file-handling/01-read-patterns/01-whole-file-read
language: rust
---

# Solve: Whole-File Read (Rust)

## Final Implementation

```rust
use std::{
    io::{self, Read},
    os::unix::fs::OpenOptionsExt,
    path::Path,
};

use thiserror::Error;

#[derive(Debug, Error)]
enum ReadConfigError {
    #[error("readConfig: file too large")]
    FileTooLarge,
    #[error("readConfig: file is symlink")]
    FileIsSymlink,
    #[error("readConfig: io: {source}")]
    Io {
        #[from]
        source: io::Error,
    },
}

const MAX_FILE_SIZE: u64 = 1024 * 1024;

fn read_config<P>(path: P) -> Result<Vec<u8>, ReadConfigError>
where
    P: AsRef<Path>,
{
    let mut f = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)
        .map_err(|e| {
            if e.raw_os_error() == Some(libc::ELOOP) {
                ReadConfigError::FileIsSymlink
            } else {
                ReadConfigError::Io { source: e }
            }
        })?;

    let size = f.metadata()?.len();
    if size > MAX_FILE_SIZE {
        return Err(ReadConfigError::FileTooLarge);
    }

    let mut buf = Vec::with_capacity(size as usize);
    f.read_to_end(&mut buf)?;

    Ok(buf)
}
```

## Key Decisions

### 1. `O_NOFOLLOW` แทน `is_symlink()`

```rust
// ❌ broken — File::open follows symlink ก่อน return, is_symlink() จะเป็น false เสมอ
let f = File::open(path)?;
if f.metadata()?.is_symlink() { ... }

// ✅ atomic — kernel ปฏิเสธ symlink ตอน open เลย ไม่มี TOCTOU
.custom_flags(libc::O_NOFOLLOW)
.map_err(|e| match e.raw_os_error() {
    Some(libc::ELOOP) => ReadConfigError::FileIsSymlink,
    _ => ReadConfigError::Io { source: e },
})
```

### 2. `metadata().len()` บน open fd — ไม่ใช่ path

```rust
// ❌ stat path — TOCTOU: ไฟล์อาจเปลี่ยนระหว่าง stat กับ open
let size = std::fs::metadata(path)?.len();

// ✅ stat fd ที่เปิดอยู่แล้ว — atomic กับ open
let size = f.metadata()?.len();
```

### 3. `read_to_end` แทน `read_exact`

```rust
// ❌ ถ้าไฟล์ shrink ระหว่างอ่าน → UnexpectedEof
let mut buf = vec![0u8; size as usize];
f.read_exact(&mut buf)?;

// ✅ handle file resize gracefully, capacity hint ลด realloc
let mut buf = Vec::with_capacity(size as usize);
f.read_to_end(&mut buf)?;
```

### 4. Return `Vec<u8>` ไม่ใช่ `String`

caller รู้ format ของ config — บางอย่างเป็น TOML, บางอย่างเป็น binary
การ convert เป็น UTF-8 ใน `read_config` ทำให้ function รับงานเกินหน้าที่

### 5. fd lifecycle — Rust จัดการเองผ่าน `Drop`

ไม่มี `defer` ใน Rust — `File` implement `Drop` ซึ่ง close fd อัตโนมัติเมื่อ `f` ออกจาก scope
ทุก path (success, error, early return) fd ถูกปิดแน่นอน

## Gotchas ที่เจอระหว่างทำ

| Gotcha | อาการ | Fix |
|---|---|---|
| `is_symlink()` บน open fd | always false — open ตาม symlink ไปแล้ว | `O_NOFOLLOW` + `map_err` ELOOP |
| ลืม `?` หลัง `read_to_end` | read error ถูก silently ignored | compiler warn (`#[must_use]`) แต่ไม่ error — ต้องระวัง |
| `Utf8` error variant ที่ไม่ได้ใช้ | dead code warning หลัง return type เปลี่ยนเป็น `Vec<u8>` | ลบ variant + import ออก |
| `.size()` จาก `MetadataExt` | Unix-only, ต้อง import extra trait | ใช้ `.len()` จาก standard `Metadata` แทน |

## Concept Docs

- `shared/concepts/path-security.md` — TOCTOU, O_NOFOLLOW, symlink attack
- `shared/concepts/fd-lifecycle.md` — Drop trait, fd leak
- `shared/concepts/memory-allocation.md` — OOM risk, size check before read
