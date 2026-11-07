# Building

**Purpose:** explain how to build zig-kernel, what the build produces, and how
the QEMU harness is configured.

**Implementation status:** the build and run flow is **IMPLEMENTED** for the
current UEFI/Limine target.

## Requirements

| Requirement | Notes |
| --- | --- |
| Zig 0.17.0 | Pinned in [`.zig-version`](../../.zig-version). The examples assume `~/.local/opt/toolchain/zig-x86_64-linux-0.17.0` is on `PATH`. |
| QEMU (`qemu-system-x86_64`) | Used for both interactive runs and automated tests. |
| OVMF | Default paths: `/usr/share/edk2/x64/OVMF_CODE.4m.fd` and `/usr/share/edk2/x64/OVMF_VARS.4m.fd`. |
| Linux host (x86_64) | Development is QEMU-first. No root or `sudo` is required. |
| Vendored Limine | [`third_party/limine/BOOTX64.EFI`](../../third_party/limine/BOOTX64.EFI) is checked in. |

`mtools`, `xorriso`, and `losetup` are not required. The harness builds an ESP
directory and exposes it to QEMU as a synthesized FAT drive through `vvfat`.

## Quick start

```bash
export PATH=~/.local/opt/toolchain/zig-x86_64-linux-0.17.0:$PATH
zig build        # build the normal kernel (default: ReleaseSafe)
zig build run    # boot the kernel in QEMU, serial on stdio
zig build test   # host tests + QEMU smoke and fault tests
```

The default optimization mode is `ReleaseSafe`. Override it with:

```bash
zig build -Doptimize=Debug
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseSmall
```

## Build configuration

[`build.zig`](../../build.zig) defines the target and module:

| Setting | Value |
| --- | --- |
| Target | `x86_64`, OS `freestanding`, ABI `none` |
| Code model | `.kernel` |
| Red zone | disabled |
| Stack check | disabled |
| Stack protector | disabled |
| Unwind tables | `.none` |
| PIC | disabled |
| Frame pointer omission | disabled (`omit_frame_pointer = false`) |
| LLVM backend | always enabled (`exe.use_llvm = true`) |
| Entry point | `_start` |
| Linker script | [`linker.ld`](../../linker.ld) |
| Assembly | [`interrupts.S`](../../src/arch/x86_64/interrupts.S), [`smp_entry.S`](../../src/arch/x86_64/smp_entry.S) |

LLVM is required because the self-hosted x86_64 backend in Zig 0.17 ignores
custom linker scripts.

The build creates three executables from the same `src/main.zig` root, passing
different `build_options`:

| Artifact | `exit_after_boot` | `test_page_fault` | Use |
| --- | --- | --- | --- |
| `zig-kernel` | `false` | `false` | Installed normal kernel; `zig build run`. |
| `zig-kernel-selftest` | `true` | `false` | Smoke tests; `zig build test`. |
| `zig-kernel-fault-test` | `false` | `true` | Deliberate `#PF`; `zig build test`. |

`zig build test` runs:

1. the host-side unit tests rooted at
   [`src/test_root.zig`](../../src/test_root.zig);
2. `bash tools/run.sh <selftest> --test`;
3. `bash tools/run.sh <fault-test> --test-fault`.

The QEMU steps are marked as side-effecting so the build system does not treat
them as cacheable pure commands.

## QEMU harness

[`tools/run.sh`](../../tools/run.sh) accepts three forms:

```bash
tools/run.sh <kernel.elf>                # interactive, serial on stdio
tools/run.sh <kernel.elf> --test         # headless smoke test, exit code = verdict
tools/run.sh <kernel.elf> --test-fault   # headless fault test, expects a handled #PF
```

### Default QEMU configuration

| Option | Value |
| --- | --- |
| Machine | `q35` |
| Acceleration | KVM with `-cpu host` when `/dev/kvm` is readable and writable; otherwise TCG with `-cpu max` |
| CPUs | `-smp 4` by default |
| Memory | 256 MiB |
| Firmware | OVMF code (read-only) and a writable copy of OVMF vars |
| ESP | `-drive format=raw,file=fat:rw:$ESP,if=none,id=esp` plus `virtio-blk-pci` |
| Boot order | `c` |
| Exit device | `isa-debug-exit,iobase=0xf4,iosize=0x04` |
| Other | `-no-reboot`, `-display none`, `-net none` |

The script copies `BOOTX64.EFI`, `boot/limine.conf` (to both
`EFI/BOOT/limine.conf` and the ESP root), and the requested kernel image (as
`zig-kernel`) into a temporary ESP. It copies OVMF vars so the firmware can
write to them.

### Environment overrides

| Variable | Effect |
| --- | --- |
| `ZIG_KERNEL_SMP=N` | Sets the QEMU CPU count. Default is 4. |
| `ZIG_KERNEL_NO_KVM=1` | Forces TCG even when KVM is available. |
| `LIMINE_BIN` | Overrides the vendored Limine directory. |
| `OVMF_CODE` | Overrides the OVMF code image path. |
| `OVMF_VARS_SRC` | Overrides the OVMF vars template path. |

## Exit codes

[`isa-debug-exit`](../../src/arch/x86_64/qemu.zig) reports
`(value << 1) | 1`:

| Kernel value | QEMU status | Meaning |
| --- | --- | --- |
| `0x10` (`EXIT_SUCCESS`) | 33 | Selftest passed. |
| `0x11` (`EXIT_FAILURE`) | 35 | Fatal exception, panic, or expected fault-test exit. |
| — | 124 | Harness timeout (90 seconds in test modes). |

The harness also inspects the serial log. See [testing](testing.md) for the
exact assertions.

## Formatting and hygiene

The project uses:

```bash
zig fmt --check build.zig src
git diff --check
```

Both were part of the M10 validation and passed. Running `zig fmt` on
`build.zig` and `src` keeps the Zig sources formatted; `git diff --check`
catches trailing whitespace and conflict markers.

## Troubleshooting

### Missing tools or firmware

`tools/run.sh` checks the kernel image, `BOOTX64.EFI`, OVMF code, and OVMF vars
before doing any work. It prints `run.sh: missing <path>` and exits 1 if any are
absent. Override the OVMF paths if the host stores them elsewhere.

### KVM unavailable or unstable

If `/dev/kvm` is not readable and writable, the harness automatically uses TCG.
Force TCG with `ZIG_KERNEL_NO_KVM=1` to reproduce emulator-only behavior. On
some nested-KVM hosts, `ldmxcsr` has been observed to fault; the kernel leaves
`MXCSR` at its reset value rather than programming it.

### Exercising a non-default CPU count

[`tools/run.sh`](../../tools/run.sh) reads `ZIG_KERNEL_SMP` (default 4) and uses
the same value for QEMU's `-smp` argument and for the expected
`smp: cpus=<N>` smoke marker. For example:

```bash
ZIG_KERNEL_SMP=2 zig build test
ZIG_KERNEL_SMP=1 zig build test
```

Both were verified during the pre-M11 bugfix pass. `ZIG_KERNEL_SMP=1` exercises
the no-AP path; `2` through `8` exercise AP bring-up and the SMP stress test.

### Interactive run appears to hang

The normal kernel is designed to stay alive after boot and hand control to the
idle task, so `tools/run.sh` without a test mode does not return on its own.
Use `Ctrl-C` or the QEMU monitor to stop it. In test modes, a 90-second timeout
turns a hang into status 124.

## Implementation status

| Feature | Status | Notes |
| --- | --- | --- |
| Reproducible Zig build | **IMPLEMENTED** | Pinned Zig version, vendored Limine. |
| Normal/selftest/fault variants | **IMPLEMENTED** | Built from the same root. |
| UEFI QEMU harness without root | **IMPLEMENTED** | `vvfat` ESP; no mtools/xorriso/losetup. |
| KVM with TCG fallback | **IMPLEMENTED** | Selected from `/dev/kvm` access. |
| Dynamic smoke-test CPU assertion | **IMPLEMENTED** | Derived from `ZIG_KERNEL_SMP`; verified with 1, 2, and 4 CPUs. |
| BIOS image | **PLANNED** | Not produced. |

## Related documentation

- [Documentation index](../README.md)
- [Boot and early bring-up](../architecture/boot.md)
- [Testing](testing.md)
- [Technical debt](technical-debt.md)
- [Project README](../../README.md)
