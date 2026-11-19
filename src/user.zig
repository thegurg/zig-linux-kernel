//! ELF64 `ET_EXEC` loader and initial user stack builder.
//!
//! M17 replaces the M16 fixture loader with a general loader. It validates the
//! ELF header and every `PT_LOAD` program header before mapping anything,
//! rejects overlapping segments and W+X segments, applies the W^X policy
//! (RX code, RO+NX read-only data, RW+NX data/stacks), and builds a SysV-style
//! initial stack with `argc`, `argv`, `envp`, and 16-byte alignment.
//!
//! `create`/`Image` remain as the M16 fixture entry point so the older selftest
//! keeps exercising the same fixed layout. `loadProcess` is the M17 path used
//! by the process table.

const std = @import("std");
const pmm = @import("memory/pmm.zig");
const vmm = @import("memory/vmm.zig");

const demo_elf = @embedFile("user/demo.elf");
pub const proc_elf = @embedFile("user/proc.elf");

pub const code_base: u64 = 0x0040_0000;
pub const data_base: u64 = 0x0050_0000;
pub const extra_base: u64 = 0x0060_0000;
pub const stack_base: u64 = 0x0070_0000;
pub const stack_pages: usize = 4;
pub const stack_top: u64 = stack_base + stack_pages * vmm.page_size;

/// Reserved process stack window. The last page below `process_stack_top` is
/// the guard page and is never mapped, so a stack overflow faults instead of
/// silently corrupting the neighbouring address range.
pub const process_stack_top: u64 = 0x0000_0000_7fff_f000;
pub const process_stack_pages: usize = 4;
pub const process_guard_page: u64 = process_stack_top - (process_stack_pages + 1) * vmm.page_size;

pub const Image = struct {
    root: u64,
    entry: u64,
    data_phys: u64,
    stack_phys: u64,
    extra_phys: ?u64,
};

pub const ProcessImage = struct {
    root: u64,
    entry: u64,
    stack_rsp: u64,
};

pub const StackOptions = struct {
    top: u64 = process_stack_top,
    pages: usize = process_stack_pages,
};

pub const LoadError = error{
    BadHeader,
    BadMagic,
    BadClass,
    BadEncoding,
    BadVersion,
    BadType,
    BadMachine,
    BadProgramHeader,
    BadSegment,
    BadAlignment,
    WritableExecutable,
    SegmentOverlap,
    EntryNotExecutable,
    StackOverflow,
    BadStack,
    OutOfMemory,
};

const elf_header_size = 64;
const program_header_size = 56;
const pt_load: u32 = 1;
const pf_exec: u32 = 1;
const pf_write: u32 = 2;
const pf_read: u32 = 4;
const max_phdrs = 64;
const max_segments = 32;
const max_args = 32;
const max_envs = 32;
const max_stack_pages = 64;
const min_user_vaddr: u64 = 0x0001_0000;

const Segment = struct {
    vaddr: u64,
    offset: u64,
    filesz: u64,
    memsz: u64,
    executable: bool,
    writable: bool,
};

const Validated = struct {
    entry: u64,
    count: usize,
};

const StackRegion = struct {
    /// Includes the unmapped guard page.
    start: u64,
    end: u64,
};

/// Load the embedded M16 fixture into a new address space.
pub fn create(with_extra: bool) ?Image {
    const loaded = loadProcessWith(demo_elf, &.{}, &.{}, .{
        .top = stack_top,
        .pages = stack_pages,
    }) catch return null;
    return finishM16(loaded, with_extra) orelse {
        vmm.destroyAddressSpace(loaded.root);
        return null;
    };
}

fn finishM16(loaded: ProcessImage, with_extra: bool) ?Image {
    const data_phys = mapZeroPage(loaded.root, data_base, vmm.user_rw_nx) orelse return null;
    const stack_phys = vmm.translateIn(loaded.root, stack_base) orelse return null;

    var extra_phys: ?u64 = null;
    if (with_extra) {
        extra_phys = mapZeroPage(loaded.root, extra_base, vmm.user_rw_nx) orelse return null;
    }

    return .{
        .root = loaded.root,
        .entry = loaded.entry,
        .data_phys = data_phys,
        .stack_phys = stack_phys,
        .extra_phys = extra_phys,
    };
}

/// Destroy an image whose task never started or never owned the address space.
pub fn destroy(root: u64) void {
    vmm.destroyAddressSpace(root);
}

/// Load a general `ET_EXEC` image and build its initial stack. The caller owns
/// the returned address space; `destroy` releases it on a failure path that
/// happens before a task takes ownership.
pub fn loadProcess(
    bytes: []const u8,
    argv: []const []const u8,
    envp: []const []const u8,
) LoadError!ProcessImage {
    return loadProcessWith(bytes, argv, envp, .{});
}

pub fn loadProcessWith(
    bytes: []const u8,
    argv: []const []const u8,
    envp: []const []const u8,
    stack: StackOptions,
) LoadError!ProcessImage {
    var segments: [max_segments]Segment = undefined;
    const validated = try validate(bytes, &segments, stack);

    const root = vmm.createAddressSpace() orelse return error.OutOfMemory;
    errdefer vmm.destroyAddressSpace(root);

    for (segments[0..validated.count]) |segment| {
        try mapSegment(root, bytes, segment);
    }

    const stack_rsp = try buildInitialStack(root, argv, envp, stack);
    return .{ .root = root, .entry = validated.entry, .stack_rsp = stack_rsp };
}

fn validate(
    bytes: []const u8,
    segments: *[max_segments]Segment,
    stack: StackOptions,
) LoadError!Validated {
    if (bytes.len < elf_header_size) return error.BadHeader;
    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.BadMagic;
    if (bytes[4] != 2) return error.BadClass; // ELFCLASS64
    if (bytes[5] != 1) return error.BadEncoding; // ELFDATA2LSB
    if (bytes[6] != 1) return error.BadVersion; // EV_CURRENT
    if (readU16(bytes, 16) != 2) return error.BadType; // ET_EXEC
    if (readU16(bytes, 18) != 62) return error.BadMachine; // EM_X86_64
    if (readU32(bytes, 20) != 1) return error.BadVersion;
    if (readU16(bytes, 52) != elf_header_size) return error.BadHeader;

    const phoff = readU64(bytes, 32);
    const phentsize = readU16(bytes, 54);
    const phnum = readU16(bytes, 56);
    if (phentsize != program_header_size or phnum == 0 or phnum > max_phdrs) {
        return error.BadProgramHeader;
    }

    const table_size = @as(u64, phentsize) * phnum;
    if (phoff > bytes.len or table_size > bytes.len - phoff) return error.BadProgramHeader;

    const region = try stackRegion(stack);
    const entry = readU64(bytes, 24);
    if (entry >= vmm.user_max_address) return error.EntryNotExecutable;

    var count: usize = 0;
    var ph_index: u16 = 0;
    while (ph_index < phnum) : (ph_index += 1) {
        const ph = phoff + @as(u64, ph_index) * phentsize;
        if (ph + program_header_size > bytes.len) return error.BadProgramHeader;

        if (readU32(bytes, ph) != pt_load) continue;

        const flags = readU32(bytes, ph + 4);
        if ((flags & ~(pf_exec | pf_write | pf_read)) != 0) return error.BadSegment;
        const executable = (flags & pf_exec) != 0;
        const writable = (flags & pf_write) != 0;
        const readable = (flags & pf_read) != 0;
        if (executable and writable) return error.WritableExecutable;
        if (!executable and !readable) return error.BadSegment;

        const offset = readU64(bytes, ph + 8);
        const vaddr = readU64(bytes, ph + 16);
        const filesz = readU64(bytes, ph + 32);
        const memsz = readU64(bytes, ph + 40);

        if (memsz == 0) continue;
        if (filesz > memsz) return error.BadSegment;
        if (vaddr < min_user_vaddr) return error.BadSegment;
        if (vaddr >= vmm.user_max_address) return error.BadSegment;
        if (memsz > vmm.user_max_address - vaddr) return error.BadSegment;
        if (offset > bytes.len or filesz > bytes.len - offset) return error.BadSegment;

        // File offset and virtual address must be congruent modulo the page
        // size so a page-sized copy preserves the segment's contents.
        if ((vaddr & (vmm.page_size - 1)) != (offset & (vmm.page_size - 1))) {
            return error.BadAlignment;
        }

        const alignment = readU64(bytes, ph + 48);
        if (alignment > 1) {
            if (!std.math.isPowerOfTwo(alignment)) return error.BadAlignment;
            if ((vaddr % alignment) != (offset % alignment)) return error.BadAlignment;
        }

        const page_start = std.mem.alignBackward(u64, vaddr, vmm.page_size);
        const page_end = std.mem.alignForward(u64, vaddr + memsz, vmm.page_size);
        if (page_start < region.end and region.start < page_end) return error.SegmentOverlap;

        if (count >= segments.len) return error.BadProgramHeader;
        segments[count] = .{
            .vaddr = vaddr,
            .offset = offset,
            .filesz = filesz,
            .memsz = memsz,
            .executable = executable,
            .writable = writable,
        };
        count += 1;
    }

    if (count == 0) return error.BadSegment;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const a = segments[i];
        const a_start = std.mem.alignBackward(u64, a.vaddr, vmm.page_size);
        const a_end = std.mem.alignForward(u64, a.vaddr + a.memsz, vmm.page_size);
        var j: usize = i + 1;
        while (j < count) : (j += 1) {
            const b = segments[j];
            const b_start = std.mem.alignBackward(u64, b.vaddr, vmm.page_size);
            const b_end = std.mem.alignForward(u64, b.vaddr + b.memsz, vmm.page_size);
            if (a_start < b_end and b_start < a_end) return error.SegmentOverlap;
        }
    }

    var entry_executable = false;
    for (segments[0..count]) |segment| {
        if (!segment.executable) continue;
        if (entry >= segment.vaddr and entry < segment.vaddr + segment.memsz) {
            entry_executable = true;
            break;
        }
    }
    if (!entry_executable) return error.EntryNotExecutable;

    return .{ .entry = entry, .count = count };
}

fn stackRegion(stack: StackOptions) LoadError!StackRegion {
    if (stack.pages == 0 or stack.pages > max_stack_pages) return error.BadStack;
    if (stack.top == 0 or stack.top % vmm.page_size != 0) return error.BadStack;
    if (stack.top > vmm.user_max_address) return error.BadStack;

    const size = @as(u64, @intCast(stack.pages)) * vmm.page_size;
    if (stack.top < size + vmm.page_size) return error.BadStack;
    return .{ .start = stack.top - size - vmm.page_size, .end = stack.top };
}

fn mapSegment(root: u64, bytes: []const u8, segment: Segment) LoadError!void {
    const flags = if (segment.executable)
        vmm.user_rx
    else if (segment.writable)
        vmm.user_rw_nx
    else
        vmm.user_ro_nx;

    const first = std.mem.alignBackward(u64, segment.vaddr, vmm.page_size);
    const last = std.mem.alignForward(u64, segment.vaddr + segment.memsz, vmm.page_size);
    const file_end = segment.vaddr + segment.filesz;

    var virt = first;
    while (virt < last) : (virt += vmm.page_size) {
        const phys = mapZeroPage(root, virt, flags) orelse return error.OutOfMemory;

        const copy_start = @max(segment.vaddr, virt);
        const copy_end = @min(file_end, virt + vmm.page_size);
        if (copy_end <= copy_start) continue;

        const source_offset: usize = @intCast(segment.offset + (copy_start - segment.vaddr));
        const destination_offset: usize = @intCast(copy_start - virt);
        const length: usize = @intCast(copy_end - copy_start);
        const target: [*]u8 = @ptrFromInt(vmm.hhdmOffset() + phys + destination_offset);
        @memcpy(target[0..length], bytes[source_offset..][0..length]);
    }
}

fn buildInitialStack(
    root: u64,
    argv: []const []const u8,
    envp: []const []const u8,
    stack: StackOptions,
) LoadError!u64 {
    if (argv.len > max_args or envp.len > max_envs) return error.StackOverflow;

    const region = try stackRegion(stack);
    const stack_base_addr = region.end - @as(u64, @intCast(stack.pages)) * vmm.page_size;

    var page: usize = 0;
    while (page < stack.pages) : (page += 1) {
        const virt = stack_base_addr + @as(u64, @intCast(page)) * vmm.page_size;
        _ = mapZeroPage(root, virt, vmm.user_rw_nx) orelse return error.OutOfMemory;
    }

    var arg_ptrs: [max_args]u64 = undefined;
    var env_ptrs: [max_envs]u64 = undefined;

    // Strings are pushed downward from the top. The pointer array is then
    // placed below them, so neither region can overwrite the other.
    var sp = region.end;
    for (argv, 0..) |value, index| {
        arg_ptrs[index] = try pushString(root, &sp, stack_base_addr, value);
    }
    for (envp, 0..) |value, index| {
        env_ptrs[index] = try pushString(root, &sp, stack_base_addr, value);
    }

    const qword_count = 1 + argv.len + 1 + envp.len + 1;
    const array_bytes = @as(u64, @intCast(qword_count)) * 8;
    if (sp < stack_base_addr + array_bytes) return error.StackOverflow;

    const array_start = std.mem.alignBackward(u64, sp - array_bytes, 16);
    if (array_start < stack_base_addr) return error.StackOverflow;

    var cursor = array_start;
    try writeQword(root, cursor, argv.len);
    cursor += 8;
    for (arg_ptrs[0..argv.len]) |pointer| {
        try writeQword(root, cursor, pointer);
        cursor += 8;
    }
    try writeQword(root, cursor, 0);
    cursor += 8;
    for (env_ptrs[0..envp.len]) |pointer| {
        try writeQword(root, cursor, pointer);
        cursor += 8;
    }
    try writeQword(root, cursor, 0);

    return array_start;
}

fn pushString(
    root: u64,
    sp: *u64,
    stack_base_addr: u64,
    value: []const u8,
) LoadError!u64 {
    const need = @as(u64, @intCast(value.len)) + 1;
    if (sp.* < stack_base_addr + need) return error.StackOverflow;

    sp.* -= need;
    try writeUserBytes(root, sp.*, value);
    try writeUserBytes(root, sp.* + value.len, &[_]u8{0});
    return sp.*;
}

fn writeQword(root: u64, virt: u64, value: u64) LoadError!void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try writeUserBytes(root, virt, &bytes);
}

fn writeUserBytes(root: u64, virt: u64, bytes: []const u8) LoadError!void {
    var copied: usize = 0;
    while (copied < bytes.len) {
        const address = virt + @as(u64, @intCast(copied));
        const phys = vmm.translateIn(root, address) orelse return error.BadStack;
        const room: usize = @intCast(vmm.page_size - (address & (vmm.page_size - 1)));
        const chunk = @min(bytes.len - copied, room);
        const target: [*]u8 = @ptrFromInt(vmm.hhdmOffset() + phys);
        @memcpy(target[0..chunk], bytes[copied..][0..chunk]);
        copied += chunk;
    }
}

fn mapZeroPage(root: u64, virt: u64, flags: u64) ?u64 {
    const phys = pmm.allocPage() orelse return null;
    const page: [*]u8 = @ptrFromInt(vmm.hhdmOffset() + phys);
    @memset(page[0..@intCast(vmm.page_size)], 0);

    if (!vmm.mapUserPageFlags(root, virt, phys, flags)) {
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
