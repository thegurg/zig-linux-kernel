//! Synchronization groundwork for the single-CPU kernel.
//!
//! `IrqLock` disables interrupts while a short critical section runs and
//! restores the previous interrupt state on release. It is not reentrant and
//! does not protect against other CPUs; SMP will need real atomic locks.

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
