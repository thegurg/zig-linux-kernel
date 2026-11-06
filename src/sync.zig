//! Synchronization primitives.
//!
//! `SpinLock` is a real SMP-safe atomic lock: it spins on an atomic
//! exchange/load pair and uses acquire/release ordering. `IrqSpinLock` wraps it
//! with interrupt disabling, which is required when the same lock can also be
//! taken from an interrupt handler on the same CPU.
//!
//! `IrqLock` is the older single-CPU helper. It only disables interrupts and
//! restores the previous state; it does not serialize against other CPUs.

pub const SpinLock = struct {
    locked: u32 = 0,

    pub fn acquire(self: *SpinLock) void {
        while (true) {
            if (@atomicRmw(u32, &self.locked, .Xchg, 1, .acquire) == 0) return;
            while (@atomicLoad(u32, &self.locked, .monotonic) != 0) {
                asm volatile ("pause");
            }
        }
    }

    pub fn tryAcquire(self: *SpinLock) bool {
        return @atomicRmw(u32, &self.locked, .Xchg, 1, .acquire) == 0;
    }

    pub fn release(self: *SpinLock) void {
        @atomicStore(u32, &self.locked, 0, .release);
    }
};

pub const IrqSpinLock = struct {
    lock: SpinLock = .{},
    flags: u64 = 0,

    pub fn acquire(self: *IrqSpinLock) void {
        self.flags = irqSave();
        asm volatile ("cli" ::: .{ .memory = true });
        self.lock.acquire();
    }

    pub fn release(self: *IrqSpinLock) void {
        self.lock.release();
        irqRestore(self.flags);
    }
};

pub const IrqLock = struct {
    flags: u64 = 0,

    pub fn acquire(self: *IrqLock) void {
        self.flags = irqSave();
        asm volatile ("cli" ::: .{ .memory = true });
    }

    pub fn release(self: *IrqLock) void {
        irqRestore(self.flags);
    }
};

pub fn irqSave() u64 {
    return asm volatile ("pushfq; popq %[flags]"
        : [flags] "=r" (-> u64),
    );
}

pub fn irqRestore(flags: u64) void {
    asm volatile ("pushq %[flags]; popfq"
        :
        : [flags] "r" (flags),
        : .{ .memory = true });
}
