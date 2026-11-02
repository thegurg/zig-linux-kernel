//! Early console: COM1 serial plus a text grid on the Limine framebuffer.

const std = @import("std");
const limine = @import("limine.zig");
const serial = @import("arch/x86_64/serial.zig");
const font = @import("font.zig");

const max_cols = 256;
const max_rows = 128;

const fg_color = Rgb{ .r = 0xe6, .g = 0xe8, .b = 0xf0 };
const bg_color = Rgb{ .r = 0x0b, .g = 0x0b, .b = 0x16 };
const accent_color = Rgb{ .r = 0x7a, .g = 0xd6, .b = 0x7a };

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

var active = false;

var base: [*]u8 = undefined;
var fb_width: u64 = 0;
var fb_height: u64 = 0;
var pitch: u64 = 0;

var red_size: u8 = 0;
var red_shift: u8 = 0;
var green_size: u8 = 0;
var green_shift: u8 = 0;
var blue_size: u8 = 0;
var blue_shift: u8 = 0;

var cols: usize = 0;
var rows: usize = 0;
var cursor_row: usize = 0;
var cursor_col: usize = 0;

var cells: [max_rows][max_cols]u8 = @splat(@splat(' '));

pub fn init() void {
    const fb = limine.framebuffer() orelse {
        serial.write("console: no framebuffer\n");
        return;
    };
    if (fb.bpp != 32) {
        serial.write("console: unsupported bpp\n");
        return;
    }
    const address = fb.address orelse {
        serial.write("console: null framebuffer address\n");
        return;
    };
    if (fb.width == 0 or fb.height == 0 or fb.pitch == 0) {
        serial.write("console: empty framebuffer\n");
        return;
    }

    base = @ptrCast(address);
    fb_width = fb.width;
    fb_height = fb.height;
    pitch = fb.pitch;
    red_size = fb.red_mask_size;
    red_shift = fb.red_mask_shift;
    green_size = fb.green_mask_size;
    green_shift = fb.green_mask_shift;
    blue_size = fb.blue_mask_size;
    blue_shift = fb.blue_mask_shift;

    cols = @intCast(@min(fb.width / font.width, max_cols));
    rows = @intCast(@min(fb.height / font.height, max_rows));
    if (cols == 0 or rows == 0) return;

    active = true;
    clear();
}

pub fn isActive() bool {
    return active;
}

pub fn clear() void {
    cursor_row = 0;
    cursor_col = 0;
    for (&cells) |*line| {
        @memset(line, ' ');
    }
    if (!active) return;
    fill(Rgb{ .r = 0x0b, .g = 0x0b, .b = 0x16 });
}

pub fn write(bytes: []const u8) void {
    serial.write(bytes);
    if (!active) return;
    for (bytes) |byte| putc(byte);
}

pub fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch {
        write("<console: message too long>\n");
        return;
    };
    write(text);
}

pub fn writeHex(value: u64) void {
    serial.writeHex(value);
    if (!active) return;
    const digits = "0123456789abcdef";
    var shift: u6 = 60;
    while (true) {
        const nibble: u4 = @truncate(value >> shift);
        putc(digits[nibble]);
        if (shift == 0) break;
        shift -= 4;
    }
}

fn putc(byte: u8) void {
    switch (byte) {
        '\n' => newline(),
        '\r' => cursor_col = 0,
        '\t' => while (cursor_col % 4 != 0) putc(' '),
        else => {
            const glyph: u8 = if (byte >= font.first and byte <= font.last) byte else '?';
            cells[cursor_row][cursor_col] = glyph;
            drawGlyph(cursor_col, cursor_row, glyph, pack(fg_color), pack(bg_color));
            cursor_col += 1;
            if (cursor_col >= cols) newline();
        },
    }
}

fn newline() void {
    cursor_col = 0;
    cursor_row += 1;
    if (cursor_row >= rows) scroll();
}

fn scroll() void {
    var row: usize = 1;
    while (row < rows) : (row += 1) {
        cells[row - 1] = cells[row];
    }
    @memset(&cells[rows - 1], ' ');
    cursor_row = rows - 1;
    cursor_col = 0;

    if (!active) return;
    redrawAll();
}

fn redrawAll() void {
    fill(bg_color);
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const glyph = cells[row][col];
            if (glyph != ' ') drawGlyph(col, row, glyph, pack(fg_color), pack(bg_color));
        }
    }
}

/// Print a string in the accent color on a fresh line. Used for banners.
pub fn banner(text: []const u8) void {
    serial.write(text);
    serial.write("\n");
    if (!active) return;
    for (text) |byte| {
        const glyph: u8 = if (byte >= font.first and byte <= font.last) byte else '?';
        cells[cursor_row][cursor_col] = glyph;
        drawGlyph(cursor_col, cursor_row, glyph, pack(accent_color), pack(bg_color));
        cursor_col += 1;
        if (cursor_col >= cols) newline();
    }
    newline();
}

fn fill(color: Rgb) void {
    const packed_color = pack(color);
    var y: u64 = 0;
    while (y < fb_height) : (y += 1) {
        var x: u64 = 0;
        while (x < fb_width) : (x += 1) {
            pixel(x, y, packed_color);
        }
    }
}

fn pixel(x: u64, y: u64, color: u32) void {
    const offset = y * pitch + x * 4;
    const ptr: *volatile u32 = @ptrCast(@alignCast(base + offset));
    ptr.* = color;
}

fn drawGlyph(col: usize, row: usize, glyph: u8, fg: u32, bg: u32) void {
    const bitmap = font.glyphs[@as(usize, glyph - font.first)];
    var y: usize = 0;
    const x0 = col * font.width;
    const y0 = row * font.height;
    while (y < font.height) : (y += 1) {
        const bits = bitmap[y];
        var x: usize = 0;
        while (x < font.width) : (x += 1) {
            const on = (bits & (@as(u8, 0x80) >> @intCast(x))) != 0;
            pixel(x0 + x, y0 + y, if (on) fg else bg);
        }
    }
}

fn pack(color: Rgb) u32 {
    return channel(color.r, red_size, red_shift) |
        channel(color.g, green_size, green_shift) |
        channel(color.b, blue_size, blue_shift);
}

fn channel(value: u8, size: u8, shift: u8) u32 {
    if (size == 0) return 0;
    const wide: u32 = value;
    const scaled: u32 = if (size >= 8)
        wide << @intCast(size - 8)
    else
        wide >> @intCast(8 - size);
    return scaled << @intCast(shift);
}
