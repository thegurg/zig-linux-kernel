//! Kernel heap: a first-fit free-list allocator over lazily mapped pages.
//!
//! The heap owns a fixed 64 MiB virtual range. `grow` asks the PMM for physical
//! pages, maps them with the VMM, zeroes them, and adds the new region to a
//! sorted free list. Allocations use a 32-byte header immediately before the
//! returned pointer; freeing a block inserts it back in address order and
//! coalesces adjacent free blocks.
//!
//! The allocator also implements `std.mem.Allocator` (resize/remap are not
//! supported yet, so callers fall back to allocate-copy-free).
//!
//! All allocator state is protected by `heap_lock`, an IRQ-safe spinlock. The
//! lock is held while growing the heap, which maps pages through the VMM, so the
//! lock order is heap -> `vmm.table_lock` -> `pmm.lock`. The grow path never
//! unmaps pages: a partial failure adds the mapped prefix to the free list and
//! leaves the remaining reserved range unused, so the heap lock is never held
//! across a TLB shootdown.

const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const sync = @import("../sync.zig");

const page_size: usize = @intCast(pmm.page_size);

/// Reserved virtual range for the kernel heap. Kept well away from the kernel
/// image and the HHDM.
pub const base: usize = 0xffffffff90000000;
pub const reserved_bytes: usize = 64 * 1024 * 1024;
const limit: usize = base + reserved_bytes;

const initial_grow_bytes: usize = 64 * 1024;
const min_block_size: usize = 64;
const magic: u64 = 0x4b48_4541_504d_3143; // "KHEAPM1C"

const FreeBlock = extern struct {
    size: usize,
    next: ?*FreeBlock,
};

const Header = extern struct {
    magic: u64,
    block_start: usize,
    total_size: usize,
    requested: usize,
};

const header_size: usize = @sizeOf(Header);

var free_head: ?*FreeBlock = null;
/// Next unreserved virtual address. `heap_mapped_bytes` counts pages actually
/// mapped, which can be smaller after a partial grow failure.
var heap_brk: usize = base;
var heap_mapped_bytes: usize = 0;
var initialized = false;
var heap_lock: sync.IrqSpinLock = .{};

pub const Stats = struct {
    reserved_bytes: usize,
    mapped_bytes: usize,
    free_bytes: usize,
    allocated_bytes: usize,
};

pub fn init() void {
    const guard = heap_lock.acquire();
    defer guard.release();

    free_head = null;
    heap_brk = base;
    heap_mapped_bytes = 0;
    initialized = true;
}

pub fn alloc(size: usize, alignment: usize) ?[*]u8 {
    if (!initialized or size == 0) return null;
    if (!std.math.isPowerOfTwo(alignment)) return null;

    const size_aligned = alignUp(size, 8) orelse return null;
    const overhead = add(header_size, alignment) orelse return null;
    const needed = add(size_aligned, overhead) orelse return null;

    const guard = heap_lock.acquire();
    defer guard.release();

    if (findBlock(size_aligned, alignment, size)) |ptr| return ptr;
    if (!growLocked(needed)) return null;
    return findBlock(size_aligned, alignment, size);
}

pub fn free(ptr: [*]u8, size: usize) void {
    if (!initialized or @intFromPtr(ptr) == 0) return;

    const guard = heap_lock.acquire();
    defer guard.release();

    const user_addr = @intFromPtr(ptr);
    if (user_addr < base + header_size or user_addr >= heap_brk) return;

    const header: *Header = @ptrFromInt(user_addr - header_size);
    if (header.magic != magic) return;
    if (size != 0 and size != header.requested) return;

    const block_start = header.block_start;
    const total_size = header.total_size;
    if (block_start < base or block_start >= heap_brk) return;
    if (total_size < header_size or total_size > heap_brk - block_start) return;
    if (total_size % 8 != 0) return;

    header.magic = 0;
    addFreeBlock(block_start, total_size);
}

pub fn stats() Stats {
    const guard = heap_lock.acquire();
    defer guard.release();

    var free_bytes: usize = 0;
    var current = free_head;
    while (current) |block| {
        free_bytes += block.size;
        current = block.next;
    }
    return .{
        .reserved_bytes = reserved_bytes,
        .mapped_bytes = heap_mapped_bytes,
        .free_bytes = free_bytes,
        .allocated_bytes = heap_mapped_bytes - free_bytes,
    };
}

/// The standard allocator interface, for code that wants `std.mem.Allocator`.
pub const allocator: std.mem.Allocator = .{
    .ptr = &allocator_state,
    .vtable = &vtable,
};

var allocator_state: u8 = 0;

const vtable = std.mem.Allocator.VTable{
    .alloc = allocRaw,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = freeRaw,
};

fn allocRaw(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    return alloc(len, alignment.toByteUnits());
}

fn freeRaw(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    _ = alignment;
    free(memory.ptr, memory.len);
}

fn findBlock(size_aligned: usize, alignment: usize, requested: usize) ?[*]u8 {
    var previous: ?*FreeBlock = null;
    var current = free_head;

    while (current) |block| {
        const block_addr = @intFromPtr(block);
        const start = add(block_addr, header_size) orelse return null;
        const user_addr = alignUp(start, alignment) orelse return null;
        const total = add(user_addr - block_addr, size_aligned) orelse return null;

        if (total <= block.size) {
            return allocateFrom(previous, block, user_addr, total, requested);
        }

        previous = block;
        current = block.next;
    }
    return null;
}

fn allocateFrom(
    previous: ?*FreeBlock,
    block: *FreeBlock,
    user_addr: usize,
    total: usize,
    requested: usize,
) [*]u8 {
    const block_addr = @intFromPtr(block);
    const block_size = block.size;
    const next = block.next;

    var allocation_size = total;
    const suffix_size = block_size - total;
    if (suffix_size >= min_block_size) {
        const suffix: *FreeBlock = @ptrFromInt(block_addr + total);
        suffix.* = .{ .size = suffix_size, .next = next };
        if (previous) |prev| prev.next = suffix else free_head = suffix;
    } else {
        // Too small to be useful on its own; keep it with the allocation.
        allocation_size = block_size;
        if (previous) |prev| prev.next = next else free_head = next;
    }

    const header: *Header = @ptrFromInt(user_addr - header_size);
    header.* = .{
        .magic = magic,
        .block_start = block_addr,
        .total_size = allocation_size,
        .requested = requested,
    };
    return @ptrFromInt(user_addr);
}

fn growLocked(needed: usize) bool {
    if (!initialized) return false;

    const wanted = @max(needed, initial_grow_bytes);
    const bytes = alignUp(wanted, page_size) orelse return false;
    if (heap_brk > limit or bytes > limit - heap_brk) return false;

    const start = heap_brk;
    heap_brk += bytes;
    const pages = bytes / page_size;
    var mapped: usize = 0;

    while (mapped < pages) : (mapped += 1) {
        const virt = start + mapped * page_size;
        const phys = pmm.allocPage() orelse {
            accountPartialGrowth(start, mapped);
            return false;
        };
        if (!vmm.mapPage(@intCast(virt), phys, vmm.kernel_rw)) {
            _ = pmm.freePage(phys);
            accountPartialGrowth(start, mapped);
            return false;
        }
        const ptr: [*]u8 = @ptrFromInt(virt);
        @memset(ptr[0..page_size], 0);
    }

    heap_mapped_bytes += bytes;
    addFreeBlock(start, bytes);
    return true;
}

/// A failed grow keeps the pages mapped before the failure and returns them to
/// the free list. The reserved virtual range past `mapped` pages stays unused.
/// Unmapping here would require a TLB shootdown while `heap_lock` is held, so
/// the allocator deliberately leaks that address space instead.
fn accountPartialGrowth(start: usize, mapped: usize) void {
    const mapped_bytes = mapped * page_size;
    if (mapped_bytes == 0) return;
    heap_mapped_bytes += mapped_bytes;
    addFreeBlock(start, mapped_bytes);
}

fn addFreeBlock(addr: usize, size: usize) void {
    if (size < @sizeOf(FreeBlock)) return;

    const block: *FreeBlock = @ptrFromInt(addr);
    block.* = .{ .size = size, .next = null };

    var previous: ?*FreeBlock = null;
    var current = free_head;
    while (current) |candidate| {
        if (@intFromPtr(candidate) >= addr) break;
        previous = candidate;
        current = candidate.next;
    }

    block.next = current;
    if (previous) |prev| prev.next = block else free_head = block;

    if (block.next) |next| {
        if (addr + block.size == @intFromPtr(next)) {
            block.size += next.size;
            block.next = next.next;
        }
    }

    if (previous) |prev| {
        if (@intFromPtr(prev) + prev.size == addr) {
            prev.size += block.size;
            prev.next = block.next;
        }
    }
}

fn alignUp(value: usize, alignment: usize) ?usize {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return null;
    const mask = alignment - 1;
    if (value > std.math.maxInt(usize) - mask) return null;
    return (value + mask) & ~mask;
}

fn add(a: usize, b: usize) ?usize {
    if (a > std.math.maxInt(usize) - b) return null;
    return a + b;
}
