//! x86_64 CPU bring-up helpers and per-CPU state.

const gdt = @import("gdt.zig");

pub const max_cpus = gdt.max_cpus;

/// Per-CPU data reachable through the GS base MSR.
///
/// The first field is deliberately `fpu_state`: the interrupt entry stub in
/// `interrupts.S` reads `%gs:0` to find the 512-byte FXSAVE area for the
/// interrupted task. Keep that layout stable.
pub const PerCpu = extern struct {
    fpu_state: u64 = 0,
    index: u32 = 0,
    lapic_id: u32 = 0,
    online: u64 = 0,
};

pub var per_cpu: [max_cpus]PerCpu align(64) = @splat(.{});

comptime {
    if (@offsetOf(PerCpu, "fpu_state") != 0) @compileError("PerCpu.fpu_state must be at offset 0");
    if (@offsetOf(PerCpu, "index") != 8) @compileError("PerCpu.index must be at offset 8");
    if (@offsetOf(PerCpu, "lapic_id") != 12) @compileError("PerCpu.lapic_id must be at offset 12");
}

/// Scratch FXSAVE area used between `initPerCpu` and the scheduler installing
/// the boot/idle task. It keeps `%gs:0` dereferenceable even if an exception
/// arrives before any task has been created.
var boot_fpu_state: [512]u8 align(16) = @splat(0);

/// Enable SSE/SSE2 so compiler-generated code (memcpy/memset, struct copies)
/// is legal. Firmware does not guarantee CR4.OSFXSR for the loaded image, and
/// any SSE instruction executed with OSFXSR clear raises #UD. KVM enforces
/// this strictly while TCG tends to tolerate it, so this must run before any
/// non-trivial Zig code.
///
/// MXCSR is left at its architectural reset value (0x1f80: all SIMD
/// exceptions masked, round to nearest). LDMXCSR has been observed to fault
/// under KVM on some hosts, and the reset value is already what we want.
pub fn enableSse() void {
    var cr0: u64 = asm volatile ("mov %%cr0, %[value]"
        : [value] "=r" (-> u64),
    );
    cr0 &= ~@as(u64, 1 << 2); // EM: no x87 emulation
    cr0 &= ~@as(u64, 1 << 3); // TS: no lazy FPU switching
    cr0 |= 1 << 1; // MP
    cr0 |= 1 << 5; // NE
    asm volatile ("mov %[value], %%cr0"
        :
        : [value] "r" (cr0),
    );

    var cr4: u64 = asm volatile ("mov %%cr4, %[value]"
        : [value] "=r" (-> u64),
    );
    cr4 |= 1 << 9; // OSFXSR: FXSAVE/FXRSTOR and SSE state
    cr4 |= 1 << 10; // OSXMMEXCPT: unmasked SIMD exceptions
    asm volatile ("mov %[value], %%cr4"
        :
        : [value] "r" (cr4),
    );

    asm volatile ("fninit");
}

/// Install this CPU's per-CPU block and point GS at it.
///
/// Call after the GDT has been loaded: `gdt.load` reloads the GS selector, and
/// doing this afterwards makes the `IA32_GS_BASE` value authoritative.
pub fn initPerCpu(index: u32, lapic_id: u32) void {
    if (index >= max_cpus) return;
    const state = &per_cpu[index];
    state.fpu_state = @intFromPtr(&boot_fpu_state);
    state.index = index;
    state.lapic_id = lapic_id;
    setGsBase(@intFromPtr(state));
}

/// Index of the CPU executing this code. Valid after `initPerCpu`.
pub fn currentIndex() u32 {
    return asm volatile ("movl %%gs:8, %[value]"
        : [value] "=r" (-> u32),
    );
}

/// LAPIC ID recorded for the CPU executing this code.
pub fn lapicId() u32 {
    return asm volatile ("movl %%gs:12, %[value]"
        : [value] "=r" (-> u32),
    );
}

/// Point the interrupt entry path at an FXSAVE area for the current task.
pub fn setFpuState(address: u64) void {
    asm volatile ("movq %[value], %%gs:0"
        :
        : [value] "r" (address),
        : .{ .memory = true });
}

pub fn readMsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    const value = asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    _ = value;
    return @as(u64, low) | (@as(u64, high) << 32);
}

pub fn writeMsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))),
        : .{ .memory = true });
}

fn setGsBase(value: u64) void {
    writeMsr(0xc0000101, value);
}
