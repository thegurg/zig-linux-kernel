# zig-kernel documentation

This directory is the maintained documentation for zig-kernel, a from-scratch
x86_64 kernel written in Zig and booted by Limine under UEFI. The documents are
split by subsystem and by development workflow so that each file can evolve
with the code it describes.

The project front page is [`../README.md`](../README.md). Source code remains
the final authority; where this documentation and the source disagree, the
source wins and the document should be corrected.

## Implementation status legend

| Status | Meaning |
| --- | --- |
| **IMPLEMENTED** | Present in the current source and exercised by the QEMU test flow unless noted. |
| **PARTIAL** | Present but limited, incomplete, or not safe for all current uses. |
| **PLACEHOLDER** | Scaffolding or diagnostics only; not a real implementation of the feature. |
| **PLANNED** | Not implemented yet. Planned work is kept separate from implemented behavior. |

The current release string in [`src/main.zig`](../src/main.zig) is
`0.13.0-m10`. Milestones M0 through M10 are implemented; M11 is planned.

## Architecture

| Document | Scope |
| --- | --- |
| [Overview](architecture/overview.md) | Goals, constraints, milestone status, source layout, and how the subsystems fit together. |
| [Boot and early bring-up](architecture/boot.md) | Limine/UEFI handoff, linker layout, `_start`, `kmain`, boot variants, and the console. |
| [Memory management](architecture/memory.md) | Physical page allocator, 4-level paging/HHDM, and the kernel heap. |
| [CPU and interrupts](architecture/cpu-interrupts.md) | SSE bring-up, GDT/TSS, IDT, exception/IRQ entry, PIC, and PIT. |
| [Scheduling](architecture/scheduling.md) | Task model, round-robin scheduler, task lifecycle, idle task, and FPU context switching. |
| [Synchronization](architecture/synchronization.md) | Spinlocks, IRQ masking, wait queues, mutexes, and condition variables. |
| [SMP bring-up](architecture/smp.md) | Limine MP protocol, AP entry, per-CPU stacks/TSS, and the SMP stress test. |

## Development

| Document | Scope |
| --- | --- |
| [Building](development/building.md) | Toolchain requirements, build options, kernel variants, and the QEMU harness. |
| [Testing](development/testing.md) | Host tests, QEMU smoke and fault tests, assertions, exit codes, and recorded results. |
| [Technical debt and known issues](development/technical-debt.md) | Correctness hazards, unsafe assumptions, and current limitations. |
| [Roadmap](development/roadmap.md) | Planned M11 work and later items, kept separate from implemented features. |

## Suggested reading paths

- New to the project: [Overview](architecture/overview.md) ->
  [Boot and early bring-up](architecture/boot.md) ->
  [Memory management](architecture/memory.md).
- Working on scheduling or synchronization: [Scheduling](architecture/scheduling.md)
  -> [Synchronization](architecture/synchronization.md) ->
  [Technical debt](development/technical-debt.md) ->
  [Roadmap](development/roadmap.md).
- Running or extending tests: [Building](development/building.md) ->
  [Testing](development/testing.md).

## Related documentation

- [Project README](../README.md)
- [Limine third-party notices](../third_party/limine/3RDPARTY.md)
- [Boot menu configuration](../boot/limine.conf)
- [Linker script](../linker.ld)
