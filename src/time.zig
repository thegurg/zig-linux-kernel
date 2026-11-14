//! Monotonic kernel time base.
//!
//! The preferred clocksource is the invariant TSC. CPUID decides whether the
//! TSC exists and whether CPUID.80000007H:EDX[8] advertises a non-stop,
//! invariant TSC. The TSC is then calibrated on the BSP against PIT channel 2
//! over several short windows; an unstable calibration falls back to the
//! scheduler's calibrated 100 Hz tick counter. Both sources expose the same
//! `nowNs()` API and pass through the same monotonic clamp.
//!
//! `nowNs()` may be called from any CPU. A per-CPU TSC offset is installed by a
//! broadcast IPI after the APs are online (`syncAll`), so timestamps from
//! different CPUs are comparable. Before the sync the offsets are zero, which
//! is only correct on the BSP; no time consumer runs on an AP before it is
//! online and the BSP performs the sync.
//!
//! Time is deliberately independent of the scheduler's task table: the
//! scheduler reports CPU 0 ticks through `timerTick`, and in return the
//! scheduler uses the conversion helpers here for deadline durations. The
//! public API is:
//!
//! - `init(force_ticks)` selects the clocksource;
//! - `nowNs()` returns a nondecreasing nanosecond timestamp;
//! - `syncAll(online_mask)` installs cross-CPU TSC offsets;
//! - `timerTick(cpu)` advances the fallback tick clocksource;
//! - `msToTicks`/`nsToTicks` convert durations for the tick-based scheduler.

const cpu = @import("arch/x86_64/cpu.zig");
const lapic = @import("arch/x86_64/lapic.zig");
const pit = @import("arch/x86_64/pit.zig");

/// Scheduler tick frequency. CPU 0's PIT or LAPIC timer runs at this rate and
/// the fallback clocksource derives nanoseconds from its tick count.
pub const tick_hz: u32 = 100;

/// IPI vector used to stamp every online CPU's TSC against one BSP reference.
pub const sync_vector: u8 = 243;

const ns_per_second: u64 = 1_000_000_000;
const calibration_window_ms: u16 = 20;
const calibration_samples: usize = 3;
const calibration_tolerance_percent: u64 = 2;
const min_tsc_hz: u64 = 100_000_000;
const max_tsc_hz: u64 = 10_000_000_000;
const max_sync_spin: u64 = 100_000_000;

pub const Source = enum { ticks, tsc };

pub const FallbackReason = enum {
    none,
    forced,
    unsupported,
    non_invariant,
    calibration_failed,
    unstable,
    out_of_range,
};

pub const Info = struct {
    tsc_supported: bool,
    invariant_tsc: bool,
    tsc_calibrated: bool,
    tsc_hz: u64,
    source: Source,
    fallback_reason: FallbackReason,
    synced_cpus: u32,
    sync_skew_cycles: u64,
    sync_skew_ns: u64,
};

const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

var source: Source = .ticks;
var fallback_reason: FallbackReason = .none;

var tsc_supported = false;
var invariant_tsc = false;
var tsc_calibrated = false;
var tsc_hz: u64 = 0;
var tsc_base: u64 = 0;

/// Added to the raw clocksource value when the test hook switches sources so
/// the public timestamp never jumps backwards.
var tsc_ns_offset: u64 = 0;
var tick_ns_offset: u64 = 0;

/// CPU 0 timer ticks. Updated by `timerTick`; only CPU 0 advances it.
var tick_count: u64 = 0;

/// Global monotonic clamp. `@atomicRmw(.Max)` makes concurrent readers safe
/// without a lock and guarantees that no caller observes a backward step.
var last_ns: u64 = 0;

/// TSC correction per CPU, in cycles. Offset i means `raw_tsc + offset` is on
/// the BSP timeline. The BSP offset is always zero.
var tsc_offset: [cpu.max_cpus]i64 = @splat(0);

var sync_seq: u64 = 0;
var sync_reference: u64 = 0;
var sync_ack: [cpu.max_cpus]u64 = @splat(0);
var synced_mask: u64 = 0;
var sync_skew_cycles: u64 = 0;
var sync_skew_ns: u64 = 0;
var sync_interrupts: u64 = 0;

pub fn init(force_ticks: bool) void {
    detectTsc();

    source = .ticks;
    fallback_reason = .none;
    tsc_calibrated = false;
    tsc_hz = 0;
    tsc_base = 0;
    tsc_ns_offset = 0;
    tick_ns_offset = 0;
    tick_count = 0;
    last_ns = 0;
    tsc_offset = @splat(0);
    sync_seq = 0;
    sync_reference = 0;
    sync_ack = @splat(0);
    synced_mask = 0;
    sync_skew_cycles = 0;
    sync_skew_ns = 0;
    sync_interrupts = 0;

    if (force_ticks) {
        fallback_reason = .forced;
        return;
    }
    if (!tsc_supported) {
        fallback_reason = .unsupported;
        return;
    }
    if (!invariant_tsc) {
        fallback_reason = .non_invariant;
        return;
    }

    switch (calibrateTsc()) {
        .ok => {
            source = .tsc;
            tsc_calibrated = true;
        },
        .pit_failed => fallback_reason = .calibration_failed,
        .unstable => fallback_reason = .unstable,
        .out_of_range => fallback_reason = .out_of_range,
    }
}

pub fn info() Info {
    return .{
        .tsc_supported = tsc_supported,
        .invariant_tsc = invariant_tsc,
        .tsc_calibrated = tsc_calibrated,
        .tsc_hz = tsc_hz,
        .source = source,
        .fallback_reason = fallback_reason,
        .synced_cpus = @popCount(@atomicLoad(u64, &synced_mask, .acquire)),
        .sync_skew_cycles = sync_skew_cycles,
        .sync_skew_ns = sync_skew_ns,
    };
}

/// Current clocksource. `selectSourceForTest` can change it at run time; normal
/// kernel code should only observe it.
pub fn currentSource() Source {
    return source;
}

/// Nanoseconds since `init`. Nondecreasing on every CPU even when the raw
/// clocksource or a TSC offset moves backwards; the jump is clamped to the
/// previous published value.
pub fn nowNs() u64 {
    const raw = switch (source) {
        .tsc => tscNowNs(),
        .ticks => tickNowNs(),
    };
    const previous = @atomicRmw(u64, &last_ns, .Max, raw, .monotonic);
    return @max(previous, raw);
}

/// CPU 0 timer tick. Called by the scheduler from its timer interrupt before
/// deadline processing, so a sleeper that expires on this tick observes the
/// new timestamp.
pub fn timerTick(cpu_index: u32) void {
    if (cpu_index == 0) {
        _ = @atomicRmw(u64, &tick_count, .Add, 1, .monotonic);
    }
}

pub fn tickCount() u64 {
    return @atomicLoad(u64, &tick_count, .monotonic);
}

/// Convert a millisecond duration to scheduler ticks, rounding up. Zero stays
/// zero. The saturating bound is effectively "wait forever".
pub fn msToTicks(ms: u64) u64 {
    if (ms == 0) return 0;
    const max = ~@as(u64, 0);
    if (ms > (max - (tick_hz - 1)) / tick_hz) return max;
    return (ms * tick_hz + (tick_hz - 1)) / 1000;
}

/// Convert a nanosecond duration to scheduler ticks, rounding up.
pub fn nsToTicks(ns: u64) u64 {
    if (ns == 0) return 0;
    const max = ~@as(u64, 0);
    if (ns > (max - (ns_per_second - 1)) / tick_hz) return max;
    return (ns * tick_hz + (ns_per_second - 1)) / ns_per_second;
}

/// Install cross-CPU TSC offsets. The BSP broadcasts one reference TSC sample
/// and waits until every online target has acknowledged. Returns false only if
/// an IPI cannot be sent or the acknowledgement spins out; callers may keep
/// using the unsynchronised clock in that case.
pub fn syncAll(online_mask: u64) bool {
    if (source != .tsc or !tsc_calibrated) return true;

    const me = cpu.currentIndex();
    if (me >= cpu.max_cpus) return false;

    const reference = readTscOrdered();
    @atomicStore(u64, &sync_reference, reference, .release);
    const seq = @atomicRmw(u64, &sync_seq, .Add, 1, .monotonic) + 1;

    const self_bit = @as(u64, 1) << @intCast(me);
    const targets = online_mask & ~self_bit;

    var index: usize = 0;
    while (index < cpu.max_cpus) : (index += 1) {
        const bit = @as(u64, 1) << @intCast(index);
        if ((targets & bit) == 0) continue;
        if (!lapic.isInitialized()) return false;
        lapic.sendIpi(cpu.per_cpu[index].lapic_id, sync_vector);
    }

    var spin: u64 = 0;
    while (true) {
        var pending: u64 = 0;
        index = 0;
        while (index < cpu.max_cpus) : (index += 1) {
            const bit = @as(u64, 1) << @intCast(index);
            if ((targets & bit) == 0) continue;
            if (@atomicLoad(u64, &sync_ack[index], .acquire) < seq) pending |= bit;
        }
        if (pending == 0) break;
        if (spin >= max_sync_spin) return false;
        spin += 1;
        asm volatile ("pause");
    }

    @atomicStore(i64, &tsc_offset[me], 0, .monotonic);
    _ = @atomicRmw(u64, &synced_mask, .Or, self_bit, .release);
    computeSyncSkew(online_mask | self_bit);
    return true;
}

/// IPI handler. Samples the local TSC, converts it to the BSP timeline through
/// the shared reference, and acknowledges the sequence. It takes no locks so it
/// can run while a CPU is inside the scheduler waiting for another IPI.
pub fn tscSyncInterrupt() void {
    const index = cpu.currentIndex();
    if (index >= cpu.max_cpus) return;

    const seq = @atomicLoad(u64, &sync_seq, .acquire);
    if (seq == 0) return;
    const reference = @atomicLoad(u64, &sync_reference, .acquire);
    const raw = readTscOrdered();

    const offset = @as(i64, @bitCast(reference)) -% @as(i64, @bitCast(raw));
    @atomicStore(i64, &tsc_offset[index], offset, .release);
    _ = @atomicRmw(u64, &synced_mask, .Or, @as(u64, 1) << @intCast(index), .release);
    _ = @atomicRmw(u64, &sync_interrupts, .Add, 1, .monotonic);
    @atomicStore(u64, &sync_ack[index], seq, .release);
}

pub fn syncInterruptCount() u64 {
    return @atomicLoad(u64, &sync_interrupts, .monotonic);
}

/// Test hook: switch the public API between the two clocksources without
/// breaking monotonicity. The elapsed time is preserved in a source offset, so
/// `nowNs()` immediately before and after the switch are equal. Not intended
/// for concurrent use by normal kernel code.
pub fn selectSourceForTest(new_source: Source) void {
    if (new_source == source) return;
    if (new_source == .tsc and !tsc_calibrated) return;

    const now = nowNs();
    switch (new_source) {
        .ticks => tick_ns_offset = now -% rawTickNs(),
        .tsc => tsc_ns_offset = now -% rawTscNs(),
    }
    source = new_source;
}

const CalibrationResult = enum { ok, pit_failed, unstable, out_of_range };

fn calibrateTsc() CalibrationResult {
    var samples: [calibration_samples]u64 = undefined;
    var previous = readTscOrdered();

    for (&samples) |*sample| {
        if (!pit.delayBlockingMs(calibration_window_ms)) return .pit_failed;
        const current = readTscOrdered();
        const delta = current -% previous;
        previous = current;
        if (delta == 0) return .unstable;
        sample.* = (delta * 1000) / calibration_window_ms;
    }

    sortSamples(&samples);
    const low = samples[0];
    const median = samples[calibration_samples / 2];
    const high = samples[calibration_samples - 1];

    if (median < min_tsc_hz or median > max_tsc_hz) return .out_of_range;
    if (high - low > low / calibration_tolerance_percent) return .unstable;

    tsc_hz = median;
    tsc_base = readTscOrdered();
    return .ok;
}

fn sortSamples(samples: *[calibration_samples]u64) void {
    var i: usize = 1;
    while (i < calibration_samples) : (i += 1) {
        const value = samples[i];
        var j = i;
        while (j > 0 and samples[j - 1] > value) : (j -= 1) {
            samples[j] = samples[j - 1];
        }
        samples[j] = value;
    }
}

fn detectTsc() void {
    tsc_supported = false;
    invariant_tsc = false;

    const basic = cpuid(0, 0);
    if (basic.eax < 1) return;

    const leaf1 = cpuid(1, 0);
    tsc_supported = (leaf1.edx & (1 << 4)) != 0;
    if (!tsc_supported) return;

    const max_extended = cpuid(0x8000_0000, 0).eax;
    if (max_extended >= 0x8000_0007) {
        invariant_tsc = (cpuid(0x8000_0007, 0).edx & (1 << 8)) != 0;
    }
}

fn tscNowNs() u64 {
    return tsc_ns_offset +% rawTscNs();
}

fn rawTscNs() u64 {
    if (!tsc_calibrated) return 0;

    const index = cpu.currentIndex();
    const offset = if (index < cpu.max_cpus)
        @atomicLoad(i64, &tsc_offset[index], .monotonic)
    else
        0;

    const raw = readTscOrdered();
    const adjusted = raw +% @as(u64, @bitCast(offset));
    if (adjusted < tsc_base) return 0;
    return cyclesToNs(adjusted - tsc_base);
}

fn tickNowNs() u64 {
    return tick_ns_offset +% rawTickNs();
}

fn rawTickNs() u64 {
    const ticks = @atomicLoad(u64, &tick_count, .monotonic);
    return (ticks *% ns_per_second) / tick_hz;
}

fn cyclesToNs(cycles: u64) u64 {
    if (tsc_hz == 0) return 0;
    const whole = cycles / tsc_hz;
    const remainder = cycles % tsc_hz;
    const fraction = (remainder * ns_per_second) / tsc_hz;
    return whole *% ns_per_second +% fraction;
}

fn computeSyncSkew(mask: u64) void {
    var minimum: i64 = 0;
    var maximum: i64 = 0;
    var first = true;
    var index: usize = 0;
    while (index < cpu.max_cpus) : (index += 1) {
        const bit = @as(u64, 1) << @intCast(index);
        if ((mask & bit) == 0) continue;
        const offset = @atomicLoad(i64, &tsc_offset[index], .acquire);
        if (first) {
            minimum = offset;
            maximum = offset;
            first = false;
        } else {
            minimum = @min(minimum, offset);
            maximum = @max(maximum, offset);
        }
    }
    if (first) return;
    const spread: u64 = @intCast(maximum - minimum);
    sync_skew_cycles = spread;
    sync_skew_ns = cyclesToNs(spread);
}

fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = leaf;
    var ebx: u32 = undefined;
    var ecx: u32 = subleaf;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "+{eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "+{ecx}" (ecx),
          [edx] "={edx}" (edx),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn readTsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

fn readTscOrdered() u64 {
    asm volatile ("lfence" ::: .{ .memory = true });
    return readTsc();
}
