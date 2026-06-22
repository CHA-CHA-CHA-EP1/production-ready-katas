# Concept: Error Wrapping

## ปัญหาของ error เปล่าๆ

เวลา error เกิดลึกในระบบแล้วส่งขึ้นมาโดยไม่มี context เพิ่ม:

```
open /etc/app/config.json: no such file or directory
```

ถ้า codebase ใหญ่ขึ้น error แบบนี้ไม่บอกว่า "ใคร" เรียก open, "ทำไม" ถึง open ไฟล์นั้น
ต้องไปไล่ stack trace หรือ grep code เองว่ามาจากไหน

**Error wrapping** แก้ปัญหานี้ด้วยการเพิ่ม context ทุกชั้นที่ส่ง error ขึ้นไป:

```
ReadConfig: open /etc/app/config.json: no such file or directory
     ↑                    ↑
  context ที่เพิ่ม      original error จาก OS
```

## วิธี Wrap Error ในแต่ละภาษา

### Go: `fmt.Errorf` + `%w` (Go 1.13+)

**Go:**
```go
func ReadConfig(path string) ([]byte, error) {
    f, err := os.Open(path)
    if err != nil {
        return nil, fmt.Errorf("ReadConfig: %w", err)
    }
    // ...
}
```

**Rust:**
```rust
use std::fmt;

#[derive(Debug)]
struct ReadConfigError {
    source: std::io::Error,
    path: String,
}

impl fmt::Display for ReadConfigError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "ReadConfig {}: {}", self.path, self.source)
    }
}

// หรือใช้ `anyhow` crate ที่ง่ายกว่า:
use anyhow::Context;
fn read_config(path: &str) -> anyhow::Result<Vec<u8>> {
    std::fs::read(path)
        .with_context(|| format!("ReadConfig: {}", path))
}
```

**Zig:**
```zig
// Zig ใช้ error union — error type กำหนดตอน compile
const ReadConfigError = error{
    FileNotFound,
    PermissionDenied,
    FileTooLarge,
    ReadFailed,
};

fn readConfig(path: []const u8) ReadConfigError![]u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.PermissionDenied,
        else => return error.ReadFailed,
    };
    defer f.close();
    // ...
}
```

`%w` (wrap) ต่างจาก `%v` (format เป็น string) ตรงที่:
- `%w` เก็บ original error ไว้ข้างใน สามารถ unwrap ได้ภายหลัง
- `%v` แปลงเป็น string ทันที ข้อมูล type และ value ของ error หายไป

### Unwrap: `errors.Is` และ `errors.As`

เพราะ error ถูก wrap ไว้ การเช็คด้วย `==` จะไม่ทำงาน:

```go
err := ReadConfig("/nonexistent")

// ❌ ไม่ work — err เป็น wrapped error ไม่ใช่ *PathError โดยตรง
if err == os.ErrNotExist { }

// ✅ errors.Is unwrap ลงไปหา os.ErrNotExist ในทุก layer
if errors.Is(err, os.ErrNotExist) {
    // handle not found
}

// ✅ errors.As ดึง concrete type ออกมาจาก chain
var pathErr *os.PathError
if errors.As(err, &pathErr) {
    fmt.Println(pathErr.Path) // "/nonexistent"
}
```

**`errors.Is`** — เช็คว่า error chain มี error ที่ตรงกับ target ไหม (เปรียบเทียบด้วย `==` หรือ `.Is()` method)
**`errors.As`** — เช็คว่า error chain มี error ที่ type ตรงกับ target ไหม แล้วดึงออกมา

## Convention การตั้งชื่อ Context

รูปแบบที่อ่านง่ายที่สุด: `"FunctionName: ข้อความสั้นๆ ถ้าจำเป็น: %w"`

```go
// ดี: บอก function และ operation
fmt.Errorf("ReadConfig: read file: %w", err)

// ดี: บอก function เดียวพอถ้าชัดเจน
fmt.Errorf("ReadConfig: %w", err)

// หลีกเลี่ยง: ใส่ "error" หรือ "failed" ซ้ำซ้อน
fmt.Errorf("ReadConfig error: failed to read: %w", err)
// → อ่านแล้ว เหมือนบอกว่า "มี error เกิดขึ้น" ซึ่งรู้อยู่แล้วว่าเป็น error
```

## อย่า Wrap ซ้ำสองชั้นในที่เดียวกัน

```go
// ❌ wrap สองครั้งใน function เดียว
f, err := os.Open(path)
if err != nil {
    wrapped := fmt.Errorf("open failed: %w", err)
    return nil, fmt.Errorf("ReadConfig: %w", wrapped)
}

// ✅ wrap ครั้งเดียวต่อ function
f, err := os.Open(path)
if err != nil {
    return nil, fmt.Errorf("ReadConfig: %w", err)
}
```

## Sentinel Errors

บางครั้งเราอยากให้ caller เช็ค error ประเภทเฉพาะ สร้าง **sentinel error** ไว้เลย:

```go
var ErrFileTooLarge = errors.New("file exceeds size limit")

func ReadConfig(path string) ([]byte, error) {
    // ...
    if size > maxSize {
        return nil, fmt.Errorf("ReadConfig: %w", ErrFileTooLarge)
    }
}

// caller เช็คได้
if errors.Is(err, ErrFileTooLarge) {
    // handle specifically
}
```

## Linux: errno — ที่มาของ Error จาก OS

เมื่อ syscall ล้มเหลว Linux kernel คืน **errno** — integer ที่บอกสาเหตุ:

```
ENOENT  =  2   → No such file or directory
EACCES  = 13   → Permission denied
EMFILE  = 24   → Too many open files (per-process limit)
ENFILE  = 23   → Too many open files in system (system-wide limit)
ENOSPC  = 28   → No space left on device
EROFS   = 30   → Read-only file system
```

Go map errno เหล่านี้มาเป็น `syscall.Errno` และ OS ห่อเป็น `*os.PathError` อีกชั้น:

**Go:**
```go
// error chain จาก os.Open ที่ล้มเหลว:
// *os.PathError
//   └── Op: "open"
//       Path: "/etc/app/config.json"
//       Err: syscall.ENOENT (errno 2)

f, err := os.Open("/nonexistent")
// err.Error() → "open /nonexistent: no such file or directory"

var pathErr *os.PathError
errors.As(err, &pathErr)
pathErr.Err == syscall.ENOENT  // true
```

**`os.ErrNotExist`** เป็น sentinel ที่ Go map มาจาก `syscall.ENOENT` (และ errno อื่นที่มีความหมายเดียวกัน)
ใช้ `errors.Is(err, os.ErrNotExist)` แทนการเช็ค errno ตรงๆ เพื่อ portability

**Rust:**
```rust
use std::io::ErrorKind;

match std::fs::File::open("/nonexistent") {
    Err(e) if e.kind() == ErrorKind::NotFound => {
        // ENOENT — ไม่พบไฟล์
    }
    Err(e) if e.kind() == ErrorKind::PermissionDenied => {
        // EACCES — ไม่มีสิทธิ์
    }
    _ => {}
}
// e.raw_os_error() คืน errno integer จาก OS โดยตรง
```

**Zig:**
```zig
const f = std.fs.cwd().openFile("/nonexistent", .{}) catch |err| switch (err) {
    error.FileNotFound => { /* ENOENT */ },
    error.AccessDenied => { /* EACCES */ },
    error.ProcessFdQuotaExceeded => { /* EMFILE */ },
    else => return err,
};
// Zig map errno เป็น error value ตอน compile — type-safe กว่า Go
```

```bash
# ดู errno จาก syscall จริง (Linux)
strace -e trace=openat ./your-program 2>&1
# openat(AT_FDCWD, "/nonexistent", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
#                                                          ↑ errno อยู่ตรงนี้
```

## ระดับลึก: Error Chain

`fmt.Errorf("...: %w", err)` สร้าง struct ที่ implement interface นี้:

```go
type interface {
    Error() string
    Unwrap() error  // คืน wrapped error
}
```

`errors.Is` และ `errors.As` เรียก `Unwrap()` วนไปเรื่อยๆ จนถึง nil หรือเจอ match
ทำให้ error chain ลึกแค่ไหนก็ตามก็ยัง unwrap ได้ถูกต้อง

สำหรับ file error chain จะลึก 3 ชั้น:
```
fmt.Errorf("ReadConfig: %w", err)   ← ชั้นที่เราเพิ่ม
  └── *os.PathError                  ← Go standard library เพิ่ม
        └── syscall.Errno (ENOENT)   ← kernel ส่งมา
```
