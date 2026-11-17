//! Minimal M16 test-only ELF64 loader.
//!
//! This is intentionally not a general process loader. It accepts the single
//! checked-in `src/user/demo.elf` fixture, maps its `PT_LOAD` segments into a
//! private low-half address space, and adds a writable data page and stack.
//! M17 owns validation, W^X/NX, argv, and general executable loading.

const std = @import("std");
const pmm = @import("memory/pmm.zig");
const vmm = @import("memory/vmm.zig");

const demo_elf = @embedFile("user/demo.elf");

pub const code_base: u64 = 0x0040_0000;
pub const data_base: u64 = 0x0050_0000;
pub const extra_base: u64 = 0x0060_0000;
pub const stack_base: u64 = 0x0070_0000;
pub const stack_pages: usize = 4;
pub const stack_top: u64 = stack_base + stack_pages * vmm.page_size;

pub const Image = struct {
    root: u64,
    entry: u64,
    data_phys: u64,
    stack_phys: u64,
    extra_phys: ?u64,
};

const elf_header_size = 64;
const program_header_size = 56;
const pt_load: u32 = 1;

/// Load the embedded test program into a new address space.
pub fn create(with_extra: bool) ?Image {
    const root = vmm.createAddressSpace() orelse return null;
    return createIn(root, with_extra) orelse {
        vmm.destroyAddressSpace(root);
        return null;
    };
}

fn createIn(root: u64, with_extra: bool) ?Image {
    const entry = loadSegments(root) orelse return null;

    const data_phys = mapZeroPage(root, data_base, true) orelse return null;

    var stack_phys: u64 = 0;
    var page: usize = 0;
    while (page < stack_pages) : (page += 1) {
        const virt = stack_base + @as(u64, @intCast(page)) * vmm.page_size;
        const phys = mapZeroPage(root, virt, true) orelse return null;
        if (page == 0) stack_phys = phys;
    }

    var extra_phys: ?u64 = null;
    if (with_extra) {
        extra_phys = mapZeroPage(root, extra_base, true) orelse return null;
    }

    return .{
        .root = root,
        .entry = entry,
        .data_phys = data_phys,
        .stack_phys = stack_phys,
        .extra_phys = extra_phys,
    };
}

/// Destroy an image whose task never started or never owned the address space.
pub fn destroy(root: u64) void {
    vmm.destroyAddressSpace(root);
}

fn loadSegments(root: u64) ?u64 {
    const bytes: []const u8 = demo_elf;
    if (bytes.len < elf_header_size) return null;

    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return null;
    if (bytes[4] != 2 or bytes[5] != 1) return null; // ELF64, little-endian
    if (readU16(bytes, 16) != 2) return null; // ET_EXEC
    if (readU16(bytes, 18) != 62) return null; // EM_X86_64

    const entry = readU64(bytes, 24);
    const phoff = readU64(bytes, 32);
    const phentsize = readU16(bytes, 54);
    const phnum = readU16(bytes, 56);
    if (phentsize < program_header_size or phnum == 0 or phnum > 16) return null;

    const table_size = @as(u64, phentsize) * phnum;
    if (phoff > bytes.len or table_size > bytes.len - phoff) return null;

    var loaded: usize = 0;
    var index: u16 = 0;
    while (index < phnum) : (index += 1) {
        const ph = phoff + @as(u64, index) * phentsize;
        if (ph + program_header_size > bytes.len) return null;

        const kind = readU32(bytes, ph);
        if (kind != pt_load) continue;

        const flags = readU32(bytes, ph + 4);
        const offset = readU64(bytes, ph + 8);
        const vaddr = readU64(bytes, ph + 16);
        const filesz = readU64(bytes, ph + 32);
        const memsz = readU64(bytes, ph + 40);

        if (memsz == 0 or filesz > memsz) return null;
        if (vaddr < vmm.page_size or vaddr % vmm.page_size != 0) return null;
        if (vaddr > data_base or memsz > data_base - vaddr) return null;
        if (offset > bytes.len or filesz > bytes.len - offset) return null;

        if (!mapSegment(root, bytes, offset, vaddr, filesz, memsz, (flags & 2) != 0)) return null;
        loaded += 1;
    }

    if (loaded == 0) return null;
    if (entry < code_base or entry >= data_base) return null;
    return entry;
}

fn mapSegment(
    root: u64,
    bytes: []const u8,
    offset: u64,
    vaddr: u64,
    filesz: u64,
    memsz: u64,
    writable: bool,
) bool {
    const file_end = vaddr + filesz;
    const segment_end = vaddr + memsz;

    var virt = vaddr;
    while (virt < segment_end) : (virt += vmm.page_size) {
        const phys = mapZeroPage(root, virt, writable) orelse return false;

        const page_end = virt + vmm.page_size;
        const copy_start = @max(vaddr, virt);
        const copy_end = @min(file_end, page_end);
        if (copy_end > copy_start) {
            const source_offset: usize = @intCast(offset + (copy_start - vaddr));
            const destination_offset: usize = @intCast(copy_start - virt);
            const length: usize = @intCast(copy_end - copy_start);
            const target: [*]u8 = @ptrFromInt(vmm.hhdmOffset() + phys + destination_offset);
            @memcpy(target[0..length], bytes[source_offset..][0..length]);
        }
    }
    return true;
}

fn mapZeroPage(root: u64, virt: u64, writable: bool) ?u64 {
    const phys = pmm.allocPage() orelse return null;
    const page: [*]u8 = @ptrFromInt(vmm.hhdmOffset() + phys);
    @memset(page[0..vmm.page_size], 0);

    if (!vmm.mapUserPage(root, virt, phys, writable)) {
        _ = pmm.freePage(phys);
        return null;
    }
    return phys;
}

fn readU16(bytes: []const u8, offset: u64) u16 {
    const at: usize = @intCast(offset);
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: u64) u32 {
    const at: usize = @intCast(offset);
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn readU64(bytes: []const u8, offset: u64) u64 {
    const at: usize = @intCast(offset);
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}
