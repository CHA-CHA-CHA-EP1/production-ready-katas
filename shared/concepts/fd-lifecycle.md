# Concept: File Descriptor Lifecycle

## File Descriptor คืออะไร

เวลาโปรแกรมเปิดไฟล์ ระบบปฏิบัติการไม่ได้คืน "ไฟล์" มาให้ตรงๆ — แต่คืน **integer** ตัวเล็กๆ เช่น `3`, `4`, `5` ที่เรียกว่า **file descriptor (fd)**

fd นี้เป็นแค่ index เข้าไปใน **file descriptor table** ที่ kernel เก็บไว้ต่อ process ซึ่งข้างในเก็บข้อมูลจริงเช่น inode, offset ปัจจุบัน, สิทธิ์การเข้าถึง

```
process fd table         kernel file table
┌─────────────┐          ┌──────────────────────────────┐
│ fd 0 (stdin)│ ───────► │ inode, offset, flags, ...    │
│ fd 1 (stdout│ ───────► │ inode, offset, flags, ...    │
│ fd 2 (stderr│ ───────► │ inode, offset, flags, ...    │
│ fd 3        │ ───────► │ inode=/etc/app/config, off=0 │
│ fd 4        │ ───────► │ inode=/var/log/app.log, off= │
└─────────────┘          └──────────────────────────────┘
```

## Lifecycle: เปิด → ใช้ → ปิด

```
open(path) ──► kernel allocates fd ──► read/write ──► close(fd) ──► kernel frees fd
```

ทุกครั้งที่เรียก `open` kernel จะหา fd ที่เล็กที่สุดที่ยังว่างอยู่แล้วส่งกลับมา
ทุกครั้งที่เรียก `close` kernel จะคืน fd นั้นกลับเข้า pool

## FD Leak คืออะไร และทำไมถึงอันตราย

**FD leak** เกิดเมื่อโปรแกรมเปิดไฟล์แล้ว **ไม่ close** ทุก code path — โดยเฉพาะ error path

**Go:**
```go
// leak: ถ้า process() return error ก่อน, f.Close() ไม่ถูกเรียก
f, _ := os.Open(path)
data, err := process(f)
if err != nil {
    return err  // ← fd รั่วตรงนี้
}
f.Close()
```

**Rust (leak ไม่เกิด เพราะ Drop):**
```rust
// Rust: fd leak ไม่เกิดแบบนี้ — Drop จัดการให้เสมอ
// แต่ leak ยังเกิดได้ถ้าใช้ ManuallyDrop หรือ mem::forget
let f = std::fs::File::open(path)?;
let data = process(&f);
if data.is_err() {
    return Err(data.unwrap_err()); // f ยัง drop ที่นี่ — fd ถูกปิด
}
// f drop ที่นี่เช่นกัน
```

**Zig (leak ถ้าไม่ใช้ defer):**
```zig
// ❌ leak เหมือน Go ถ้าไม่ใช้ defer
const f = try std.fs.cwd().openFile(path, .{});
const data = process(f) catch |err| {
    return err; // fd รั่วตรงนี้ถ้าไม่มี defer
};
f.close();

// ✅ ถูกต้อง
const f = try std.fs.cwd().openFile(path, .{});
defer f.close();
const data = try process(f);
```

**ผลลัพธ์:**
- แต่ละ process มี fd limit (Linux default: 1024, ดูได้จาก `ulimit -n`)
- เมื่อถึง limit ทุก `open()` จะ fail ด้วย `too many open files`
- ระบบหยุดทำงาน — ทั้ง HTTP server, DB connection, log write ล้วน open fd ทั้งนั้น

**การ leak มักไม่โชว์ใน dev** เพราะ:
- Process อายุสั้น (restart บ่อย) → fd ถูก OS คืนให้อัตโนมัติตอน process ตาย
- Traffic น้อย → ไม่ถึง limit
- โชว์ใน production ที่ process อยู่นาน + traffic สูง

## วิธีจัดการ FD ในแต่ละภาษา

**Go:**
```go
f, err := os.Open(path)
if err != nil {
    return err
}
defer f.Close()  // ← ปิดแน่นอน ไม่ว่า code path ไหน

// อ่าน/ใช้ f ได้เลย
```

`defer` รัน **ก่อน function return เสมอ** ไม่ว่าจะ return ปกติหรือ return error

**Rust:**
```rust
// Rust ใช้ Drop trait — File ถูก close อัตโนมัติเมื่อออกนอก scope
// ไม่ต้องเรียก close() เอง — compiler บังคับ
fn read_config(path: &str) -> std::io::Result<Vec<u8>> {
    let mut f = std::fs::File::open(path)?; // เปิด
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)?;              // อ่าน
    Ok(buf)
    // f ถูก drop ตรงนี้ → close() ถูกเรียกอัตโนมัติ ทุก code path
}
```

**Zig:**
```zig
fn readConfig(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close(); // เหมือน Go's defer — รันก่อน return ทุก path

    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    _ = try f.readAll(buf);
    return buf;
}
```

## ตรวจสอบ FD ที่เปิดอยู่

```bash
# ดู fd ทั้งหมดของ process (macOS/Linux)
lsof -p <pid>

# นับจำนวน fd ที่ process เปิดอยู่
lsof -p <pid> | wc -l

# ดู limit ของ process ปัจจุบัน
ulimit -n
```

## Linux: มองเห็น FD จริงด้วย `/proc`

Linux expose fd ที่เปิดอยู่ผ่าน virtual filesystem `/proc`:

```bash
# ดู fd ทั้งหมดของ process ใน Linux
ls -la /proc/<pid>/fd/

# ตัวอย่าง output
lrwxrwxrwx 1 root root 0 ... 0 -> /dev/null
lrwxrwxrwx 1 root root 0 ... 1 -> /dev/null
lrwxrwxrwx 1 root root 0 ... 2 -> /dev/null
lrwxrwxrwx 1 root root 0 ... 3 -> /etc/app/config.json
lrwxrwxrwx 1 root root 0 ... 4 -> socket:[12345]

# นับจำนวน fd ที่เปิดอยู่
ls /proc/<pid>/fd | wc -l

# ดู soft/hard limit ของ process
cat /proc/<pid>/limits | grep "open files"
```

แต่ละ entry เป็น symlink ชี้ไปยัง resource จริง — ไม่ว่าจะเป็นไฟล์, socket, pipe, หรือ device

## Linux: FD Limit — Soft vs Hard

Linux มี 2 ระดับ:

```
soft limit  — limit ที่ใช้จริงตอนนี้ (process สามารถเพิ่มเองได้ถึง hard limit)
hard limit  — เพดานสูงสุด (เพิ่มได้เฉพาะ root)
```

```bash
# ดู soft/hard limit ของ shell ปัจจุบัน
ulimit -Sn   # soft
ulimit -Hn   # hard

# เพิ่ม soft limit ชั่วคราว (ถ้าต่ำกว่า hard limit)
ulimit -n 65536

# ดู system-wide limit
cat /proc/sys/fs/file-max       # limit รวมทั้ง OS
cat /proc/sys/fs/file-nr        # allocated / free / max
```

Production server มักตั้ง soft limit ที่ 65536 หรือสูงกว่า เพราะ service อย่าง Nginx, database, หรือ Go HTTP server เปิด fd ได้มากในเวลาเดียวกัน

## Linux: Three-Table Model

Linux ใช้ 3 table ในการจัดการไฟล์:

```
process fd table       open file table (kernel)      inode table
┌──────────────┐       ┌──────────────────────┐      ┌──────────────┐
│ fd 3 ────────┼──────►│ flags: O_RDONLY       │─────►│ inode 42     │
│ fd 4 ────────┼──┐    │ offset: 1024          │      │ /etc/passwd  │
└──────────────┘  │    │ ref_count: 1          │      │ size: 2048   │
                  │    └──────────────────────┘      └──────────────┘
                  │    ┌──────────────────────┐      ┌──────────────┐
                  └───►│ flags: O_RDWR         │─────►│ inode 42     │  ← ไฟล์เดียวกัน
                       │ offset: 0             │      │ ref_count: 2 │     เปิด 2 ครั้ง
                       │ ref_count: 1          │      └──────────────┘
                       └──────────────────────┘
```

- **fd table** — per-process, เก็บ index เข้า open file table
- **open file table** — kernel-wide, เก็บ state ต่อการเปิด (offset, flags)
- **inode table** — kernel-wide, เก็บ metadata ของไฟล์จริง (size, permissions, disk location)

เปิดไฟล์เดิม 2 ครั้ง → ได้ 2 entry ใน open file table (offset แยกกัน) → ชี้ inode เดิม

## Linux: `fork()` และ FD Inheritance

เมื่อ process `fork()` ลูก child **ได้รับ copy ของ fd table ทั้งหมด** จาก parent:

```
parent process          child process (after fork)
fd 3 → config.json      fd 3 → config.json  ← ชี้ open file entry เดียวกัน!
fd 4 → socket           fd 4 → socket
```

**ผลที่ตามมา:**
- ถ้า parent มี fd leak → child ก็ inherit fd เหล่านั้นมาด้วย
- socket ที่ parent เปิดไว้ → child ปิดไม่ได้จนกว่า parent จะปิดด้วย (เพราะ ref_count > 0)

**แก้ด้วย `O_CLOEXEC`** — flag ที่บอก kernel ว่า "ปิด fd นี้อัตโนมัติเมื่อ exec()"

```go
// Go ใช้ O_CLOEXEC โดย default ตั้งแต่ Go 1.5
f, err := os.Open(path)  // ← ใน Linux จะ set O_CLOEXEC อัตโนมัติ
```

## ระดับลึก: Kernel Internals

เบื้องหลัง `os.Open` ใน Go เรียก syscall `open(2)` บน Linux
Kernel เก็บ fd table ใน `struct files_struct` ต่อ task (process)
แต่ละ entry ชี้ไป `struct file` ที่ shared ได้ข้าม process (กรณี `fork` / `dup`)

```bash
# ดู syscall ที่โปรแกรมเรียกจริง (Linux only)
strace -e trace=openat,close,read ./your-program

# ตัวอย่าง output
openat(AT_FDCWD, "/etc/app/config.json", O_RDONLY|O_CLOEXEC) = 3
read(3, "app.name=foo\n", 4096)         = 13
close(3)                                 = 0
```

fd 0, 1, 2 ถูก allocate ให้อัตโนมัติตอน process เริ่ม:
- `0` = stdin
- `1` = stdout
- `2` = stderr

ดังนั้น fd แรกที่โปรแกรม open เองมักได้เลข `3`
