//! QEMU `isa-debug-exit` device: lets the kernel terminate QEMU with a status
//! code, which turns boot smoke tests into plain process exit codes.
//!
//! QEMU reports `(value << 1) | 1`, so EXIT_SUCCESS (0x10) surfaces as 33.

const port = @import("port.zig");

pub const EXIT_SUCCESS: u8 = 0x10;
pub const EXIT_FAILURE: u8 = 0x11;

const debug_exit_port: u16 = 0xf4;

pub fn exit(code: u8) noreturn {
    port.outb(debug_exit_port, code);
    // If no isa-debug-exit device is attached, halt instead of continuing.
    while (true) {
        asm volatile ("cli; hlt");
    }
}
