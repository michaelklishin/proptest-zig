const std = @import("std");
const pt = @import("proptest");
const testing = std.testing;

test "check passes for a property that always holds" {
    var r = pt.Runner.initFromSeed(.{ .cases = 64, .log_failures = false }, 1);
    try r.check(testing.allocator, pt.num.intInRange(i32, -100, 100), struct {
        fn run(x: i32) !void {
            if (x * 0 != 0) return error.ImpossibleZero;
        }
    }.run);
}

test "check reports failure for a property that fails immediately" {
    var r = pt.Runner.initFromSeed(.{ .cases = 64, .log_failures = false }, 2);
    const result = r.check(testing.allocator, pt.num.intInRange(i32, 0, 100), struct {
        fn run(x: i32) !void {
            if (x >= 0) return error.AlwaysFails;
        }
    }.run);
    try testing.expectError(error.PropertyFailed, result);
}

test "max_shrink_iters = 0 disables shrinking; lastFailing reports the initial counterexample" {
    var r = pt.Runner.initFromSeed(.{
        .cases = 16,
        .max_shrink_iters = 0,
        .log_failures = false,
    }, 42);
    const result = r.check(testing.allocator, pt.num.intInRange(i32, 0, 1000), struct {
        fn run(x: i32) !void {
            if (x >= 50) return error.AboveThreshold;
        }
    }.run);
    try testing.expectError(error.PropertyFailed, result);
    const shrunk = r.lastFailing();
    const parsed: i32 = std.fmt.parseInt(i32, shrunk, 10) catch -1;
    // Without shrinking, the reported value is whatever first failed; it
    // must be in the original [50, 1000] failing range, but is unlikely to
    // sit exactly at the boundary.
    try testing.expect(parsed >= 50 and parsed <= 1000);
}

test "Runner.lastFailing reports the shrunk minimum" {
    // Property fails for x >= 50. The shrinker should drive the
    // counterexample to a value at or just above 50.
    var r = pt.Runner.initFromSeed(.{ .cases = 16, .log_failures = false }, 42);
    const result = r.check(testing.allocator, pt.num.intInRange(i32, 0, 1000), struct {
        fn run(x: i32) !void {
            if (x >= 50) return error.AboveThreshold;
        }
    }.run);
    try testing.expectError(error.PropertyFailed, result);
    // We don't assert the exact text (formatting depends on `{any}`), but
    // the shrunk counterexample should be small relative to the initial
    // [0, 1000] domain.
    const shrunk = r.lastFailing();
    try testing.expect(shrunk.len > 0);
    // Sanity: the bisection should converge near 50 for this simple
    // threshold property; allow a small band to accommodate rounding.
    const parsed: i32 = std.fmt.parseInt(i32, shrunk, 10) catch -1;
    // The bisection should converge to the threshold (50). Allow a small
    // band for off-by-one rounding in midpoint computation.
    try testing.expect(parsed >= 50 and parsed <= 52);
}

test "check finds a regression in a buggy abs" {
    // Simulated buggy `abs` that misbehaves at -1.
    const buggyAbs = struct {
        fn f(x: i32) i32 {
            if (x == -1) return -1;
            return if (x < 0) -x else x;
        }
    }.f;

    var r = pt.Runner.initFromSeed(.{ .cases = 256, .log_failures = false }, 3);
    const result = r.check(testing.allocator, pt.num.intInRange(i32, -50, 50), struct {
        fn run(x: i32) !void {
            if (buggyAbs(x) < 0) return error.NegativeAbs;
        }
    }.run);
    try testing.expectError(error.PropertyFailed, result);
}

test "check passes commutativity over a tuple strategy" {
    var r = pt.Runner.initFromSeed(.{ .cases = 128, .log_failures = false }, 4);
    const ints = pt.num.intInRange(i32, -1000, 1000);
    const pair = pt.tuple.t2(ints, ints);
    try r.check(testing.allocator, pair, struct {
        fn run(p: struct { i32, i32 }) !void {
            if (p[0] + p[1] != p[1] + p[0]) return error.NotCommutative;
        }
    }.run);
}

test "lastFailing is cleared by a subsequent passing check" {
    var r = pt.Runner.initFromSeed(.{ .cases = 16, .log_failures = false }, 1);
    // First run fails; lastFailing should be populated.
    const failed = r.check(testing.allocator, pt.num.intInRange(i32, 0, 100), struct {
        fn run(x: i32) !void {
            if (x >= 0) return error.Always;
        }
    }.run);
    try testing.expectError(error.PropertyFailed, failed);
    try testing.expect(r.lastFailing().len > 0);
    // Second run passes; lastFailing should be reset to empty.
    try r.check(testing.allocator, pt.num.intInRange(i32, 0, 100), struct {
        fn run(_: i32) !void {}
    }.run);
    try testing.expectEqual(@as(usize, 0), r.lastFailing().len);
}

test "check passes for a non-error-returning predicate (void)" {
    var r = pt.Runner.initFromSeed(.{ .cases = 32, .log_failures = false }, 5);
    try r.check(testing.allocator, pt.boolean(), struct {
        fn run(b: bool) void {
            // This will always pass; predicate returns void.
            std.debug.assert(b == true or b == false);
        }
    }.run);
}
