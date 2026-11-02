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

const MemmapRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*MemmapResponse,
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

test "base revision marker layout" {
    try std.testing.expectEqual(@as(usize, 3), base_revision.len);
    try std.testing.expectEqual(base_revision_number, base_revision[2]);
}
