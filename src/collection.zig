const std = @import("std");
const runner = @import("runner.zig");
const num = @import("num.zig");
const Allocator = std.mem.Allocator;

//
// Slice
//
// Generates a slice of `T` whose length is in `[min_len, max_len]` and whose
// elements are produced by `elem_strategy`. Shrinks length toward `min_len`
// then shrinks individual elements left-to-right.
//

pub fn slice(elem_strategy: anytype, min_len: usize, max_len: usize) Slice(@TypeOf(elem_strategy)) {
    std.debug.assert(min_len <= max_len);
    return .{
        .elem = elem_strategy,
        .min_len = min_len,
        .max_len = max_len,
    };
}

pub fn Slice(comptime ElemStrategy: type) type {
    const T = ElemStrategy.Value;
    const ElemTree = ElemStrategy.Tree;

    return struct {
        elem: ElemStrategy,
        min_len: usize,
        max_len: usize,

        const Self = @This();
        pub const Value = []const T;
        pub const Tree = SliceTree(T, ElemTree);

        pub fn newTree(self: Self, ctx: *runner.Runner, allocator: Allocator) !Tree {
            const r = ctx.random();
            const len = r.intRangeAtMost(usize, self.min_len, self.max_len);

            const trees = try allocator.alloc(ElemTree, len);
            // Track how many element trees we've successfully built so the
            // errdefer doesn't run `deinit` over uninitialised memory if a
            // later element strategy fails mid-loop.
            var built: usize = 0;
            errdefer {
                if (@hasDecl(ElemTree, "deinit")) {
                    for (trees[0..built]) |*t| t.deinit();
                }
                allocator.free(trees);
            }
            while (built < len) : (built += 1) {
                trees[built] = try self.elem.newTree(ctx, allocator);
            }

            const live = try allocator.alloc(bool, len);
            errdefer allocator.free(live);
            @memset(live, true);

            const buf = try allocator.alloc(T, len);
            errdefer allocator.free(buf);

            return .{
                .allocator = allocator,
                .min_len = self.min_len,
                .trees = trees,
                .live = live,
                .buf = buf,
                .live_len = len,
                .shrink_step = .removing,
                .removal_idx = 0,
                .last_removal_idx = null,
                .elem_idx = 0,
            };
        }
    };
}

pub fn SliceTree(comptime T: type, comptime ElemTree: type) type {
    return struct {
        const Self = @This();
        pub const Value = []const T;

        const Step = enum { removing, shrinking_elements, done };

        allocator: Allocator,
        min_len: usize,
        // Per-element trees. Length is fixed; `live` tracks which elements
        // belong to the current slice.
        trees: []ElemTree,
        live: []bool,
        // Reusable scratch buffer for materialising the current slice.
        buf: []T,
        live_len: usize,

        shrink_step: Step,
        // Index into `trees` (not into the materialised slice) we're trying
        // to remove next.
        removal_idx: usize,
        // Last successfully proposed removal, in case we need to undo it.
        last_removal_idx: ?usize,
        // Element index (in `trees`) we're shrinking during the second pass.
        elem_idx: usize,

        pub fn current(self: *Self) []const T {
            var w: usize = 0;
            for (self.trees, self.live) |*tree, on| {
                if (!on) continue;
                self.buf[w] = tree.current();
                w += 1;
            }
            return self.buf[0..w];
        }

        pub fn simplify(self: *Self) bool {
            switch (self.shrink_step) {
                .removing => {
                    while (self.removal_idx < self.trees.len) {
                        if (!self.live[self.removal_idx]) {
                            self.removal_idx += 1;
                            continue;
                        }
                        if (self.live_len <= self.min_len) {
                            // Done removing; move to per-element shrinking.
                            self.shrink_step = .shrinking_elements;
                            return self.simplify();
                        }
                        self.live[self.removal_idx] = false;
                        self.live_len -= 1;
                        self.last_removal_idx = self.removal_idx;
                        self.removal_idx += 1;
                        return true;
                    }
                    self.shrink_step = .shrinking_elements;
                    return self.simplify();
                },
                .shrinking_elements => {
                    while (self.elem_idx < self.trees.len) {
                        if (!self.live[self.elem_idx]) {
                            self.elem_idx += 1;
                            continue;
                        }
                        if (self.trees[self.elem_idx].simplify()) {
                            return true;
                        }
                        self.elem_idx += 1;
                    }
                    self.shrink_step = .done;
                    return false;
                },
                .done => return false,
            }
        }

        pub fn complicate(self: *Self) bool {
            switch (self.shrink_step) {
                .removing => {
                    if (self.last_removal_idx) |idx| {
                        self.live[idx] = true;
                        self.live_len += 1;
                        self.last_removal_idx = null;
                        return true;
                    }
                    return false;
                },
                .shrinking_elements => {
                    if (self.elem_idx < self.trees.len and self.live[self.elem_idx]) {
                        return self.trees[self.elem_idx].complicate();
                    }
                    return false;
                },
                .done => return false,
            }
        }

        pub fn deinit(self: *Self) void {
            if (@hasDecl(ElemTree, "deinit")) {
                for (self.trees) |*t| t.deinit();
            }
            self.allocator.free(self.trees);
            self.allocator.free(self.live);
            self.allocator.free(self.buf);
        }
    };
}

//
// Bytes (alias for `slice` over the full u8 range)
//

pub fn bytes(min_len: usize, max_len: usize) Slice(num.IntInRange(u8)) {
    return slice(num.intInRange(u8, 0, 255), min_len, max_len);
}

//
// ASCII string
//
// Bytes restricted to printable ASCII (`0x20..0x7E`). Returned as `[]const u8`.
//

pub fn asciiString(min_len: usize, max_len: usize) Slice(num.IntInRange(u8)) {
    return slice(num.intInRange(u8, 0x20, 0x7E), min_len, max_len);
}

//
// Unit Tests
//

const testing = std.testing;

test "slice produces a length within bounds" {
    var r = runner.Runner.initFromSeed(.{}, 1);
    const s = slice(num.intInRange(i32, 0, 9), 2, 5);
    var t = try s.newTree(&r, testing.allocator);
    defer t.deinit();
    const v = t.current();
    try testing.expect(v.len >= 2 and v.len <= 5);
}

test "slice shrinks length toward min" {
    var r = runner.Runner.initFromSeed(.{}, 7);
    const s = slice(num.intInRange(i32, 0, 9), 0, 8);
    var t = try s.newTree(&r, testing.allocator);
    defer t.deinit();

    const initial_len = t.current().len;
    var iters: u32 = 0;
    while (iters < 64 and t.simplify()) : (iters += 1) {}
    try testing.expect(t.current().len <= initial_len);
}

test "slice cleans up after a mid-construction element-strategy failure" {
    // Use a Filter that always rejects so the slice's element loop fails
    // partway through. The testing allocator would flag a leak (or UB on
    // double-free of uninitialised trees) if cleanup is wrong.
    const alwaysReject = struct {
        fn f(_: i32) bool {
            return false;
        }
    }.f;
    const restrictive = @import("strategy.zig").filter(num.intInRange(i32, 0, 9), alwaysReject);
    var r = runner.Runner.initFromSeed(.{ .max_filter_rejections = 4 }, 13);
    const s = slice(restrictive, 3, 5);
    const result = s.newTree(&r, testing.allocator);
    try testing.expectError(error.FilterTooRestrictive, result);
}

test "asciiString stays within printable ASCII" {
    var r = runner.Runner.initFromSeed(.{}, 11);
    var t = try asciiString(0, 64).newTree(&r, testing.allocator);
    defer t.deinit();
    for (t.current()) |b| {
        try testing.expect(b >= 0x20 and b <= 0x7E);
    }
}
