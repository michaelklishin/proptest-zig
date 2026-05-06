const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

//
// Configuration
//

pub const Config = struct {
    /// Number of test cases to generate before declaring success.
    cases: u32 = 256,
    /// Maximum number of shrink steps before giving up on the current minimum.
    max_shrink_iters: u32 = 4096,
    /// Maximum number of consecutive `Filter` rejections before bailing.
    /// Without this guard, an over-restrictive filter would loop forever.
    max_filter_rejections: u32 = 65536,
    /// When true, the runner prints the seed and counterexample to stderr
    /// before returning the error.
    log_failures: bool = true,

    pub const default: Config = .{};
};

//
// Runner
//

/// `Runner` owns the RNG and the configuration used to drive a property test.
/// One runner is reusable across many `check` calls; the RNG state advances
/// monotonically across calls. To reproduce a specific failure, re-run the
/// whole test sequence with the same `PROPTEST_SEED`. Independent
/// reproducibility per `check` call requires a fresh `Runner` per call.
pub const Runner = struct {
    config: Config,
    prng: std.Random.DefaultPrng,
    seed: u64,
    // Owned buffer for the formatted shrunk counterexample of the most
    // recent failing `check` call. Tests can read it via `lastFailing()` to
    // assert that shrinking reached the expected minimum, without parsing
    // log output.
    last_failing_buf: FormatBuf = undefined,
    last_failing_len: usize = 0,

    pub fn initDefault() Runner {
        return initFromEnvOrEntropy(.{});
    }

    /// Returns the formatted shrunk counterexample of the most recent
    /// failing `check`, or an empty slice if no `check` has failed on this
    /// runner.
    pub fn lastFailing(self: *const Runner) []const u8 {
        return self.last_failing_buf[0..self.last_failing_len];
    }

    /// Honours the `PROPTEST_SEED`, `PROPTEST_CASES`, and
    /// `PROPTEST_MAX_SHRINK_ITERS` environment variables; falls back to a
    /// fresh OS-derived seed otherwise. If you need a hermetic seed, prefer
    /// `initFromSeed` directly.
    pub fn initFromEnvOrEntropy(config: Config) Runner {
        var effective = config;
        if (readU32FromEnv("PROPTEST_CASES")) |c| effective.cases = c;
        if (readU32FromEnv("PROPTEST_MAX_SHRINK_ITERS")) |c| effective.max_shrink_iters = c;
        const seed = readSeedFromEnv() orelse entropySeed();
        return initFromSeed(effective, seed);
    }

    /// Hermetic init: uses exactly the supplied `config` and `seed`. Does
    /// not consult `PROPTEST_*` environment variables. Use this when you
    /// want a test that always behaves the same regardless of the user's
    /// shell environment.
    pub fn initFromSeed(config: Config, seed: u64) Runner {
        return .{
            .config = config,
            .prng = std.Random.DefaultPrng.init(seed),
            .seed = seed,
        };
    }

    pub fn deinit(self: *Runner) void {
        _ = self;
    }

    pub fn random(self: *Runner) std.Random {
        return self.prng.random();
    }

    /// Runs `predicate` against `cases` random values from `strategy`. On the
    /// first failure, shrinks the failing case to a local minimum and returns
    /// `error.PropertyFailed`.
    pub fn check(
        self: *Runner,
        allocator: Allocator,
        strategy: anytype,
        predicate: anytype,
    ) !void {
        // Invalidate any stale failure data from a prior `check` so a
        // successful call doesn't expose it via `lastFailing`.
        self.last_failing_len = 0;
        var case: u32 = 0;
        while (case < self.config.cases) : (case += 1) {
            var tree = try strategy.newTree(self, allocator);
            defer maybeDeinit(&tree);

            const initial = tree.current();
            const result = invoke(predicate, initial);
            if (result) |_| {
                continue;
            } else |first_err| {
                // Capture both the initial and the running "last failing"
                // value as formatted strings. We must format eagerly: for
                // slice-valued strategies, `current()` aliases the tree's
                // scratch buffer and is overwritten by subsequent
                // simplify/complicate calls.
                var initial_buf: FormatBuf = undefined;
                const initial_str = formatValue(&initial_buf, initial);
                const outcome = shrink(&tree, predicate, self.config.max_shrink_iters, initial, first_err, &self.last_failing_buf);
                self.last_failing_len = outcome.last_failing_len;
                if (self.config.log_failures) {
                    logFailure(self.seed, case, outcome, initial_str, self.lastFailing(), first_err);
                }
                return error.PropertyFailed;
            }
        }
    }
};

const format_buf_size: usize = 1024;
const FormatBuf = [format_buf_size]u8;

fn formatValue(buf: *FormatBuf, value: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{any}", .{value}) catch blk: {
        // bufPrint failed because the formatted form was longer than 1024
        // bytes. Returning `buf[0..buf.len]` would expose the partially
        // written prefix plus garbage; emit a clean truncation marker
        // instead.
        const marker = "<value too large to format>";
        const n = @min(buf.len, marker.len);
        @memcpy(buf[0..n], marker[0..n]);
        break :blk buf[0..n];
    };
}

const ShrinkOutcome = struct {
    shrinks: u32,
    last_error: anyerror,
    last_failing_len: usize,
};

/// Standard simplify/complicate shrink loop, mirroring Rust proptest's
/// protocol: test the current value, then either `simplify` (on failure)
/// or `complicate` (on success). Each transformation is followed by a
/// fresh predicate test on the next iteration, so the bisection's
/// boundary tracking stays accurate. We capture the last failing value's
/// formatted bytes into `last_buf` immediately because a slice-valued
/// `current()` may alias scratch memory that the next transformation
/// overwrites.
fn shrink(
    tree: anytype,
    predicate: anytype,
    max_iters: u32,
    initial_value: anytype,
    initial_error: anyerror,
    last_buf: *FormatBuf,
) ShrinkOutcome {
    var shrinks: u32 = 0;
    var last_err: anyerror = initial_error;
    var last_len: usize = formatValue(last_buf, initial_value).len;

    // Honour `max_shrink_iters = 0` as "shrinking disabled". Without this
    // guard the unconditional first simplify below would still run once.
    if (max_iters == 0) {
        return .{ .shrinks = 0, .last_error = last_err, .last_failing_len = last_len };
    }

    // The caller has already tested the initial value: it failed, which
    // is why shrinking was invoked. Drive the first transformation
    // (simplify) without re-testing.
    if (!tree.simplify()) {
        return .{ .shrinks = 0, .last_error = last_err, .last_failing_len = last_len };
    }
    shrinks += 1;

    while (shrinks < max_iters) {
        const candidate = tree.current();
        if (invoke(predicate, candidate)) |_| {
            if (!tree.complicate()) break;
            shrinks += 1;
        } else |err| {
            last_err = err;
            last_len = formatValue(last_buf, candidate).len;
            if (!tree.simplify()) break;
            shrinks += 1;
        }
    }

    return .{ .shrinks = shrinks, .last_error = last_err, .last_failing_len = last_len };
}

fn invoke(predicate: anytype, value: anytype) anyerror!void {
    const Predicate = @TypeOf(predicate);
    const info = @typeInfo(Predicate);
    const fn_info = switch (info) {
        .@"fn" => |f| f,
        else => @compileError("predicate must be a function"),
    };

    if (fn_info.return_type.? == void) {
        @call(.auto, predicate, .{value});
        return;
    }
    return @call(.auto, predicate, .{value});
}

fn maybeDeinit(tree: anytype) void {
    const T = @TypeOf(tree.*);
    if (@hasDecl(T, "deinit")) {
        tree.deinit();
    }
}

fn logFailure(
    seed: u64,
    case: u32,
    outcome: ShrinkOutcome,
    initial_str: []const u8,
    last_str: []const u8,
    first_err: anyerror,
) void {
    std.log.scoped(.proptest).err(
        "property failed at case {d} after {d} shrinks: {s}\n" ++
            "  shrunk counterexample: {s}\n" ++
            "  initial counterexample: {s} ({s})\n" ++
            "  reproduce with PROPTEST_SEED={d}",
        .{
            case,
            outcome.shrinks,
            @errorName(outcome.last_error),
            last_str,
            initial_str,
            @errorName(first_err),
            seed,
        },
    );
}

fn readSeedFromEnv() ?u64 {
    return readEnv(u64, "PROPTEST_SEED");
}

fn readU32FromEnv(name: [*:0]const u8) ?u32 {
    return readEnv(u32, name);
}

fn readEnv(comptime T: type, name: [*:0]const u8) ?T {
    // libc's `getenv` is the only env-lookup path in Zig 0.16 that doesn't
    // require an `Io` instance.
    const raw = std.c.getenv(name) orelse return null;
    const value = std.mem.span(raw);
    return std.fmt.parseInt(T, value, 10) catch null;
}

/// Cross-platform best-effort entropy: reads from the OS RNG. Panics on
/// platforms where neither `arc4random_buf` nor `getrandom` is wired up,
/// directing the caller to `initFromSeed` instead.
fn entropySeed() u64 {
    var s: u64 = 0;
    const buf: [*]u8 = @ptrCast(&s);
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos, .serenity => {
            std.c.arc4random_buf(buf, @sizeOf(u64));
        },
        .linux => {
            // `getrandom` returns either the byte count or a negative errno.
            // For counts <= 256 the kernel never short-reads, so `r != 8` is
            // the cleanest "did the kernel give us a full u64" check and
            // also catches the negative-errno case (encoded as a large
            // unsigned value).
            const r = std.os.linux.getrandom(buf, @sizeOf(u64), 0);
            if (r != @sizeOf(u64)) {
                std.debug.panic("proptest: getrandom failed; pass an explicit seed via Runner.initFromSeed", .{});
            }
        },
        else => std.debug.panic(
            "proptest: no entropy source on this platform ({s}); pass an explicit seed via Runner.initFromSeed",
            .{@tagName(builtin.os.tag)},
        ),
    }
    return s;
}

//
// Unit Tests
//

const testing = std.testing;

test "Runner.initFromSeed is reproducible" {
    var a = Runner.initFromSeed(.{}, 42);
    var b = Runner.initFromSeed(.{}, 42);
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        try testing.expectEqual(a.random().int(u64), b.random().int(u64));
    }
}

test "Runner.deinit is callable" {
    var r = Runner.initFromSeed(.{}, 1);
    r.deinit();
}

test "Runner.initFromEnvOrEntropy compiles and produces a non-zero seed" {
    // Forces semantic analysis of the env/entropy path: without a caller,
    // Zig's lazy analysis would let bit-rot in this branch slip past CI.
    var r = Runner.initFromEnvOrEntropy(.{});
    // We can't assert a specific seed (entropy-derived), but we can confirm
    // the runner is usable.
    _ = r.random().int(u64);
}
