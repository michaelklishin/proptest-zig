const std = @import("std");
const pt = @import("proptest");
const testing = std.testing;

// Two runs with the same seed must produce the same sequence of values.

test "intInRange is reproducible from a seed" {
    const s = pt.num.intInRange(i32, -1000, 1000);

    var r1 = pt.Runner.initFromSeed(.{}, 12345);
    var r2 = pt.Runner.initFromSeed(.{}, 12345);

    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var a = try s.newTree(&r1, testing.allocator);
        var b = try s.newTree(&r2, testing.allocator);
        try testing.expectEqual(a.current(), b.current());
    }
}

test "different seeds produce different sequences" {
    const s = pt.num.intInRange(i32, 0, 1_000_000);

    var r1 = pt.Runner.initFromSeed(.{}, 1);
    var r2 = pt.Runner.initFromSeed(.{}, 2);

    var any_diff = false;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        var a = try s.newTree(&r1, testing.allocator);
        var b = try s.newTree(&r2, testing.allocator);
        if (a.current() != b.current()) any_diff = true;
    }
    try testing.expect(any_diff);
}

test "boolean is reproducible from a seed" {
    var r1 = pt.Runner.initFromSeed(.{}, 999);
    var r2 = pt.Runner.initFromSeed(.{}, 999);
    const s = pt.boolean();

    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        var a = try s.newTree(&r1, testing.allocator);
        var b = try s.newTree(&r2, testing.allocator);
        try testing.expectEqual(a.current(), b.current());
    }
}
