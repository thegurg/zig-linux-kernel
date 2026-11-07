//! Synchronization primitives.
//!
//! `SpinLock` is a real SMP-safe atomic lock: it spins on an atomic
//! exchange/load pair and uses acquire/release ordering. `IrqSpinLock` wraps it
//! with interrupt disabling, which is required when the same lock can also be
//! taken from an interrupt handler on the same CPU.
//!
//! Both `IrqSpinLock` and `IrqLock` return a guard from `acquire`. The saved
//! interrupt state lives in the guard on the caller's stack, not in the lock
//! object, so concurrent and nested acquisitions cannot overwrite each other's
//! flags. `release` takes the guard by value.
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

    pub const Guard = struct {
        owner: *IrqSpinLock,
        flags: u64,

        /// Release the lock and restore the interrupt state saved by the
        /// matching `acquire`.
        pub fn release(self: Guard) void {
            self.owner.lock.release();
            irqRestore(self.flags);
        }
    };

    /// Acquire the lock with interrupts disabled. The returned guard must be
    /// released exactly once, by the same CPU and on the same stack frame that
    /// acquired it.
    pub fn acquire(self: *IrqSpinLock) Guard {
        const flags = irqSave();
        asm volatile ("cli" ::: .{ .memory = true });
        self.lock.acquire();
        return .{ .owner = self, .flags = flags };
    }
};

pub const IrqLock = struct {
    pub const Guard = struct {
        flags: u64,

        /// Restore the interrupt state saved by the matching `acquire`.
        pub fn release(self: Guard) void {
            irqRestore(self.flags);
        }
    };

    /// Disable interrupts and return a guard carrying the previous state.
    /// `IrqLock` does not serialize against other CPUs; use `IrqSpinLock`
    /// whenever the protected state can be touched concurrently.
    pub fn acquire(self: *IrqLock) Guard {
        _ = self;
        const flags = irqSave();
        asm volatile ("cli" ::: .{ .memory = true });
        return .{ .flags = flags };
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
