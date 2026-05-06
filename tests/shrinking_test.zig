const std = @import("std");
const pt = @import("proptest");
const testing = std.testing;

// Tests that exercise the shrinker as a standalone state machine, without
// going through `check`. They simulate an external "pass/fail oracle" by
// driving simplify/complicate based on whether the current value satisfies
// a known property.

test "int shrinks to the smallest value that fails an x >= K threshold" {
    var r = pt.Runner.initFromSeed(.{}, 1);
    var t = try pt.num.intInRange(i32, 0, 1000).newTree(&r, testing.allocator);
    if (t.current() < 50) return; // generated value already passes

    // Drive shrinking the way the runner does: track the last known failing
    // value separately, since the simplify/complicate dance can leave the
    // tree at the largest known *passing* value.
    var last_failing: i32 = t.current();
    var iters: u32 = 0;
    while (iters < 256) : (iters += 1) {
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

test "int shrinks toward zero for a property that fails on non-zero" {
    var r = pt.Runner.initFromSeed(.{}, 2);
    var t = try pt.num.intInRange(i32, -1000, 1000).newTree(&r, testing.allocator);
    if (t.current() == 0) return;
    var iters: u32 = 0;
    while (iters < 256 and t.current() != 0) : (iters += 1) {
        if (!t.simplify()) break;
    }
    try testing.expectEqual(@as(i32, 0), t.current());
}

test "slice shrinks length toward min when failure persists" {
    var r = pt.Runner.initFromSeed(.{}, 3);
    const s = pt.collection.slice(pt.num.intInRange(i32, 0, 9), 0, 16);
    var t = try s.newTree(&r, testing.allocator);
    defer t.deinit();

    var iters: u32 = 0;
    while (iters < 256 and t.simplify()) : (iters += 1) {}
    try testing.expectEqual(@as(usize, 0), t.current().len);
}

test "slice shrinks element values once length is at minimum" {
    // The property fails iff any element is non-zero. After length shrinking
    // bottoms out at min_len, the element-shrink phase should drive every
    // surviving element to zero.
    var r = pt.Runner.initFromSeed(.{}, 91);
    const s = pt.collection.slice(pt.num.intInRange(i32, 0, 100), 3, 8);
    var t = try s.newTree(&r, testing.allocator);
    defer t.deinit();
    var iters: u32 = 0;
    while (iters < 1024 and t.simplify()) : (iters += 1) {}
    const v = t.current();
    try testing.expect(v.len >= 3);
    for (v) |x| try testing.expectEqual(@as(i32, 0), x);
}

test "slice with min_len > 0 keeps at least that many elements" {
    var r = pt.Runner.initFromSeed(.{}, 4);
    const s = pt.collection.slice(pt.num.intInRange(i32, 0, 9), 3, 10);
    var t = try s.newTree(&r, testing.allocator);
    defer t.deinit();

    var iters: u32 = 0;
    while (iters < 256 and t.simplify()) : (iters += 1) {}
    try testing.expect(t.current().len >= 3);
}

test "float shrinks toward zero for a property that fails on large positive" {
    var r = pt.Runner.initFromSeed(.{}, 100);
    var t = try pt.num.floatInRange(f64, 0.0, 1000.0).newTree(&r, testing.allocator);
    if (t.current() < 50.0) return;
    var last_failing: f64 = t.current();
    var iters: u32 = 0;
    while (iters < 256) : (iters += 1) {
        const x = t.current();
        if (x >= 50.0) {
            last_failing = x;
            if (!t.simplify()) break;
        } else {
            if (!t.complicate()) break;
        }
    }
    // The bisection runs on absolute epsilon (1e-9), so we should converge
    // very close to the boundary but the exact landing depends on the
    // sequence of midpoints.
    try testing.expect(last_failing >= 50.0);
    try testing.expect(last_failing < 50.0 + 1e-3);
}

test "float shrinks all the way to zero when the property fails everywhere" {
    var r = pt.Runner.initFromSeed(.{}, 200);
    var t = try pt.num.floatInRange(f64, -1000.0, 1000.0).newTree(&r, testing.allocator);
    var iters: u32 = 0;
    while (iters < 256 and t.simplify()) : (iters += 1) {}
    try testing.expectEqual(@as(f64, 0.0), t.current());
}

test "tuple shrinks left-to-right" {
    var r = pt.Runner.initFromSeed(.{}, 5);
    const s = pt.tuple.t2(
        pt.num.intInRange(i32, 0, 100),
        pt.num.intInRange(i32, 0, 100),
    );
    var t = try s.newTree(&r, testing.allocator);
    var iters: u32 = 0;
    while (iters < 64 and t.simplify()) : (iters += 1) {}
    const v = t.current();
    try testing.expectEqual(@as(i32, 0), v[0]);
    try testing.expectEqual(@as(i32, 0), v[1]);
}

test "tuple t3 shrinks all components" {
    var r = pt.Runner.initFromSeed(.{}, 6);
    const s = pt.tuple.t3(
        pt.num.intInRange(i32, 0, 100),
        pt.num.intInRange(i32, 0, 100),
        pt.num.intInRange(i32, 0, 100),
    );
    var t = try s.newTree(&r, testing.allocator);
    var iters: u32 = 0;
    while (iters < 128 and t.simplify()) : (iters += 1) {}
    const v = t.current();
    try testing.expectEqual(@as(i32, 0), v[0]);
    try testing.expectEqual(@as(i32, 0), v[1]);
    try testing.expectEqual(@as(i32, 0), v[2]);
}

test "tuple t4 shrinks all components" {
    var r = pt.Runner.initFromSeed(.{}, 7);
    const s = pt.tuple.t4(
        pt.num.intInRange(i32, 0, 100),
        pt.num.intInRange(i32, 0, 100),
        pt.num.intInRange(i32, 0, 100),
        pt.num.intInRange(i32, 0, 100),
    );
    var t = try s.newTree(&r, testing.allocator);
    var iters: u32 = 0;
    while (iters < 256 and t.simplify()) : (iters += 1) {}
    const v = t.current();
    try testing.expectEqual(@as(i32, 0), v[0]);
    try testing.expectEqual(@as(i32, 0), v[1]);
    try testing.expectEqual(@as(i32, 0), v[2]);
    try testing.expectEqual(@as(i32, 0), v[3]);
}

test "nested slice (slice of slice) shrinks length, allocates and frees correctly" {
    // Exercises recursive `Tree.deinit`: outer SliceTree owns N inner
    // SliceTrees, each with their own `trees`/`live`/`buf` allocations.
    // `testing.allocator` flags any leak.
    var r = pt.Runner.initFromSeed(.{}, 9);
    const inner = pt.collection.slice(pt.num.intInRange(i32, 0, 9), 0, 4);
    const outer = pt.collection.slice(inner, 0, 4);
    var t = try outer.newTree(&r, testing.allocator);
    defer t.deinit();
    var iters: u32 = 0;
    while (iters < 1024 and t.simplify()) : (iters += 1) {}
    try testing.expectEqual(@as(usize, 0), t.current().len);
}

test "slice of tuples shrinks both length and per-component" {
    // Composes Slice over Tuple2: length shrinks first, then each element's
    // tuple components shrink independently.
    var r = pt.Runner.initFromSeed(.{}, 8);
    const elem = pt.tuple.t2(
        pt.num.intInRange(i32, 0, 50),
        pt.num.intInRange(i32, 0, 50),
    );
    const s = pt.collection.slice(elem, 1, 6);
    var t = try s.newTree(&r, testing.allocator);
    defer t.deinit();
    var iters: u32 = 0;
    while (iters < 1024 and t.simplify()) : (iters += 1) {}
    const v = t.current();
    try testing.expect(v.len >= 1);
    for (v) |pair| {
        try testing.expectEqual(@as(i32, 0), pair[0]);
        try testing.expectEqual(@as(i32, 0), pair[1]);
    }
}
