const std = @import("std");
const runner = @import("runner.zig");
const Allocator = std.mem.Allocator;

//
// Integer strategies
//

/// A strategy that generates values of `T` over the inclusive range
/// `[lo, hi]` and shrinks toward `lo` (or toward zero if `lo <= 0 <= hi`).
pub fn intInRange(comptime T: type, lo: T, hi: T) IntInRange(T) {
    std.debug.assert(lo <= hi);
    return .{ .lo = lo, .hi = hi };
}

/// Convenience: full integer range for `T`.
pub fn int(comptime T: type) IntInRange(T) {
    return intInRange(T, std.math.minInt(T), std.math.maxInt(T));
}

pub fn IntInRange(comptime T: type) type {
    comptime std.debug.assert(@typeInfo(T) == .int);
    return struct {
        lo: T,
        hi: T,

        const Self = @This();
        pub const Value = T;
        pub const Tree = IntTree(T);

        pub fn newTree(self: Self, ctx: *runner.Runner, allocator: Allocator) !Tree {
            _ = allocator;
            const r = ctx.random();
            const value = r.intRangeAtMost(T, self.lo, self.hi);
            return Tree.init(self.lo, self.hi, value);
        }
    };
}

/// Binary-search shrinker for integers. Picks a target inside the range:
///   * `0` if `lo <= 0 <= hi`
///   * `lo` otherwise
/// On each `simplify`, halves the distance from `current` toward `target`;
/// `complicate` walks back toward the previous candidate, halving the gap.
pub fn IntTree(comptime T: type) type {
    comptime std.debug.assert(@typeInfo(T) == .int);
    return struct {
        const Self = @This();
        pub const Value = T;

        target: T,
        // `low` is the most aggressive simplification we know still fails.
        // `high` is the most conservative we've tested. Their midpoint is the
        // current candidate.
        low: T,
        high: T,
        cur: T,
        // `false` until the first `simplify` is called: simplify on the first
        // call jumps to the target, complicate then bisects.
        started: bool,

        pub fn init(lo: T, hi: T, value: T) Self {
            const target: T = if (lo <= 0 and 0 <= hi) 0 else lo;
            return .{
                .target = target,
                .low = target,
                .high = value,
                .cur = value,
                .started = false,
            };
        }

        pub fn current(self: *Self) T {
            return self.cur;
        }

        pub fn simplify(self: *Self) bool {
            if (!self.started) {
                // First simplify: jump to the target.
                self.started = true;
                if (self.cur == self.target) return false;
                self.cur = self.target;
                return true;
            }
            // Subsequent simplifies: try halfway between low and current.
            // The current value failed (caller flagged it as a failure), so
            // we treat it as the new ceiling.
            if (self.cur == self.low) return false;
            const candidate = midpointToward(self.low, self.cur);
            if (candidate == self.cur) return false;
            self.high = self.cur;
            self.cur = candidate;
            return true;
        }

        pub fn complicate(self: *Self) bool {
            // The most recent simplification went too far (predicate now
            // passes). Walk halfway back.
            if (!self.started) return false;
            if (self.cur == self.high) return false;
            const candidate = midpointToward(self.high, self.cur);
            if (candidate == self.cur) {
                // Can't bisect any further.
                return false;
            }
            self.low = self.cur;
            self.cur = candidate;
            return true;
        }
    };
}

/// Returns the integer halfway between `from` and `toward`, rounding so that
/// the result is *closer* to `toward` than `from` whenever they differ. For
/// equal inputs, returns the input unchanged.
fn midpointToward(from: anytype, toward: @TypeOf(from)) @TypeOf(from) {
    const T = @TypeOf(from);
    if (from == toward) return from;
    // Compute (from + toward) / 2 without overflow by working with the
    // signed difference.
    const Wide = std.meta.Int(@typeInfo(T).int.signedness, @typeInfo(T).int.bits + 1);
    const f: Wide = from;
    const t: Wide = toward;
    const mid = @divTrunc(f + t, 2);
    // Bias the rounding toward `toward` so that bisection actually moves.
    const result: T = @intCast(if (f < t and @rem(f + t, 2) != 0) mid + 1 else mid);
    return result;
}

//
// Float strategies
//

pub fn floatInRange(comptime T: type, lo: T, hi: T) FloatInRange(T) {
    // Reject NaN and infinities: with `lo = -inf, hi = +inf`, the
    // generation arithmetic `lo + u * (hi - lo)` produces NaN for almost
    // every `u`, silently wrecking the whole strategy.
    std.debug.assert(std.math.isFinite(lo));
    std.debug.assert(std.math.isFinite(hi));
    std.debug.assert(lo <= hi);
    return .{ .lo = lo, .hi = hi };
}

/// Convenience: a "useful by default" float range, `[-1e6, +1e6]`.
///
/// Note: unlike `num.int`, this is *not* the full type range. Generating
/// values up to `floatMax(T)` makes arithmetic in user predicates routinely
/// overflow into infinity, which is rarely what a property test wants. Use
/// `floatInRange` directly if you need a wider domain.
pub fn float(comptime T: type) FloatInRange(T) {
    return floatInRange(T, -1e6, 1e6);
}

pub fn FloatInRange(comptime T: type) type {
    comptime std.debug.assert(@typeInfo(T) == .float);
    return struct {
        lo: T,
        hi: T,

        const Self = @This();
        pub const Value = T;
        pub const Tree = FloatTree(T);

        pub fn newTree(self: Self, ctx: *runner.Runner, allocator: Allocator) !Tree {
            _ = allocator;
            const r = ctx.random();
            const u = r.float(T);
            const value = self.lo + u * (self.hi - self.lo);
            return Tree.init(self.lo, self.hi, value);
        }
    };
}

pub fn FloatTree(comptime T: type) type {
    comptime std.debug.assert(@typeInfo(T) == .float);
    return struct {
        const Self = @This();
        pub const Value = T;
        // Floats shrink toward zero if zero is in range, otherwise toward
        // the lower bound. We bisect between `low` and `cur` (or `high` and
        // `cur` for complicate) until the next candidate is within
        // `epsilon` of the current value, at which point further progress
        // is below the absolute precision we care about.
        const epsilon: T = 1e-9;

        target: T,
        low: T,
        high: T,
        cur: T,
        started: bool,

        pub fn init(lo: T, hi: T, value: T) Self {
            const target: T = if (lo <= 0 and 0 <= hi) 0 else lo;
            return .{
                .target = target,
                .low = target,
                .high = value,
                .cur = value,
                .started = false,
            };
        }

        pub fn current(self: *Self) T {
            return self.cur;
        }

        pub fn simplify(self: *Self) bool {
            if (!self.started) {
                self.started = true;
                if (@abs(self.cur - self.target) < epsilon) return false;
                self.high = self.cur;
                self.cur = self.target;
                return true;
            }
            const candidate = (self.low + self.cur) / 2.0;
            if (@abs(candidate - self.cur) < epsilon) return false;
            self.high = self.cur;
            self.cur = candidate;
            return true;
        }

        pub fn complicate(self: *Self) bool {
            if (!self.started) return false;
            const candidate = (self.high + self.cur) / 2.0;
            if (@abs(candidate - self.cur) < epsilon) return false;
            self.low = self.cur;
            self.cur = candidate;
            return true;
        }
    };
}

//
// Unit Tests
//

const testing = std.testing;

test "midpointToward is symmetric for equal inputs" {
    try testing.expectEqual(@as(i32, 5), midpointToward(@as(i32, 5), 5));
    try testing.expectEqual(@as(u32, 0), midpointToward(@as(u32, 0), 0));
}

test "midpointToward bisects strictly toward target" {
    // Standard midpoint: from 100 toward 0 -> 50.
    try testing.expectEqual(@as(i32, 50), midpointToward(@as(i32, 100), 0));
    // Asymmetric midpoint: integer truncation toward 0.
    try testing.expectEqual(@as(i32, 1), midpointToward(@as(i32, 0), 2));
    try testing.expectEqual(@as(i32, 5), midpointToward(@as(i32, 10), 1));
    // Adjacent values: bias forces a step toward `toward` rather than stalling.
    try testing.expectEqual(@as(i32, 2), midpointToward(@as(i32, 1), 2));
}

test "IntTree shrinks toward zero in mixed-sign range" {
    var t = IntTree(i32).init(-100, 100, 73);
    try testing.expectEqual(@as(i32, 73), t.current());
    try testing.expect(t.simplify());
    try testing.expectEqual(@as(i32, 0), t.current());
}

test "IntTree shrinks toward lo when zero is out of range" {
    var t = IntTree(i32).init(10, 100, 73);
    try testing.expect(t.simplify());
    try testing.expectEqual(@as(i32, 10), t.current());
}

test "IntTree refuses to simplify a value already at target" {
    var t = IntTree(i32).init(0, 100, 0);
    try testing.expect(!t.simplify());
}

test "intInRange works for u1" {
    var r = runner.Runner.initFromSeed(.{}, 1);
    var saw0 = false;
    var saw1 = false;
    var i: u32 = 0;
    while (i < 64 and (!saw0 or !saw1)) : (i += 1) {
        var t = try intInRange(u1, 0, 1).newTree(&r, std.testing.allocator);
        if (t.current() == 0) saw0 = true else saw1 = true;
    }
    try testing.expect(saw0 and saw1);
}

test "IntTree binary-search converges to the boundary" {
    // Property that fails for x >= 50. The simplify/complicate dance can
    // leave `current()` on the *passing* side of the boundary, so we track
    // the last known failing value separately, the same way the runner does.
    var t = IntTree(i32).init(0, 100, 80);
    var last_failing: i32 = t.current();
    var iters: u32 = 0;
    while (iters < 64) : (iters += 1) {
        const x = t.current();
        if (x >= 50) {
            last_failing = x;
            if (!t.simplify()) break;
        } else {
            if (!t.complicate()) break;
        }
    }
    try testing.expectEqual(@as(i32, 50), last_failing);
}
