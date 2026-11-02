//! x86_64 CPU bring-up helpers.

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
