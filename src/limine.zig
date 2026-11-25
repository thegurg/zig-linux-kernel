//! Minimal Limine boot protocol bindings (protocol v12.9.4, base revision 3).
//!
//! Requests live in `.limine_requests`; Limine scans that section between the
//! start/end markers in the linked image. See the Limine protocol docs.

const std = @import("std");

pub const base_revision_number: u64 = 3;

const common_magic_0: u64 = 0xc7b1dd30df4c8b88;
const common_magic_1: u64 = 0x0a82e883a194f07b;

pub const Framebuffer = extern struct {
    address: ?*anyopaque,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?*anyopaque,
    mode_count: u64,
    modes: [*]?*VideoMode,
};

pub const VideoMode = extern struct {
    pitch: u64,
    width: u64,
    height: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]?*Framebuffer,
};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const ExecutableAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

pub const PagingModeResponse = extern struct {
    revision: u64,
    mode: u64,
};

/// Base revision 3 returns the RSDP as a physical address. The caller adds the
/// HHDM offset before reading the ACPI tables.
pub const RsdpResponse = extern struct {
    revision: u64,
    address: ?*anyopaque,
};

/// x86-64 entry from Limine's MP (multiprocessor) protocol. `reserved` and
/// `goto_address` are managed by the bootloader until we publish an entry;
/// `extra_argument` is free for the kernel.
/// One file passed to the kernel through the Limine module mechanism. The
/// loader maps module contents somewhere in the HHDM; `address` is that virtual
/// address. `path` is the on-disk path and `string` is the configured
/// `MODULE_STRING` (both NUL-terminated).
pub const File = extern struct {
    revision: u64,
    address: u64,
    size: u64,
    path: [*:0]const u8,
    string: [*:0]const u8,
    media_type: u32,
    unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: [16]u8,
    gpt_part_uuid: [16]u8,
    part_uuid: [16]u8,
};

pub const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules: [*]?*File,
};

pub const MpInfo = extern struct {
    processor_id: u32,
    lapic_id: u32,
    reserved: u64,
    goto_address: u64,
    extra_argument: u64,
};

pub const MpResponse = extern struct {
    revision: u64,
    flags: u32,
    bsp_lapic_id: u32,
    cpu_count: u64,
    cpus: [*]?*MpInfo,
};

pub const mp_x2apic: u32 = 1 << 0;

pub const MemmapEntryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,
    reserved_mapped = 8,
    _,
};

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    type: u64,
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]?*MemmapEntry,
};

const FramebufferRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*FramebufferResponse,
};

const HhdmRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*HhdmResponse,
};

const ExecutableAddressRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*ExecutableAddressResponse,
};

const PagingModeRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*PagingModeResponse,
    mode: u64,
    max_mode: u64,
    min_mode: u64,
};

const RsdpRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*RsdpResponse,
};

const MemmapRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*MemmapResponse,
};

const ModuleRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*ModuleResponse,
};

const MpRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*MpResponse,
    flags: u64,
};

// Markers delimiting the request section.
export const requests_start_marker: [4]u64 linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9,
};
export const requests_end_marker: [2]u64 linksection(".limine_requests_end") = .{
    0xadc0e0531bb10d03, 0x9572709f31764c62,
};

/// Limine overwrites element 2 with the highest base revision it supports when
/// our requested revision is too new; zero means "supported".
pub export var base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, base_revision_number,
};

export var framebuffer_request: FramebufferRequest linksection(".limine_requests") = .{
    .id = .{ common_magic_0, common_magic_1, 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    .revision = 0,
    .response = null,
};

export var hhdm_request: HhdmRequest linksection(".limine_requests") = .{
    .id = .{ common_magic_0, common_magic_1, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    .revision = 0,
    .response = null,
};

export var memmap_request: MemmapRequest linksection(".limine_requests") = .{
    .id = .{ common_magic_0, common_magic_1, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    .revision = 0,
    .response = null,
};

export var executable_address_request: ExecutableAddressRequest linksection(".limine_requests") = .{
    .id = .{ common_magic_0, common_magic_1, 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    .revision = 0,
    .response = null,
};

/// Request module (initramfs) metadata. Limine maps each module and reports its
/// virtual address and length.
export var module_request: ModuleRequest linksection(".limine_requests") = .{
    .id = .{ common_magic_0, common_magic_1, 0x3e7e279702be32af, 0xca1c4f3bd1280cee },
    .revision = 0,
    .response = null,
};

/// Ask Limine to bootstrap secondary CPUs and park them until we publish a
/// per-CPU `goto_address`.
export var mp_request: MpRequest linksection(".limine_requests") = .{
    .id = .{ common_magic_0, common_magic_1, 0x95a67b819a1b857e, 0xa0b61b723b6a73e0 },
    .revision = 0,
    .response = null,
    .flags = 0,
};

/// Force 4-level paging: M1c builds 4-level tables and assumes CR4.LA57 = 0.
export var paging_mode_request: PagingModeRequest linksection(".limine_requests") = .{
    .id = .{ common_magic_0, common_magic_1, 0x95c1a0edab0944cb, 0xa4e5cb3842f7488a },
    .revision = 0,
    .response = null,
    .mode = 0,
    .max_mode = 0,
    .min_mode = 0,
};

/// ACPI root pointer request. Physical for Limine base revision 3.
export var rsdp_request: RsdpRequest linksection(".limine_requests") = .{
    .id = .{ common_magic_0, common_magic_1, 0xc5e77b6b397e7b43, 0x27637845accdcf3c },
    .revision = 0,
    .response = null,
};

pub fn baseRevisionSupported() bool {
    return base_revision[2] == 0;
}

pub fn framebuffer() ?*Framebuffer {
    const response = framebuffer_request.response orelse return null;
    if (response.framebuffer_count == 0) return null;
    return response.framebuffers[0] orelse null;
}

pub fn hhdmOffset() ?u64 {
    const response = hhdm_request.response orelse return null;
    return response.offset;
}

pub fn memmap() ?*MemmapResponse {
    return memmap_request.response;
}

pub fn executableAddress() ?*ExecutableAddressResponse {
    return executable_address_request.response;
}

pub fn pagingMode() ?*PagingModeResponse {
    return paging_mode_request.response;
}

pub fn rsdp() ?*RsdpResponse {
    return rsdp_request.response;
}

pub fn mp() ?*MpResponse {
    return mp_request.response;
}

pub fn modules() ?*ModuleResponse {
    return module_request.response;
}

pub fn moduleCount() usize {
    const response = modules() orelse return 0;
    return @intCast(response.module_count);
}

pub fn moduleAt(index: usize) ?*File {
    const response = modules() orelse return null;
    if (index >= response.module_count) return null;
    return response.modules[index];
}

/// Return the first module whose `MODULE_STRING` or path contains `needle`.
pub fn findModule(needle: []const u8) ?*File {
    var index: usize = 0;
    while (index < moduleCount()) : (index += 1) {
        const file = moduleAt(index) orelse continue;
        if (std.mem.indexOf(u8, std.mem.span(file.string), needle) != null) return file;
        if (std.mem.indexOf(u8, std.mem.span(file.path), needle) != null) return file;
    }
    return null;
}

test "base revision marker layout" {
    try std.testing.expectEqual(@as(usize, 3), base_revision.len);
    try std.testing.expectEqual(base_revision_number, base_revision[2]);
}
