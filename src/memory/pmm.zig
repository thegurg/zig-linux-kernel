//! Physical memory manager: bitmap page allocator over Limine's memory map.
//!
//! The bitmap is sized for a 4 GiB physical address space and lives in the
//! kernel image (zero-initialised .bss), so bringing the allocator up does not
//! itself require allocating memory. Only `usable` memory-map ranges are ever
//! handed out; the kernel image, firmware, ACPI and MMIO ranges stay marked as
//! used because the bitmap starts out completely full.
//!
//! A second bitmap tracks which pages were actually returned by `allocPage`.
//! `freePage` refuses to free a page that was never allocated, so a caller
//! cannot accidentally release the kernel image or a firmware region.

const std = @import("std");
const limine = @import("../limine.zig");
const sync = @import("../sync.zig");

pub const page_size: u64 = 4096;

/// Highest physical address covered by the bitmap. Machines with more RAM keep
/// working; the extra memory is simply not managed (yet).
pub const max_physical_address: u64 = 4 * 1024 * 1024 * 1024;

const page_count: usize = @intCast(max_physical_address / page_size);
const bitmap_words: usize = page_count / 64; // page_count is a multiple of 64

/// One bit per page: 1 = not free (reserved or allocated).
var used_bitmap: [bitmap_words]u64 align(8) = undefined;
/// One bit per page: 1 = currently allocated through `allocPage`.
var allocated_bitmap: [bitmap_words]u64 align(8) = undefined;

var total_pages: usize = 0;
var free_pages: usize = 0;
var next_hint_word: usize = 0;
var initialized = false;

/// Serializes bitmap mutation. Allocation and freeing are short, so a single
/// IRQ-safe spinlock is enough for the current allocator.
var lock: sync.IrqSpinLock = .{};

pub const InitError = error{
    NoMemoryMap,
    NoUsableMemory,
};

pub const Stats = struct {
    total_pages: usize,
    free_pages: usize,
    used_pages: usize,
};

pub fn init() InitError!void {
    const memmap = limine.memmap() orelse return error.NoMemoryMap;

    @memset(&used_bitmap, ~@as(u64, 0));
    @memset(&allocated_bitmap, 0);
    total_pages = 0;
    free_pages = 0;
    next_hint_word = 0;

    var index: u64 = 0;
    while (index < memmap.entry_count) : (index += 1) {
        const entry = memmap.entries[index] orelse continue;
        if (entry.type != @backingInt(limine.MemmapEntryType.usable)) continue;

        const start = std.mem.alignForward(u64, entry.base, page_size);
        const end = std.mem.alignBackward(u64, entry.base +| entry.length, page_size);
        if (end <= start) continue;

        var address = start;
        while (address < end) : (address += page_size) {
            const page = address / page_size;
            if (page >= page_count) break;
            markFree(@intCast(page));
        }
    }

    if (free_pages == 0) return error.NoUsableMemory;

    // Keep the zero page out of the allocator so null-pointer bugs fault
    // instead of silently succeeding.
    markUsed(0);

    total_pages = free_pages;
    initialized = true;
}

pub fn allocPage() ?u64 {
    if (!initialized) return null;

    const guard = lock.acquire();
    defer guard.release();
    return allocPageLocked();
}

/// Allocate `count` physically contiguous pages. Used by DMA-capable devices
/// whose legacy virtqueue layout must live in one contiguous physical region.
pub fn allocContiguous(count: usize) ?u64 {
    if (!initialized or count == 0 or count > page_count) return null;

    const guard = lock.acquire();
    defer guard.release();

    var run: usize = 0;
    var start: usize = 0;
    var page: usize = 0;
    while (page < page_count) : (page += 1) {
        if (bitSet(&used_bitmap, page)) {
            run = 0;
            continue;
        }
        if (run == 0) start = page;
        run += 1;
        if (run < count) continue;

        var mark = start;
        while (mark < start + count) : (mark += 1) {
            setBit(&used_bitmap, mark);
            setBit(&allocated_bitmap, mark);
        }
        free_pages -= count;
        next_hint_word = start / 64;
        return @as(u64, @intCast(start)) * page_size;
    }

    return null;
}

/// Free a block returned by `allocContiguous`. Every page must have been
/// allocated, otherwise nothing is changed.
pub fn freeContiguous(address: u64, count: usize) bool {
    if (!initialized or count == 0 or address % page_size != 0) return false;

    const start: usize = @intCast(address / page_size);
    if (start + count > page_count) return false;

    const guard = lock.acquire();
    defer guard.release();

    var page = start;
    while (page < start + count) : (page += 1) {
        if (!bitSet(&allocated_bitmap, page) or !bitSet(&used_bitmap, page)) return false;
    }

    page = start;
    while (page < start + count) : (page += 1) {
        clearBit(&allocated_bitmap, page);
        clearBit(&used_bitmap, page);
    }
    free_pages += count;
    if (start / 64 < next_hint_word) next_hint_word = start / 64;
    return true;
}

fn bitSet(bitmap: *const [bitmap_words]u64, page: usize) bool {
    const word = page / 64;
    const mask = @as(u64, 1) << @intCast(page % 64);
    return (bitmap[word] & mask) != 0;
}

fn setBit(bitmap: *[bitmap_words]u64, page: usize) void {
    const word = page / 64;
    bitmap[word] |= @as(u64, 1) << @intCast(page % 64);
}

fn clearBit(bitmap: *[bitmap_words]u64, page: usize) void {
    const word = page / 64;
    bitmap[word] &= ~(@as(u64, 1) << @intCast(page % 64));
}

fn allocPageLocked() ?u64 {
    var scanned: usize = 0;
    while (scanned < bitmap_words) : (scanned += 1) {
        const word = (next_hint_word + scanned) % bitmap_words;
        const used = used_bitmap[word];
        if (used == ~@as(u64, 0)) continue;

        const bit: u7 = @ctz(~used);
        const mask = @as(u64, 1) << @intCast(bit);

        used_bitmap[word] |= mask;
        allocated_bitmap[word] |= mask;
        free_pages -= 1;
        next_hint_word = word;

        const page = word * 64 + @as(usize, @intCast(bit));
        return @as(u64, page) * page_size;
    }

    return null;
}

pub fn freePage(address: u64) bool {
    if (!initialized) return false;

    const guard = lock.acquire();
    defer guard.release();
    return freePageLocked(address);
}

fn freePageLocked(address: u64) bool {
    if (address % page_size != 0) return false;

    const page64 = address / page_size;
    if (page64 >= page_count) return false;
    const page: usize = @intCast(page64);

    const word = page / 64;
    const bit: u6 = @intCast(page % 64);
    const mask = @as(u64, 1) << bit;

    // Only pages handed out by allocPage may be freed. This protects reserved
    // regions (kernel image, firmware, MMIO) from accidental release.
    if ((allocated_bitmap[word] & mask) == 0) return false;

    allocated_bitmap[word] &= ~mask;
    used_bitmap[word] &= ~mask;
    free_pages += 1;

    if (word < next_hint_word) next_hint_word = word;
    return true;
}

pub fn stats() Stats {
    const guard = lock.acquire();
    defer guard.release();
    return .{
        .total_pages = total_pages,
        .free_pages = free_pages,
        .used_pages = total_pages - free_pages,
    };
}

pub fn totalBytes() u64 {
    return @as(u64, @intCast(stats().total_pages)) * page_size;
}

pub fn freeBytes() u64 {
    return @as(u64, @intCast(stats().free_pages)) * page_size;
}

fn markFree(page: usize) void {
    const word = page / 64;
    const bit: u6 = @intCast(page % 64);
    const mask = @as(u64, 1) << bit;
    if ((used_bitmap[word] & mask) != 0) {
        used_bitmap[word] &= ~mask;
        free_pages += 1;
    }
}

fn markUsed(page: usize) void {
    const word = page / 64;
    const bit: u6 = @intCast(page % 64);
    const mask = @as(u64, 1) << bit;
    if ((used_bitmap[word] & mask) == 0) {
        used_bitmap[word] |= mask;
        free_pages -= 1;
    }
}
