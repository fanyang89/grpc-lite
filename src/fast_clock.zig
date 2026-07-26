const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("cpucycles.h");
    @cInclude("stdio.h");
});

const Backend = enum(u8) {
    uninitialized,
    initializing,
    cycles,
    monotonic,
};

const FallbackReason = enum(u8) {
    none,
    counter_unavailable,
    unsupported_implementation,
    unstable_platform,
    invalid_frequency,
    unstable_initial_sample,
    counter_regression,
    conversion_overflow,
    runtime_drift,
};

const validation_interval_ns = 100 * std.time.ns_per_ms;
const validation_tolerance_ns = 2 * std.time.ns_per_ms;
const initial_sample_ns = 10 * std.time.ns_per_ms;

var backend: std.atomic.Value(u8) = .init(@intFromEnum(Backend.uninitialized));
var fallback_reason: std.atomic.Value(u8) = .init(@intFromEnum(FallbackReason.none));
var validation_lock: std.atomic.Value(bool) = .init(false);
var next_validation_cycles: std.atomic.Value(u64) = .init(0);
var base_cycles: u64 = 0;
var base_monotonic_ns: u64 = 0;
var cycles_per_second: u64 = 0;
var selected_implementation: [32:0]u8 = @splat(0);

pub fn now(io: std.Io) u64 {
    switch (loadBackend()) {
        .monotonic => return monotonicNow(io),
        .cycles => {},
        .uninitialized, .initializing => {
            ensureInitialized(io);
            return now(io);
        },
    }

    const cycles = readCycles() orelse {
        fallBack(.counter_unavailable);
        return monotonicNow(io);
    };
    const predicted = predictNs(cycles) orelse {
        fallBack(if (cycles < base_cycles) .counter_regression else .conversion_overflow);
        return monotonicNow(io);
    };
    validateIfDue(io, cycles, predicted);
    if (loadBackend() != .cycles) return monotonicNow(io);
    return predicted;
}

pub fn validatedNow(io: std.Io) u64 {
    const predicted = now(io);
    if (loadBackend() != .cycles) return predicted;

    const actual = monotonicNow(io);
    if (!withinTolerance(predicted, actual, validation_tolerance_ns)) {
        fallBack(.runtime_drift);
    }
    return actual;
}

pub fn usesCpuCycles() bool {
    return loadBackend() == .cycles;
}

pub fn implementation() []const u8 {
    return std.mem.sliceTo(&selected_implementation, 0);
}

pub fn fallbackReason() []const u8 {
    return @tagName(@as(FallbackReason, @enumFromInt(fallback_reason.load(.acquire))));
}

fn ensureInitialized(io: std.Io) void {
    while (true) switch (loadBackend()) {
        .cycles, .monotonic => return,
        .initializing => std.atomic.spinLoopHint(),
        .uninitialized => {
            if (backend.cmpxchgStrong(
                @intFromEnum(Backend.uninitialized),
                @intFromEnum(Backend.initializing),
                .acq_rel,
                .acquire,
            ) != null) continue;
            initialize(io);
            return;
        },
    };
}

fn initialize(io: std.Io) void {
    const first_cycles = readCycles() orelse return fallBack(.counter_unavailable);
    const implementation_pointer = c.cpucycles_implementation() orelse return fallBack(.counter_unavailable);
    const implementation_name = std.mem.span(implementation_pointer);
    const copy_length = @min(implementation_name.len, selected_implementation.len - 1);
    @memcpy(selected_implementation[0..copy_length], implementation_name[0..copy_length]);
    if (!implementationCanBeStable(implementation_name)) return fallBack(.unsupported_implementation);
    if (!platformSourceIsStable(implementation_name)) return fallBack(.unstable_platform);

    const frequency = c.cpucycles_persecond();
    if (frequency <= 0) return fallBack(.invalid_frequency);
    cycles_per_second = @intCast(frequency);

    const first_ns = monotonicNow(io);
    std.Io.sleep(io, .fromNanoseconds(initial_sample_ns), .awake) catch return fallBack(.unstable_initial_sample);
    const second_cycles = readCycles() orelse return fallBack(.counter_unavailable);
    const second_ns = monotonicNow(io);
    if (!stableInterval(first_cycles, second_cycles, first_ns, second_ns, cycles_per_second)) {
        return fallBack(.unstable_initial_sample);
    }

    base_cycles = second_cycles;
    base_monotonic_ns = second_ns;
    const interval_cycles = scaleNsToCycles(validation_interval_ns, cycles_per_second) orelse
        return fallBack(.conversion_overflow);
    next_validation_cycles.store(second_cycles +| interval_cycles, .release);
    backend.store(@intFromEnum(Backend.cycles), .release);
}

fn validateIfDue(io: std.Io, cycles: u64, predicted_ns: u64) void {
    if (cycles < next_validation_cycles.load(.acquire)) return;
    if (validation_lock.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    defer validation_lock.store(false, .release);
    if (loadBackend() != .cycles) return;

    const actual_ns = monotonicNow(io);
    if (!withinTolerance(predicted_ns, actual_ns, validation_tolerance_ns)) {
        fallBack(.runtime_drift);
        return;
    }
    const interval_cycles = scaleNsToCycles(validation_interval_ns, cycles_per_second) orelse {
        fallBack(.conversion_overflow);
        return;
    };
    next_validation_cycles.store(cycles +| interval_cycles, .release);
}

fn predictNs(cycles: u64) ?u64 {
    if (cycles < base_cycles) return null;
    const elapsed_ns = scaleCyclesToNs(cycles - base_cycles, cycles_per_second) orelse return null;
    return std.math.add(u64, base_monotonic_ns, elapsed_ns) catch null;
}

fn readCycles() ?u64 {
    const read = c.cpucycles orelse return null;
    const value = read();
    return if (value >= 0) @intCast(value) else null;
}

fn monotonicNow(io: std.Io) u64 {
    const value = std.Io.Clock.awake.now(io).nanoseconds;
    return std.math.cast(u64, @max(value, @as(i96, 0))) orelse std.math.maxInt(u64);
}

fn loadBackend() Backend {
    return @enumFromInt(backend.load(.acquire));
}

fn fallBack(reason: FallbackReason) void {
    fallback_reason.store(@intFromEnum(reason), .release);
    backend.store(@intFromEnum(Backend.monotonic), .release);
}

fn implementationCanBeStable(name: []const u8) bool {
    return std.mem.eql(u8, name, "amd64-tsc") or
        std.mem.eql(u8, name, "amd64-tscasm") or
        std.mem.eql(u8, name, "x86-tsc") or
        std.mem.eql(u8, name, "x86-tscasm") or
        std.mem.eql(u8, name, "arm64-vct");
}

fn platformSourceIsStable(name: []const u8) bool {
    if (std.mem.eql(u8, name, "arm64-vct")) {
        return fileHasToken(
            "/sys/devices/system/clocksource/clocksource0/available_clocksource",
            "arch_sys_counter",
        );
    }
    return fileHasToken("/proc/cpuinfo", "constant_tsc") and
        fileHasToken("/proc/cpuinfo", "nonstop_tsc") and
        fileHasToken(
            "/sys/devices/system/clocksource/clocksource0/available_clocksource",
            "tsc",
        );
}

fn fileHasToken(path: [*:0]const u8, token: []const u8) bool {
    const file = c.fopen(path, "r") orelse return false;
    defer _ = c.fclose(file);
    var buffer: [64 * 1024]u8 = undefined;
    const length = c.fread(&buffer, 1, buffer.len, file);
    return hasToken(buffer[0..length], token);
}

fn hasToken(input: []const u8, token: []const u8) bool {
    var iterator = std.mem.tokenizeAny(u8, input, " \t\r\n");
    while (iterator.next()) |candidate| {
        if (std.mem.eql(u8, candidate, token)) return true;
    }
    return false;
}

fn stableInterval(first_cycles: u64, second_cycles: u64, first_ns: u64, second_ns: u64, frequency: u64) bool {
    if (second_cycles <= first_cycles or second_ns <= first_ns) return false;
    const cycle_ns = scaleCyclesToNs(second_cycles - first_cycles, frequency) orelse return false;
    const monotonic_ns = second_ns - first_ns;
    return withinTolerance(cycle_ns, monotonic_ns, @max(100 * std.time.ns_per_us, monotonic_ns / 100));
}

fn withinTolerance(first: u64, second: u64, tolerance: u64) bool {
    const difference = if (first > second) first - second else second - first;
    return difference <= tolerance;
}

fn scaleCyclesToNs(cycles: u64, frequency: u64) ?u64 {
    if (frequency == 0) return null;
    const scaled = @as(u128, cycles) * std.time.ns_per_s / frequency;
    return std.math.cast(u64, scaled);
}

fn scaleNsToCycles(nanoseconds: u64, frequency: u64) ?u64 {
    const scaled = @as(u128, nanoseconds) * frequency / std.time.ns_per_s;
    return std.math.cast(u64, scaled);
}

test "stable implementations exclude performance and OS counters" {
    try std.testing.expect(implementationCanBeStable("amd64-tsc"));
    try std.testing.expect(implementationCanBeStable("arm64-vct"));
    try std.testing.expect(!implementationCanBeStable("amd64-perfpmc"));
    try std.testing.expect(!implementationCanBeStable("default-monotonic"));
}

test "token detection observes exact platform capability names" {
    try std.testing.expect(hasToken("flags: tsc constant_tsc nonstop_tsc", "constant_tsc"));
    try std.testing.expect(!hasToken("flags: tsc_reliable", "tsc"));
}

test "stability sampling rejects regressions and clock drift" {
    const frequency = 2_000_000_000;
    try std.testing.expect(stableInterval(10, 20_000_010, 50, 10_000_050, frequency));
    try std.testing.expect(!stableInterval(20, 10, 50, 10_000_050, frequency));
    try std.testing.expect(!stableInterval(10, 24_000_010, 50, 10_000_050, frequency));
}

test "host platform accepts its kernel monotonic counter" {
    if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
        try std.testing.expect(platformSourceIsStable("amd64-tsc"));
    } else if (builtin.cpu.arch == .aarch64) {
        try std.testing.expect(platformSourceIsStable("arm64-vct"));
    }
}
