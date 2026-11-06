# zig-kernel

A from-scratch x86_64 kernel written in Zig, booted by [Limine](https://github.com/limine-bootloader/limine) under UEFI. Built for QEMU-first development with a single-command test flow.

## Status
- **M0 complete:** higher-half Limine/UEFI boot, framebuffer + COM1 console, HHDM and memory map reporting, SSE bring-up.
- **M1a complete:** own 64 KiB kernel stack, GDT/TSS (`RSP0` + 8 KiB #DF IST stack), 256-entry IDT, exception dispatcher for vectors 0-31, PIC remap/mask.
- **M1b complete:** bitmap physical page allocator built from the Limine memory map (4 GiB managed cap, zero page reserved, double-free protection).
- **M1c complete:** own 4-level page tables, higher-half kernel mapping, 4 GiB HHDM direct map, and a 64 MiB lazily-mapped kernel heap with `std.mem.Allocator` support.
- **M2 complete:** IRQ gates/stubs, 100 Hz PIT on IRQ0, full 15-GPR interrupt context save/restore, and a preemptive round-robin kernel task scheduler with per-task stacks.
- **M3 complete:** cooperative `yield`/`exit` software interrupts, an idle task that runs when no other task is ready, and reuse of finished task slots.
- **M4 complete:** timer-based blocking sleep (`sched.sleep`), deadline wakeups in the timer tick, and a small interrupt-safe lock (`sync.IrqLock`).
- **M5 complete:** explicit indefinite blocking (`sched.block`) and wakeup (`sched.wake`) with a blocked-task counter.
- **M6 complete:** `sched.WaitQueue` with `wait`, `wakeOne` and `wakeAll`, plus pruning of stale waiter entries.
- **M7 complete:** timed wait queues (`WaitQueue.waitTimeout`) that distinguish an explicit signal from a deadline timeout.
- **M8 complete:** blocking `sched.Mutex` with ownership transfer, plus `sched.Condition` with `wait`, `signal` and `broadcast`.
- **M9 complete:** FPU/SIMD context switching with per-task `FXSAVE`/`FXRSTOR` areas.
- **Next:** M10 - SMP bring-up and SMP-safe synchronization.

## Requirements
- Zig 0.17.0 (pinned in `.zig-version`)
- QEMU (`qemu-system-x86_64`), OVMF (`/usr/share/edk2/x64/OVMF_CODE.4m.fd`)
- Linux host (x86_64). No root/sudo required for development.

## Quick start
```bash
export PATH=~/.local/opt/toolchain/zig-x86_64-linux-0.17.0:$PATH
zig build        # build kernel (default: ReleaseSafe)
zig build run    # boot in QEMU (serial on stdio)
zig build test   # host tests + QEMU smoke and fault tests
```

Build options:
- `-Doptimize={debug,safe,fast,small}` (default: `safe`/`ReleaseSafe`)

`zig build test` builds two headless images and checks both with
`isa-debug-exit`:
- the selftest checks PMM allocation/free/reuse, page-table translation and
  map/unmap, heap allocation/alignment/coalescing, waits for 30 PIT ticks while
  two round-robin tasks yield and exit, creates a third task to verify
  finished-slot reuse, creates a sleeping task and checks that it wakes after
  its deadline, blocks a worker until the boot task wakes it explicitly, puts
  another worker on a wait queue and wakes it with `wakeOne`, verifies both the
  timeout and signaled paths of `WaitQueue.waitTimeout`, checks mutex exclusion
  across a yield and a condition-variable wait/signal handshake, checks that two
  tasks keep distinct `xmm0` patterns across a cooperative yield, triggers
  `int3` and must return from the handler (QEMU status 33);
- the fault test dereferences NULL and must report `#PF` with `CR2` before
  exiting through the failure path (QEMU status 35).

## Layout
```
boot/limine.conf   Limine menu/config
linker.ld          Higher-half layout, page-aligned PT_LOAD segments
src/
  arch/x86_64/     ports, serial, qemu exit, SSE, GDT/TSS, IDT, PIC, PIT
  arch/x86_64/interrupts.S  Exception/IRQ stubs and full GPR save/restore
  console.zig      framebuffer text console + serial mirroring
  font.zig         8x16 bitmap font
  limine.zig       Limine protocol bindings
  main.zig         _start, kmain, panic, boot sequence, M2-M9 smoke tests
  memory/pmm.zig   bitmap physical page allocator from the Limine memory map
  memory/vmm.zig   4-level page tables, kernel/HHDM mappings, CR3 switch
  memory/heap.zig  lazily mapped first-fit kernel heap + std.mem.Allocator
  sched.zig        scheduler, wait queues, mutex/condition, FPU state, idle task
  sync.zig         interrupt-safe critical-section lock (`IrqLock`)
tools/run.sh       Build ESP (vvfat) and launch QEMU
tools/genfont.py   Regenerate src/font.zig from a system font
third_party/limine/ Vendored Limine UEFI binary (BOOTX64.EFI)
```

## Notes
- KVM works with `-cpu host`; on some nested-KVM hosts we disable `ldmxcsr` (MXCSR stays at its reset value) to avoid an emulation issue while keeping SSE usable.
- Debug builds use the LLVM backend (`exe.use_llvm = true`) because the self-hosted x86_64 backend ignores custom linker scripts in Zig 0.17.
- `_start` switches from the Limine stack to a fixed 64 KiB kernel stack before calling `kmain`; double faults run on a separate 8 KiB IST stack.
- The PMM only frees `usable` memory-map ranges, never hands out the zero page, and uses a separate allocation bitmap so reserved pages (kernel image, firmware, framebuffer, MMIO) cannot be freed by mistake. Physical memory above 4 GiB is not managed yet.
- M1c forces 4-level paging, builds a fresh PML4, maps the kernel image at its Limine physical base, and maps the first 4 GiB of physical memory at the HHDM offset with 2 MiB pages. Kernel text/rodata are read-only and `CR0.WP` is enabled; the framebuffer's HHDM range is marked uncached.
- The heap reserves `0xffffffff90000000..0xffffffff94000000` and grows in 64 KiB batches from the PMM. It is a first-fit free-list allocator with block headers, coalescing, arbitrary power-of-two alignment, and a `std.mem.Allocator` adapter; `resize`/`remap` are not implemented yet.
- M2 programs the PIT channel 0 to 100 Hz on IRQ0 and unmasks only that PIC line. Every interrupt saves all 15 general-purpose registers into a common frame; the IRQ0 dispatcher sends EOI and calls the round-robin scheduler, which returns the saved-register base of the next task. `tasks[0]` is the boot context, and the selftest creates workers with static 16 KiB stacks.
- M3 adds software interrupts 48 and 49 for `sched.yield()` and `sched.exit()`. `tasks[1]` is a dedicated idle task that halts when no other task is ready, and finished slots are reused by later `create` calls. The normal kernel exits its boot task into the idle task after starting the timer. With 8 slots total (boot + idle + 6 user tasks), the task table is modified under `sync.IrqLock`.
- M4 adds software interrupt 50 for `sched.sleep(ticks)`. A sleeping task enters the `blocked` state with a wake tick; the IRQ0 handler marks it ready once the deadline passes, and the idle task covers the case where every other task is asleep. `sync.IrqLock` saves RFLAGS, disables interrupts for a short critical section, and restores the previous interrupt state; it is not reentrant and is only correct on a single CPU.
- M5 adds software interrupt 51 for `sched.block()` and `sched.wake(*Task)`. An indefinitely blocked task has no wake tick; another task must explicitly mark it ready. `sched.blockedCount()` exposes the number of blocked tasks, which the smoke test uses as a handshake before waking the worker.
- M6 adds `sched.WaitQueue`. Waiters are stored by task ID, so a reused slot cannot accidentally satisfy an old wakeup. `wakeOne` removes stale or already-ready entries and wakes the first task that is still blocked; `wakeAll` drains the queue.
- M7 adds software interrupt 53 for `WaitQueue.waitTimeout(ticks)`. A timed waiter is queued exactly like a normal waiter but carries a deadline; the timer tick or an explicit wake records why the task became ready, and `waitTimeout` returns `true` only for an explicit signal. Timed-out IDs stay in the queue until the next `wakeOne` or `compactLocked` pass prunes them.
- M8 adds `sched.Mutex` and `sched.Condition`. Mutex contention blocks on the same task queue used by other waits; `unlock` transfers ownership directly to the next waiter, so a resumed `lock` call already owns the mutex. `Condition.wait` atomically enqueues the waiter and releases the associated mutex, `signal`/`broadcast` wake one or all waiters, and the waiter reacquires the mutex before returning. Signalling without holding the predicate's mutex can still lose a wakeup; callers must follow the usual condition-variable discipline. Neither primitive is reentrant, and both rely on single-CPU interrupt disabling.
- M9 saves x87/SSE state at interrupt entry with `fxsave64` and restores it immediately before `iretq` with `fxrstor64`. Each task owns a 16-byte-aligned 512-byte `FpuState` area; `switchTask` points the exported `current_fpu_state` at the next task, and new/idle tasks inherit a clean `fninit` template with zeroed XMM registers. The `fxsave64`/`fxrstor64` pair is skipped while `current_fpu_state` is zero, so pre-scheduler exceptions still use the fault-test path. SMP-safe synchronization, per-CPU state and AP bring-up remain for M10.
