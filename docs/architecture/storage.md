# Storage, filesystems, and initramfs

**Purpose:** describe the M18 storage path: PCI discovery, the legacy virtio-blk
polling driver, the block interface, the read-only FAT driver, the minimal VFS,
and the Limine-module initramfs reader.

**Implementation status:** M18 is **IMPLEMENTED** for the polling path, FAT16,
FAT32, the VFS, and the tar initramfs. Modern virtio, MSI-X, filesystem writes,
and FAT12 are **PLANNED** or **DEFERRED** as noted below.

## Status at a glance

| Feature | Status | Source |
| --- | --- | --- |
| Legacy PCI config space (`0xCF8`/`0xCFC`) enumeration | **IMPLEMENTED** | [`src/drivers/pci.zig`](../../src/drivers/pci.zig) |
| PCI BAR decoding (I/O, MMIO, 64-bit) | **IMPLEMENTED** | [`src/drivers/pci.zig`](../../src/drivers/pci.zig) |
| PCI capability walk | **IMPLEMENTED** | [`src/drivers/pci.zig`](../../src/drivers/pci.zig) |
| PCI ECAM/MCFG | **PLANNED** | Not implemented. |
| Legacy virtio-blk (virtio 0.9.5) polling | **IMPLEMENTED** | [`src/drivers/virtio_blk.zig`](../../src/drivers/virtio_blk.zig) |
| Modern virtio 1.0 | **PLANNED** | The driver reports `ModernOnly` instead of guessing. |
| MSI-X completion | **PLANNED** | M18 deliberately uses polling. |
| Block read/write at a sector LBA | **IMPLEMENTED** | [`src/fs/block.zig`](../../src/fs/block.zig) |
| Read-only FAT16 | **IMPLEMENTED** | [`src/fs/fat.zig`](../../src/fs/fat.zig) |
| Read-only FAT32 | **IMPLEMENTED** | [`src/fs/fat.zig`](../../src/fs/fat.zig) |
| VFAT long file names | **IMPLEMENTED** | [`src/fs/fat.zig`](../../src/fs/fat.zig) |
| FAT12 | **PLANNED** | Rejected as `UnsupportedFat12`. |
| FAT writes, create, delete, rename | **PLANNED** | The driver is read-only. |
| Minimal mount table and file reads | **IMPLEMENTED** | [`src/fs/vfs.zig`](../../src/fs/vfs.zig) |
| ustar/PAX-compatible tar reads | **IMPLEMENTED** | [`src/fs/tar.zig`](../../src/fs/tar.zig) |
| Limine-module initramfs | **IMPLEMENTED** | [`src/initramfs.zig`](../../src/initramfs.zig) |
| Shared storage bring-up | **IMPLEMENTED** | [`src/storage.zig`](../../src/storage.zig) |
| Generated FAT disk image and tar fixture | **IMPLEMENTED** | [`tools/mkdisk.py`](../../tools/mkdisk.py), [`tools/mkinitramfs.py`](../../tools/mkinitramfs.py) |

## Boot wiring

[`src/storage.zig`](../../src/storage.zig) is the shared bring-up path. Normal
boot calls it after the memory, SMP, and timer layers and logs a non-fatal
summary:

```text
storage: pci=<n> virtio=<0|1> fat=<0|1> initramfs=<0|1>
```

The selftest calls the same function and then exercises the returned handles.
The sequence is:

1. `pci.init()` scans bus 0-255, slot 0-31, and every function of a
   multi-function device using the legacy configuration mechanism.
2. `virtio_blk.init()` finds the transitional/legacy virtio-blk device
   (`vendor 0x1af4`, device `0x1001`), enables I/O and bus-master access, resets
   the device, negotiates zero guest features, allocates one physically
   contiguous virtqueue, and sets `DRIVER_OK`.
3. `fat.mount()` reads sector 0 through the block interface, validates the BPB,
   and records the FAT type and data-region geometry.
4. `vfs.mount("/", fat.vfsBackend(&volume))` exposes the FAT files.
5. `initramfs.find()` reads the Limine module response, and the tar archive is
   mounted at `/initramfs`.
6. In the selftest, `process.spawn()` loads `INIT.ELF` from the FAT volume
   through the same process model used by M17.

A machine without a legacy virtio-blk device still boots; `storage.init`
reports `virtio=0` and leaves the VFS empty. This keeps the storage stack from
becoming a boot prerequisite before there is a userland that depends on it.

## PCI

Only the legacy configuration mechanism is implemented. `read32` writes the
address to port `0xCF8` and reads the dword from `0xCFC`; byte and word reads
extract the field from an aligned dword. Enumeration is BSP-only and runs once.

Firmware has already assigned BARs, so the driver decodes but never relocates
them. A 64-bit memory BAR consumes the next BAR slot, which is why the decoder
records the original slot index before advancing. The capability walk follows
the linked list from config offset `0x34` when status bit 4 is set, with a
bounded step count.

## Legacy virtio-blk

The register layout is the legacy one:

| Offset | Register |
| --- | --- |
| `0x00` | host features |
| `0x04` | guest features |
| `0x08` | queue address (PFN) |
| `0x0c` | queue size |
| `0x0e` | queue select |
| `0x10` | queue notify |
| `0x12` | device status |
| `0x14` | capacity (64-bit) |

The driver negotiates no optional features. It uses one queue, one outstanding
request, and a three-descriptor chain: a 16-byte block request header, a
512-byte data buffer, and a one-byte status. Reads set the device-write flag on
the data descriptor; writes clear it and copy the caller's sector into the
bounce buffer first.

The descriptor table, available ring, and used ring live in one
`pmm.allocContiguous` allocation. The driver verifies through `vmm.translate`
that the HHDM mapping is physically contiguous, because the device receives
physical addresses while the driver writes through the direct map. The used ring
starts on a 4096-byte boundary, as the legacy interface requires.

Completion is polling: after publishing the available-ring index and notifying
the device, the driver spins on the used-ring index with a bounded `pause` loop.
It compares the device index against its own count of consumed completions
rather than sampling the device index immediately before notifying; otherwise a
device that completes before the driver polls would make the driver wait for a
completion that already happened. A timeout returns `false`; there is no
interrupt path in M18. `block.Device` serializes requests with an IRQ-safe
spinlock.

## Block layer

[`src/fs/block.zig`](../../src/fs/block.zig) defines the smallest interface the
filesystems need:

```zig
pub const Device = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, lba: u64, buffer: []u8) bool,
    write_fn: ?*const fn (*anyopaque, lba: u64, buffer: []const u8) bool = null,
    sector_size: u32 = 512,
    sector_count: u64 = 0,
};
```

`read` and `write` reject zero-length or partial-sector buffers and refuse to
run past a known capacity. A `sector_count` of zero means the capacity is
unknown. FAT uses only reads; the selftest uses the optional write path for a
single scratch sector.

## FAT16/FAT32

`fat.mount` accepts 512-byte logical sectors only. It computes the root
directory size, the first data sector, and the cluster count, then selects the
type from the BPB:

- a non-zero 16-bit FAT size means FAT16; fewer than 4085 clusters is rejected
  as FAT12;
- a zero 16-bit FAT size means FAT32; fewer than 65525 clusters or a root
  cluster below 2 is rejected as corrupt.

Paths are ASCII, case-insensitive, and separated by `/` or `\`. Directory
iteration handles short 8.3 entries and VFAT long names, including names split
across directory sectors. The `..` component is rejected as
`UnsupportedPath`; there is no parent tracking.

File reads are stateless: the caller supplies an entry and an offset, and the
driver walks the cluster chain from the first cluster to the cluster containing
that offset. This is O(chain length) per read and deliberately simple. Every
FAT and directory sector read uses a 512-byte stack buffer, so the driver owns
no mutable global state and needs no lock beyond the block device's.

The `vfsBackend` adapter packs the first cluster and file size into the VFS
entry token. FAT itself never allocates.

## VFS

The VFS is a fixed eight-entry mount table. A backend provides `open` and
`read` function pointers, and a `File` carries the backend pointer, an opaque
entry, and a caller-owned offset. Opening does not allocate and a `File` can be
copied without invalidating anything.

Mount matching uses the longest matching prefix. `/` and `/initramfs` therefore
coexist, and `/initramfs/HELLO.TXT` reaches the tar archive while
`/HELLO.TXT` reaches FAT. This is intentionally not a POSIX VFS: there are no
inodes, permissions, directory streams, writes, or `..` resolution.

The mount table is written once during boot and is not locked. That is safe for
the current single-threaded mount/read use; concurrent mounts are not supported
(see [technical debt](../development/technical-debt.md)).

## Initramfs

[`src/limine.zig`](../../src/limine.zig) adds a module request and a `File`
layout matching the Limine protocol. `initramfs.find()` selects the first module
whose `MODULE_STRING` or path contains `initramfs` and exposes its mapped bytes.

[`src/fs/tar.zig`](../../src/fs/tar.zig) walks 512-byte ustar headers, validates
the checksum, honours the `prefix` field, and returns the data offset of regular
files (`typeflag` `'0'` or NUL). Directories, links, and PAX extended headers are
skipped. Reads are in place; nothing is copied at mount time.

The test harness generates `initramfs.tar` with `HELLO.TXT` and
`SUB/NESTED.TXT`, passes it through `boot/limine.conf` as a module, and mounts
it at `/initramfs`.

## Test fixtures

[`tools/mkdisk.py`](../../tools/mkdisk.py) builds a 4 MiB FAT16 image with one
sector per cluster, two FATs, 64 root entries, and these files:

| File | Purpose |
| --- | --- |
| `HELLO.TXT` | Single-cluster file read through FAT and the VFS. |
| `BIG.BIN` | 1300-byte multi-cluster file with a deterministic byte pattern. |
| `INIT.ELF` | A copy of `src/user/proc.elf`, loaded and run through the process model. |
| `SUB/NESTED.TXT` | Subdirectory lookup. |

The final disk sector is left outside every allocated cluster and is used for
the raw write/read pattern test. The script uses only Python's standard library;
it needs no root, loop device, `mtools`, `xorriso`, or `losetup`.

[`tools/mkinitramfs.py`](../../tools/mkinitramfs.py) writes a deterministic
ustar archive with the two text files above.

## Validation

The M18 selftest asserts:

- PCI enumeration finds a legacy virtio-blk device with an I/O BAR;
- the device reports the generated 8192-sector capacity and a non-zero queue;
- sector 0 has the FAT boot signature and `ZIGKERNL` OEM name;
- a pattern written to the final sector reads back identically;
- the FAT16 volume mounts with 8123 clusters;
- `/HELLO.TXT`, `/SUB/NESTED.TXT`, and the 1300-byte `/BIG.BIN` read through
  the VFS;
- the Limine-module tar contains `HELLO.TXT` with different contents from the
  FAT file, and `/initramfs/HELLO.TXT` resolves through the longest-prefix mount;
- `INIT.ELF` loads from FAT, runs, exits 42, and is reaped with an empty process
  table.

Host unit tests build FAT16 and FAT32 images in memory and cover mounting,
short-name lookup, subdirectories, multi-cluster reads, offsets, the boot
signature check, tar lookup/checksum rejection, and VFS longest-prefix matching.

## Limitations

- Polling only: no MSI-X, no virtio interrupts, one outstanding request.
- Legacy virtio only: the driver returns `ModernOnly` when it finds a modern
  device ID and no legacy device.
- FAT is read-only; FAT12 is rejected; sector size must be 512 bytes; `..` is
  not resolved; reads restart the cluster walk instead of caching.
- The VFS has no permissions, directory streams, writes, or concurrent mount
  support.
- `INIT.ELF` is loaded from FAT but the ring-3 syscall ABI is still the M16
  test ABI; there is no `open`/`read` syscall yet.
- The test disk image is generated per run and is not a general-purpose image
  builder.
