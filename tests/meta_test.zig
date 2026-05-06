const std = @import("std");
const pt = @import("proptest");
const testing = std.testing;

// Meta tests: use proptest itself to assert properties of its primitives.
// These are the highest-leverage tests in the suite: if a generator is
// biased or a shrinker reaches the wrong fixed point, these are the most
// likely places to catch it.

test "intInRange always produces a value in [lo, hi]" {
    var r = pt.Runner.initFromSeed(.{ .cases = 256, .log_failures = false }, 1);
    const ranges = pt.tuple.t2(
        pt.num.intInRange(i32, -100, 100),
        pt.num.intInRange(i32, -100, 100),
    );
    try r.check(testing.allocator, ranges, struct {
        fn run(p: struct { i32, i32 }) !void {
            const lo = @min(p[0], p[1]);
            const hi = @max(p[0], p[1]);
            var inner = pt.Runner.initFromSeed(.{}, 9999);
            var t = try pt.num.intInRange(i32, lo, hi).newTree(&inner, testing.allocator);
            const v = t.current();
            if (v < lo or v > hi) return error.OutOfRange;
        }
    }.run);
}

test "IntTree.simplify() never crosses the target boundary" {
    var r = pt.Runner.initFromSeed(.{ .cases = 128, .log_failures = false }, 2);
    try r.check(testing.allocator, pt.num.intInRange(i32, -500, 500), struct {
        fn run(start: i32) !void {
            var t = pt.num.IntTree(i32).init(-500, 500, start);
            var prev = t.current();
            const target: i32 = if (-500 <= 0 and 0 <= 500) 0 else -500;
            // After any simplify, current must be on the same side of the
            // target as the previous current: never overshoot.
            var iters: u32 = 0;
            while (iters < 32 and t.simplify()) : (iters += 1) {
                const cur = t.current();
                const sign_prev = std.math.sign(prev - target);
                const sign_cur = std.math.sign(cur - target);
                if (sign_prev != 0 and sign_cur != 0 and sign_prev != sign_cur) {
                    return error.OvershotTarget;
                }
                prev = cur;
            }
        }
    }.run);
}

test "oneOf weight ratio holds approximately under a pinned seed" {
    // Pin the seed so this assertion is deterministic. We're checking that
    // a 9:1 weight ratio produces roughly 90% / 10% over a large sample,
    // not validating the exact frequencies (which depend on PRNG output).
    var r = pt.Runner.initFromSeed(.{}, 31337);
    const s = pt.oneOf(i32, .{
        .{ @as(u32, 9), pt.just(@as(i32, 0)) },
        .{ @as(u32, 1), pt.just(@as(i32, 1)) },
    });
    const N: usize = 4000;
    var ones: usize = 0;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        var t = try s.newTree(&r, testing.allocator);
        defer if (@hasDecl(@TypeOf(t), "deinit")) t.deinit();
        if (t.current() == 1) ones += 1;
    }
    // Expected ones: ~400 (10%). Allow a wide band to absorb PRNG variance
    // without making the test brittle.
    try testing.expect(ones > 250 and ones < 600);
}

test "slice always produces a length within the configured bounds" {
    var r = pt.Runner.initFromSeed(.{ .cases = 64, .log_failures = false }, 3);
    const lens = pt.tuple.t2(
        pt.num.intInRange(usize, 0, 16),
        pt.num.intInRange(usize, 0, 16),
    );
    try r.check(testing.allocator, lens, struct {
        fn run(p: struct { usize, usize }) !void {
            const lo = @min(p[0], p[1]);
            const hi = @max(p[0], p[1]);
            var inner = pt.Runner.initFromSeed(.{}, 4242);
            var t = try pt.collection.slice(pt.num.intInRange(i32, 0, 9), lo, hi).newTree(&inner, testing.allocator);
            defer t.deinit();
            const len = t.current().len;
            if (len < lo or len > hi) return error.OutOfBounds;
        }
    }.run);
}
