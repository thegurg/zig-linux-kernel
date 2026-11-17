//! Ring-3 syscall ABI and dispatcher.
//!
//! User code enters through the DPL3 gate for `int 0x80`. `isr_common` has
//! already saved all general-purpose registers, so this module reads and writes
//! the saved frame directly. Arguments follow the Linux x86_64 convention:
//! RAX = syscall number, RDI/RSI/RDX/R10 = arguments, RAX = result.
//!
//! Numbers and error values are deliberately tiny and project-local. They are
//! part of the M16 test ABI only; M17 may replace them with a process-facing
//! interface.

const console = @import("console.zig");
const sched = @import("sched.zig");
const vmm = @import("memory/vmm.zig");

pub const vector: u8 = 128;

pub const sys_write: u64 = 1;
pub const sys_exit: u64 = 2;
pub const sys_yield: u64 = 3;
pub const sys_sleep_ms: u64 = 4;
pub const sys_getpid: u64 = 5;

pub const ebadsys: i64 = -1;
pub const ebadf: i64 = -9;
pub const efault: i64 = -14;
pub const enosys: i64 = -38;

/// Saved register frame produced by `isr_common`. Keep the order and offsets in
/// sync with src/arch/x86_64/interrupts.S.
pub const SavedRegisters = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
};

comptime {
    if (@sizeOf(SavedRegisters) != 120) @compileError("SavedRegisters must be 120 bytes");
    if (@offsetOf(SavedRegisters, "rdi") != 72) @compileError("SavedRegisters.rdi must be at offset 72");
    if (@offsetOf(SavedRegisters, "rsi") != 80) @compileError("SavedRegisters.rsi must be at offset 80");
    if (@offsetOf(SavedRegisters, "rdx") != 88) @compileError("SavedRegisters.rdx must be at offset 88");
    if (@offsetOf(SavedRegisters, "rax") != 112) @compileError("SavedRegisters.rax must be at offset 112");
}

/// Handle `int 0x80` and return the saved-register base to resume.
pub fn dispatch(saved_rsp: u64) u64 {
    const regs: *SavedRegisters = @ptrFromInt(saved_rsp);
    const number = regs.rax;

    if (number == sys_write) {
        regs.rax = @bitCast(handleWrite(regs));
        return saved_rsp;
    }
    if (number == sys_exit) {
        const status: i32 = @bitCast(@as(u32, @truncate(regs.rdi)));
        return sched.exitUser(saved_rsp, status);
    }
    if (number == sys_yield) {
        regs.rax = 0;
        return sched.yieldCurrent(saved_rsp);
    }
    if (number == sys_sleep_ms) {
        regs.rax = 0;
        return sched.sleepMsCurrent(saved_rsp, regs.rdi);
    }
    if (number == sys_getpid) {
        regs.rax = sched.currentId();
        return saved_rsp;
    }

    regs.rax = @bitCast(enosys);
    return saved_rsp;
}

fn handleWrite(regs: *SavedRegisters) i64 {
    const fd = regs.rdi;
    if (fd != 1 and fd != 2) return ebadf;

    const length = regs.rdx;
    if (length == 0) return 0;
    const count: usize = @intCast(length);

    var copied: usize = 0;
    var buffer: [256]u8 = undefined;
    while (copied < count) {
        const chunk = @min(buffer.len, count - copied);
        vmm.copyFromUser(buffer[0..chunk], regs.rsi +% @as(u64, @intCast(copied))) catch return efault;
        console.write(buffer[0..chunk]);
        copied += chunk;
    }
    return @intCast(count);
}
