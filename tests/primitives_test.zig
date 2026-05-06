const std = @import("std");
const pt = @import("proptest");
const testing = std.testing;

test "intInRange produces values inside the range" {
    var r = pt.Runner.initFromSeed(.{}, 1);
    const s = pt.num.intInRange(i32, -50, 50);
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        var t = try s.newTree(&r, testing.allocator);
        defer if (@hasDecl(@TypeOf(t), "deinit")) t.deinit();
        const v = t.current();
        try testing.expect(v >= -50 and v <= 50);
    }
}

test "floatInRange produces values inside the range" {
    var r = pt.Runner.initFromSeed(.{}, 2);
    const s = pt.num.floatInRange(f64, -1.0, 1.0);
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        var t = try s.newTree(&r, testing.allocator);
        const v = t.current();
        try testing.expect(v >= -1.0 and v <= 1.0);
    }
}

test "boolean produces both values over enough iterations" {
    var r = pt.Runner.initFromSeed(.{}, 3);
    const s = pt.boolean();
    var saw_true = false;
    var saw_false = false;
    var i: u32 = 0;
    while (i < 100 and (!saw_true or !saw_false)) : (i += 1) {
        var t = try s.newTree(&r, testing.allocator);
        if (t.current()) saw_true = true else saw_false = true;
    }
    try testing.expect(saw_true and saw_false);
}

test "weightedBoolean p=1.0 always returns true" {
    var r = pt.Runner.initFromSeed(.{}, 4);
    const s = pt.weightedBoolean(1.0);
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var t = try s.newTree(&r, testing.allocator);
        try testing.expect(t.current());
    }
}

test "weightedBoolean p=0.0 always returns false" {
    var r = pt.Runner.initFromSeed(.{}, 5);
    const s = pt.weightedBoolean(0.0);
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var t = try s.newTree(&r, testing.allocator);
        try testing.expect(!t.current());
    }
}

test "just always returns the same value" {
    var r = pt.Runner.initFromSeed(.{}, 6);
    const s = pt.just(@as(u32, 42));
    var t = try s.newTree(&r, testing.allocator);
    try testing.expectEqual(@as(u32, 42), t.current());
    try testing.expect(!t.simplify());
}
