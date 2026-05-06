const std = @import("std");
const pt = @import("proptest");
const testing = std.testing;

fn doubleI32(x: i32) i32 {
    return x * 2;
}

fn negateI32(x: i32) i32 {
    return -x;
}

fn isEvenI32(x: i32) bool {
    return @rem(x, 2) == 0;
}

fn alwaysReject(_: i32) bool {
    return false;
}

test "map transforms values" {
    var r = pt.Runner.initFromSeed(.{}, 1);
    const doubled = pt.map(pt.num.intInRange(i32, 1, 10), i32, doubleI32);
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        var t = try doubled.newTree(&r, testing.allocator);
        const v = t.current();
        try testing.expect(v >= 2 and v <= 20);
        try testing.expect(@rem(v, 2) == 0);
    }
}

test "map preserves shrinking semantics" {
    var r = pt.Runner.initFromSeed(.{}, 2);
    const negated = pt.map(pt.num.intInRange(i32, -100, 100), i32, negateI32);
    var t = try negated.newTree(&r, testing.allocator);
    var iters: u32 = 0;
    while (iters < 64 and t.simplify()) : (iters += 1) {}
    try testing.expectEqual(@as(i32, 0), t.current());
}

test "filter only emits accepted values" {
    var r = pt.Runner.initFromSeed(.{}, 3);
    const evens = pt.filter(pt.num.intInRange(i32, 0, 100), isEvenI32);
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        var t = try evens.newTree(&r, testing.allocator);
        try testing.expect(@rem(t.current(), 2) == 0);
    }
}

test "filter bails when the predicate is impossible" {
    var r = pt.Runner.initFromSeed(.{ .max_filter_rejections = 32 }, 4);
    const impossible = pt.filter(pt.num.intInRange(i32, 0, 10), alwaysReject);
    try testing.expectError(error.FilterTooRestrictive, impossible.newTree(&r, testing.allocator));
}

test "tuple t2 generates pairs" {
    var r = pt.Runner.initFromSeed(.{}, 5);
    const s = pt.tuple.t2(
        pt.num.intInRange(i32, 0, 10),
        pt.boolean(),
    );
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        var t = try s.newTree(&r, testing.allocator);
        const v = t.current();
        try testing.expect(v[0] >= 0 and v[0] <= 10);
        _ = v[1];
    }
}

test "oneOf with all-zero weights returns an error rather than silently picking the last branch" {
    var r = pt.Runner.initFromSeed(.{}, 99);
    const s = pt.oneOf(i32, .{
        .{ @as(u32, 0), pt.just(@as(i32, 1)) },
        .{ @as(u32, 0), pt.just(@as(i32, 2)) },
    });
    try testing.expectError(error.OneOfAllZeroWeights, s.newTree(&r, testing.allocator));
}

test "oneOf with one zero-weight branch never picks it" {
    var r = pt.Runner.initFromSeed(.{}, 100);
    const s = pt.oneOf(i32, .{
        .{ @as(u32, 0), pt.just(@as(i32, 999)) },
        .{ @as(u32, 1), pt.just(@as(i32, 1)) },
        .{ @as(u32, 1), pt.just(@as(i32, 2)) },
    });
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var t = try s.newTree(&r, testing.allocator);
        defer if (@hasDecl(@TypeOf(t), "deinit")) t.deinit();
        try testing.expect(t.current() != 999);
    }
}

test "oneOf picks from the configured branches" {
    var r = pt.Runner.initFromSeed(.{}, 7);
    const s = pt.oneOf(i32, .{
        .{ @as(u32, 1), pt.just(@as(i32, 1)) },
        .{ @as(u32, 1), pt.just(@as(i32, 2)) },
        .{ @as(u32, 1), pt.just(@as(i32, 3)) },
    });
    var saw: [3]bool = .{ false, false, false };
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var t = try s.newTree(&r, testing.allocator);
        defer if (@hasDecl(@TypeOf(t), "deinit")) t.deinit();
        const v = t.current();
        try testing.expect(v >= 1 and v <= 3);
        saw[@intCast(v - 1)] = true;
    }
    try testing.expect(saw[0] and saw[1] and saw[2]);
}
