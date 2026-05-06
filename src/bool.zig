const std = @import("std");
const runner = @import("runner.zig");
const Allocator = std.mem.Allocator;

//
// Boolean strategies
//

pub fn boolean() Bool {
    return .{ .p = 0.5 };
}

pub fn weightedBoolean(p: f64) Bool {
    std.debug.assert(p >= 0.0 and p <= 1.0);
    return .{ .p = p };
}

pub const Bool = struct {
    p: f64,

    pub const Value = bool;
    pub const Tree = BoolTree;

    pub fn newTree(self: Bool, ctx: *runner.Runner, allocator: Allocator) !Tree {
        _ = allocator;
        const r = ctx.random();
        const value = r.float(f64) < self.p;
        return Tree.init(value);
    }
};

/// Bools shrink toward `false` since it is the default and usually the
/// "less interesting" value.
pub const BoolTree = struct {
    pub const Value = bool;

    cur: bool,
    started: bool,

    pub fn init(value: bool) BoolTree {
        return .{ .cur = value, .started = false };
    }

    pub fn current(self: *BoolTree) bool {
        return self.cur;
    }

    pub fn simplify(self: *BoolTree) bool {
        if (self.started) return false;
        self.started = true;
        if (!self.cur) return false;
        self.cur = false;
        return true;
    }

    pub fn complicate(self: *BoolTree) bool {
        if (!self.started) return false;
        if (self.cur) return false;
        self.cur = true;
        return true;
    }
};

//
// Unit Tests
//

const testing = std.testing;

test "BoolTree shrinks true to false in one step" {
    var t = BoolTree.init(true);
    try testing.expect(t.current());
    try testing.expect(t.simplify());
    try testing.expect(!t.current());
    try testing.expect(!t.simplify());
}

test "BoolTree never shrinks false further" {
    var t = BoolTree.init(false);
    try testing.expect(!t.simplify());
}

test "BoolTree complicate undoes one simplify" {
    var t = BoolTree.init(true);
    _ = t.simplify();
    try testing.expect(t.complicate());
    try testing.expect(t.current());
}
