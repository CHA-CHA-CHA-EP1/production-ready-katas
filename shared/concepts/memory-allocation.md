# Concept: Memory Allocation และ Whole-File Read

## Whole-File Read โหลดอะไรเข้า Memory

เมื่อเรียก `os.ReadFile(path)` หรืออ่านทั้งไฟล์ด้วย `io.ReadAll`:

1. Kernel อ่านข้อมูลจาก disk เข้า **page cache** (kernel memory)
2. Go runtime allocate `[]byte` slice บน **heap** (user space memory)
3. ข้อมูลถูก copy จาก page cache → Go heap
4. ฟังก์ชันคืน slice นั้นมาให้

```
disk ──► kernel page cache ──► Go heap ([]byte)
                                   ↑
                              โปรแกรมใช้ตรงนี้
```

**ผลลัพธ์:** ไฟล์ 100 MB = Go heap โตขึ้น 100 MB ทันที

## เมื่อไรใช้ Whole-File Read ได้

Whole-file read เหมาะเมื่อ:
- ไฟล์มีขนาด **จำกัดและรู้ล่วงหน้า** เช่น config file, certificate, template
- ต้องการ content ทั้งหมด **พร้อมกัน** เช่น parse JSON, unmarshal YAML
- ขนาดไฟล์ **เล็กเทียบกับ available RAM** อย่างชัดเจน

ไม่เหมาะเมื่อ:
- ไฟล์ใหญ่หรือขนาดไม่แน่นอน (log file, data export, media file)
- ต้องการอ่านแค่บางส่วน (seek ไปอ่านตรงกลาง)
- ต้องการประมวลผลแบบ streaming (ไม่ต้องรอข้อมูลครบก่อน)

## ทำไมต้อง Validate ขนาดก่อน

```go
// อันตราย: ถ้า path ชี้ไปหาไฟล์ 10 GB จะ OOM
data, err := io.ReadAll(f)

// ปลอดภัยกว่า: เช็ค size ก่อนโหลด
info, err := f.Stat()
if info.Size() > maxSize {
    return nil, ErrFileTooLarge
}
data, err := io.ReadAll(f)
```

**ความเสี่ยงที่พบในระบบจริง:**
- Config path ถูก symlink ไปชี้ไฟล์ขนาดใหญ่โดยไม่ตั้งใจ
- ผู้ใช้ส่ง path มาเอง (user input) — อาจเป็นไฟล์ใหญ่ได้เสมอ
- ไฟล์ที่เคยเล็กโตขึ้นเรื่อยๆ ตามเวลา

## Dynamic Buffer ในแต่ละภาษา

`os.ReadFile` คืน `[]byte` ซึ่งเป็น slice:

**Go:**
```
[]byte header (24 bytes)        heap memory
┌──────────────────────┐       ┌─────────────────────────┐
│ ptr ─────────────────┼──────►│ a p p . n a m e = f o o │
│ len = 15             │       └─────────────────────────┘
│ cap = 15             │
└──────────────────────┘
```

- `ptr` ชี้ไปยัง backing array บน heap
- `len` = จำนวน byte ที่ใช้จริง
- `cap` = ขนาดที่ allocate ไว้ (อาจใหญ่กว่า len ถ้า runtime pre-allocate)

**Garbage Collection:** Go GC จะคืน memory นี้ให้อัตโนมัติ เมื่อไม่มีอะไร reference slice นั้นอีกแล้ว
แต่ถ้า slice ถูก pass ไปเก็บไว้ใน struct หรือ global variable GC จะยังไม่เก็บ

**Rust:**
```rust
// Vec<u8> — heap-allocated, growable buffer
let data: Vec<u8> = std::fs::read(path)?;
// Vec header: ptr + len + capacity (24 bytes on 64-bit)
// backing array อยู่บน heap เหมือนกัน
// Drop จัดการ free memory อัตโนมัติ — ไม่ต้องการ GC
```

**Zig:**
```zig
// Zig ต้องระบุ allocator เอง — ไม่มี implicit heap allocation
const allocator = std.heap.page_allocator;
const data = try allocator.alloc(u8, file_size);
defer allocator.free(data); // ต้อง free เอง

// หรือใช้ ArrayList
var buf = std.ArrayList(u8).init(allocator);
defer buf.deinit();
try file.reader().readAllArrayList(&buf, max_size);
```

## Stack vs Heap

ตัวแปรใน Go อาจอยู่บน stack หรือ heap ขึ้นอยู่กับ **escape analysis** ของ compiler

```go
func ReadConfig(path string) ([]byte, error) {
    // []byte ที่อ่านมา → ต้อง survive หลัง function return → อยู่บน heap
    data, err := io.ReadAll(f)
    return data, err
}
```

ข้อมูลขนาดใหญ่มักถูก allocate บน heap เสมอ เพราะ stack มีขนาดจำกัด (Go default: 8KB ขยายได้ถึง 1GB แต่ไม่ใช้แบบนั้นในทางปฏิบัติ)

## Linux: Virtual Memory vs Physical Memory

สิ่งที่โปรแกรมเห็นว่าเป็น "memory" ไม่ใช่ RAM จริงๆ — เป็น **virtual address space**:

```
virtual address space (process)     physical RAM
┌──────────────────────────────┐    ┌─────────────┐
│ 0x0000 - 0x7fff (user space) │    │ page frame  │
│   code segment               │───►│ page frame  │
│   heap  ← []byte อยู่ตรงนี้ │───►│ page frame  │
│   stack                      │───►│ page frame  │
├──────────────────────────────┤    │     ...     │
│ kernel space (ไม่ให้แตะ)    │    └─────────────┘
└──────────────────────────────┘
```

**ผลสำคัญ:** OS allocate memory เป็น **page** (ปกติ 4KB ต่อ page)
ไฟล์ 1 byte ก็ยัง allocate 1 page (4KB) ต่ำสุด — ทำให้ไฟล์เล็กมากๆ หลายล้านไฟล์กิน memory มากกว่าที่คิด

```bash
# ดู page size ของระบบ
getconf PAGE_SIZE   # มักได้ 4096
```

## Linux: ดู Memory ของ Process จริง

```bash
# ดู memory usage ของ process
cat /proc/<pid>/status | grep -E "VmRSS|VmSize|VmPeak"

# VmSize  — virtual memory ทั้งหมดที่ allocate (อาจใหญ่มาก แต่ยังไม่ใช้จริง)
# VmRSS   — Resident Set Size = RAM ที่ใช้จริงตอนนี้  ← ดูตัวนี้
# VmPeak  — RSS สูงสุดที่เคยใช้

# หรือใช้ tool สั้นกว่า
/usr/bin/time -v ./your-program 2>&1 | grep "Maximum resident"
```

## Linux: OOM Killer

เมื่อ RAM เต็ม Linux kernel จะเรียก **OOM Killer (Out-Of-Memory Killer)** เพื่อ kill process:

```
kernel: Out of memory: Kill process 1234 (your-service) score 847 or sacrifice child
kernel: Killed process 1234 (your-service) total-vm:2048000kB, anon-rss:1800000kB
```

**OOM Killer เลือก process โดย:**
- คำนวณ `oom_score` (0-1000) — ยิ่งสูงยิ่งถูก kill ก่อน
- Process ที่กิน memory เยอะ + อายุน้อย + ไม่มี flag พิเศษ → score สูง

**ผลใน production:**
- Service อาจถูก kill โดยไม่มี graceful shutdown
- Container บน Kubernetes จะ restart โดย kubelet (exit code 137 = killed by signal 9)
- Log บน node จะเห็น `OOM killed` แต่ application log อาจไม่มีอะไรเลย

```bash
# เช็คว่า process ถูก OOM kill หรือเปล่า
dmesg | grep -i "oom\|killed process"
cat /var/log/kern.log | grep "Out of memory"
```

## Linux: Page Cache ละเอียดขึ้น

```
disk ──► page cache (kernel) ──► process heap (user space)
              ↑
        เก็บไว้ใน RAM ของ OS ถ้ายังมีที่ว่าง
        ครั้งต่อไปที่อ่านไฟล์เดิม ไม่ต้องไปหา disk
```

Page cache กิน RAM เหมือนกัน — แต่ OS จัดการเอง:

```bash
# ดูขนาด page cache ปัจจุบัน
free -h
#              total   used   free  shared  buff/cache  available
# Mem:          15Gi   4.2Gi  2.1Gi   512Mi      9.1Gi      10Gi
#                                               ↑ นี่คือ page cache

# ล้าง page cache (ใช้ test เท่านั้น ไม่ทำใน production)
echo 3 > /proc/sys/vm/drop_caches
```

ดังนั้น "อ่านไฟล์เดิมซ้ำๆ" มักเร็วมากในทางปฏิบัติ เพราะ kernel serve จาก RAM
แต่ memory ของโปรแกรมยังคงโตขึ้นเท่าขนาดไฟล์เสมอ ไม่ว่า page cache จะมีหรือไม่

## Linux: `mmap` — ทางเลือกแทน Read

`mmap(2)` map ไฟล์เข้า virtual address space โดยตรง **โดยไม่ copy เข้า heap**:

```
page cache ──────────────────────► process virtual memory
               (mapped directly)        ↑
                                   access ผ่าน pointer ปกติ
                                   kernel โหลด page เมื่อ access จริง (lazy)
```

ใช้ได้เมื่ออยากอ่านไฟล์ใหญ่โดยไม่โหลดทั้งหมดเข้า heap — แต่มี tradeoff คือ complexity สูงกว่า
(Go ไม่มี built-in mmap ต้องใช้ `syscall.Mmap` หรือ library อย่าง `golang.org/x/sys/unix`)
