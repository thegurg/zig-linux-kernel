const std = @import("std");

/// zig-kernel is a freestanding x86_64 kernel. The build produces a static
/// ELF that Limine loads in the higher half (see linker.ld).
pub fn build(b: *std.Build) void {
    // Default to ReleaseSafe: safety checks stay on (panics instead of UB) and
    // the LLVM-backed release pipeline is what applies our linker script
    // correctly. Use `-Doptimize=Debug` for source-level debugging.
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode") orelse .safe;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // Normal kernel image: stays alive after boot so it can be explored in QEMU.
    const kernel = makeKernel(b, target, optimize, "zig-kernel", false, false);
    b.installArtifact(kernel);

    // Smoke-test image: exercises the PMM, page tables, heap, PIT/IRQ0,
    // preemptive/cooperative scheduler, task lifecycle, blocking sleep,
    // explicit block/wake, wait queues and exception path, then reports
    // success to QEMU's isa-debug-exit so CI (and `zig build test`) can assert
    // the exit code.
    const selftest_kernel = makeKernel(b, target, optimize, "zig-kernel-selftest", true, false);
    const smoke = b.addSystemCommand(&.{ "bash", "tools/run.sh" });
    smoke.addArtifactArg(selftest_kernel);
    smoke.addArg("--test");
    smoke.has_side_effects = true;

    // Fault-test image: deliberately dereferences a null pointer to verify the
    // #PF gate, the CR2 report and the fatal-exception exit path.
    const fault_kernel = makeKernel(b, target, optimize, "zig-kernel-fault-test", false, true);
    const fault_smoke = b.addSystemCommand(&.{ "bash", "tools/run.sh" });
    fault_smoke.addArtifactArg(fault_kernel);
    fault_smoke.addArg("--test-fault");
    fault_smoke.has_side_effects = true;

    // Host-side unit tests for pure logic (no arch/IO dependencies).
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_unit_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));

    const test_step = b.step("test", "Run host unit tests and the QEMU smoke tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&smoke.step);
    test_step.dependOn(&fault_smoke.step);

    const run_cmd = b.addSystemCommand(&.{ "bash", "tools/run.sh" });
    run_cmd.addArtifactArg(kernel);
    run_cmd.has_side_effects = true;
    const run_step = b.step("run", "Boot the kernel in QEMU");
    run_step.dependOn(&run_cmd.step);
}

fn makeKernel(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    name: []const u8,
    exit_after_boot: bool,
    test_page_fault: bool,
) *std.Build.Step.Compile {
    const opts = b.addOptions();
    opts.addOption(bool, "exit_after_boot", exit_after_boot);
    opts.addOption(bool, "test_page_fault", test_page_fault);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .unwind_tables = .none,
        .pic = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "build_options", .module = opts.createModule() },
        },
    });
    mod.addAssemblyFile(b.path("src/arch/x86_64/interrupts.S"));

    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    exe.entry = .{ .symbol_name = "_start" };
    exe.use_llvm = true;
    exe.setLinkerScript(b.path("linker.ld"));
    return exe;
}
