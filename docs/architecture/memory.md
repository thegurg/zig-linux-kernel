# Memory management

**Purpose:** describe the three memory layers in zig-kernel: the physical page
allocator (PMM), the virtual memory manager (VMM), and the kernel heap.

**Implementation status:** all three layers are **IMPLEMENTED**. The PMM and VMM
are protected by IRQ-safe locks and the VMM issues a TLB shootdown after
unmapping a page. The heap is **PARTIAL**: its free list is not locked. The PMM
does not manage physical memory above 4 GiB.

## Layer overview

| Layer | Source | Responsibility |
| --- | --- | --- |
| PMM | [`src/memory/pmm.zig`](../../src/memory/pmm.zig) | Allocate and free 4 KiB physical pages from Limine's usable memory ranges. |
| VMM | [`src/memory/vmm.zig`](../../src/memory/vmm.zig) | Build and maintain 4-level page tables, map the kernel and HHDM, and switch `CR3`. |
| Heap | [`src/memory/heap.zig`](../../src/memory/heap.zig) | Provide aligned kernel allocations and a `std.mem.Allocator` adapter over a reserved virtual range. |

Page-table frames come from the PMM and are accessed through the HHDM. The HHDM
mapping is available both before and after the switch to the kernel's own page
tables, so VMM helpers can use the same address translation throughout.

## Physical memory manager (PMM)

### Design

The PMM is a bitmap allocator sized for a 4 GiB physical address space:

- `max_physical_address = 4 * 1024 * 1024 * 1024`.
- `page_size = 4096`.
- `used_bitmap`: one bit per page; 1 means reserved or allocated.
- `allocated_bitmap`: one bit per page; 1 means the page was returned by
  `allocPage` and may be freed.
- Both bitmaps live in the kernel image (`.bss`), so PMM initialization does not
  itself require allocating memory.
- `used_bitmap` starts completely full. Only memory-map entries of type
  `usable` are marked free, after aligning the range inward to page boundaries.
- The zero page is marked used after initialization so NULL-pointer bugs fault
  instead of silently succeeding.
- `total_pages` records the number of managed usable pages; `free_pages` tracks
  the current free count.

### API

| Function | Behavior |
| --- | --- |
| `init() InitError!void` | Reads Limine's memory map, marks usable pages free, reserves the zero page, and rejects a missing map or no usable memory. |
| `allocPage() ?u64` | Scans from `next_hint_word` for a zero bit, marks it used and allocated, decrements `free_pages`, and returns the physical address. |
| `freePage(address: u64) bool` | Validates alignment and range, requires the page to be in `allocated_bitmap`, clears both bits, increments `free_pages`, and lowers the hint. |
| `stats() Stats` | Returns `total_pages`, `free_pages`, and `used_pages`. |
| `totalBytes() u64` / `freeBytes() u64` | Convert the page counters to bytes. |

`freePage` rejects misaligned addresses, out-of-range addresses, pages that
were never allocated, the zero page, and double frees. This protects the kernel
image, firmware, framebuffer, MMIO, and other reserved ranges from accidental
release.

### Tests

The selftest in [`src/main.zig`](../../src/main.zig) allocates four pages and
checks that they are non-zero, page-aligned, below the managed limit, and
distinct. It verifies the free count, frees one page and checks reuse, rejects a
double free, a misaligned free, an out-of-range free, and freeing the zero
page, then returns the free count to its starting value.

### Limitations

- Physical memory above 4 GiB is not managed.
- The allocator is serialized by an IRQ-safe `sync.IrqSpinLock`; allocation and
  freeing are safe from multiple CPUs, but the lock is global rather than
  per-zone.
- The bitmap is statically sized for the 4 GiB cap.

## Virtual memory manager (VMM)

### Design

M1c replaces Limine's page tables with a 4-level PML4 built by the kernel:

- The kernel image is mapped at its linked higher-half address
  (`0xffffffff80000000`) from Limine's physical base.
- The first 4 GiB of physical memory is direct-mapped at Limine's HHDM offset
  using 2 MiB pages.
- Kernel text and rodata are mapped read-only; the Limine request section and
  data/bss are mapped read-write.
- The framebuffer's HHDM range is marked uncached (`cache_disable`) on the
  covering 2 MiB page-directory entries.
- `CR0.WP` is enabled so read-only mappings are enforced even in ring 0.
- `CR3` is loaded with the new PML4, and the global TLB is flushed by clearing
  and restoring `CR4.PGE` once.

The VMM rejects 5-level paging: the paging-mode response must report mode 0,
and `CR4.LA57` must be clear. Before switching `CR3`, `init` verifies that the
kernel text virtual address translates to the expected physical address and
that the HHDM offset translates to physical 0; a bad mapping returns
`BadKernelMapping` instead of triple-faulting on the first instruction fetch.

### API

| Function | Behavior |
| --- | --- |
| `init() InitError!void` | Builds the PML4, HHDM, and kernel mappings; validates them; marks the framebuffer uncached; enables `CR0.WP`; loads `CR3`. |
| `mapPage(virt, phys, flags) bool` | Maps one 4 KiB page, allocating intermediate tables as needed. Takes the IRQ-safe page-table lock. Rejects misalignment, out-of-range physical addresses, huge-page conflicts, and an already-present PTE. Invalidates the local TLB entry when active. |
| `unmapPage(virt) bool` | Clears a present 4 KiB PTE under the page-table lock, invalidates the local TLB entry, then invokes the registered TLB-shootdown callback after releasing the lock. Rejects missing or huge-page mappings. |
| `translate(virt) ?u64` | Walks the page tables manually and returns the physical address, including 1 GiB and 2 MiB huge-page offsets. |
| `stats() Stats` | Reports PML4 physical address, HHDM offset, kernel bases, kernel bytes, and HHDM bytes. |
| `currentPml4() u64` | Reads and masks `CR3`. |
| `hhdmOffset() u64` | Returns the cached Limine HHDM offset. |
| `kernelPhysical(virt) ?u64` | Converts a kernel-image virtual address to its physical address; only valid inside the image range. |
| `markUncached(phys, size) bool` | Sets `cache_disable` on the HHDM 2 MiB chunk(s) covering a physical range. Used for framebuffer and LAPIC MMIO. |
| `setTlbShootdownHandler(fn)` | Registers the scheduler callback invoked after an unmap releases the page-table lock. |

### Mapping layout

| Range | Mapping |
| --- | --- |
| `0xffffffff80000000` and up | Kernel image, page-by-page 4 KiB mappings with per-section permissions. |
| Limine HHDM offset | First 4 GiB of physical memory, 2 MiB pages, read-write; framebuffer pages uncached. |
| `0xffffffff90000000` .. `0xffffffff94000000` | Reserved virtual range for the kernel heap, mapped lazily by `heap.zig`. |
| Test-only range | `0xffffffffb0000000` is mapped and unmapped by the VMM selftest. |

The HHDM mapping requires the Limine offset to be 1 GiB aligned. Each 1 GiB
chunk gets a page directory of 2 MiB entries; the loop stops at the 4 GiB
managed limit.

### Limitations

- TLB shootdown waits for acknowledgements with a bounded spin. A target CPU
  that runs with interrupts disabled for a long time can delay completion; the
  shooter proceeds best-effort after the limit. See
  [technical debt](../development/technical-debt.md).
- There is no user-space mapping support, no copy-on-write, and no demand
  paging. The VMM maps and unmaps explicit pages only.
- The NX bit is not used; executable permissions are not separated beyond the
  read-only/read-write distinction.
- Page-table mutation is serialized by one IRQ-safe spinlock; there is no
  per-address-space or per-range locking.
- The HHDM covers only the first 4 GiB because the PMM manages only that range.

## Kernel heap

### Design

The heap owns a fixed 64 MiB virtual range:

- Base: `0xffffffff90000000`.
- Reserved size: `64 * 1024 * 1024` bytes, ending at `0xffffffff94000000`.
- Growth starts at 64 KiB per request and maps complete 4 KiB pages.
- Each allocation has a 32-byte `Header` immediately before the returned
  pointer. The header stores a magic value (`0x4b48_4541_504d_3143`,
  "KHEAPM1C"), the block start, the total block size, and the requested size.
- Minimum block size is 64 bytes.
- `grow` asks the PMM for pages, maps them with `vmm.mapPage(..., kernel_rw)`,
  zeroes them, advances `heap_brk`, and inserts the new region into a sorted
  free list.
- Allocation is first-fit with arbitrary power-of-two alignment.
- Freeing inserts the block in address order and coalesces with the next and
  previous free blocks.
- `resize` and `remap` are not implemented; the `std.mem.Allocator` adapter
  uses `noResize` and `noRemap`, so callers fall back to allocate-copy-free.

### API

| Function | Behavior |
| --- | --- |
| `init() void` | Clears the free list and resets the break to the heap base. |
| `alloc(size, alignment) ?[*]u8` | Returns an aligned block, growing the heap if no free block fits. Rejects zero size and non-power-of-two alignment. |
| `free(ptr, size) void` | Validates the header magic, block bounds, and optional size, then returns the block to the free list. |
| `stats() Stats` | Reports reserved, mapped, free, and allocated bytes. |
| `allocator` | `std.mem.Allocator` adapter backed by `alloc`/`free`. |

`grow` rolls back already-mapped pages if a later PMM allocation or VMM mapping
fails. The selftest allocates 64, 128, and 4096-byte blocks with different
alignments, verifies non-overlap and contents, frees and reuses a block, uses
the allocator adapter, rejects an allocation larger than the reserved range,
and checks the final free/mapped counters.

### Limitations

- The heap is not thread-safe; the PMM, VMM, console, and serial drivers use
  IRQ-safe locks.
- The reserved range is fixed at 64 MiB; there is no remapping or shrinking.
- There are no per-CPU arenas or size classes.
- `free` silently ignores unknown or corrupted pointers rather than reporting an
  error.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Physical page allocation/free | **IMPLEMENTED** | 4 GiB cap, double-free protection, zero page reserved. |
| 4-level paging and HHDM | **IMPLEMENTED** | Kernel image + first 4 GiB direct map. |
| Kernel text/rodata read-only | **IMPLEMENTED** | `CR0.WP` enabled. |
| Lazy kernel heap with allocator adapter | **IMPLEMENTED** | First-fit, coalescing, alignment. |
| Heap `resize`/`remap` | **PLANNED** | Not implemented; `noResize`/`noRemap` are used. |
| TLB shootdown | **IMPLEMENTED** | IPI 241 after `unmapPage`; bounded acknowledgement wait. |
| PMM/VMM locking | **IMPLEMENTED** | IRQ-safe allocator and page-table locks. |
| Heap locking | **PLANNED** | Free list is not safe for concurrent use. |
| Physical memory above 4 GiB | **PLANNED** | Not managed. |
| User-space mappings / demand paging | **PLANNED** | Not implemented. |

## Related documentation

- [Overview](overview.md)
- [Boot and early bring-up](boot.md)
- [SMP bring-up](smp.md)
- [Technical debt](../development/technical-debt.md)
- [Testing](../development/testing.md)
- [Roadmap](../development/roadmap.md)
