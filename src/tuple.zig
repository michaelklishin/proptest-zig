const std = @import("std");
const runner = @import("runner.zig");
const Allocator = std.mem.Allocator;

//
// Heterogeneous tuple combinators (2 to 4 elements).
//
// All sub-strategies run in parallel; each component shrinks independently.
// Shrinking proceeds component-by-component left-to-right, mirroring how
// Rust proptest handles `(A, B, C)` strategies.
//

pub fn t2(a: anytype, b: anytype) Tuple2(@TypeOf(a), @TypeOf(b)) {
    return .{ .a = a, .b = b };
}

pub fn t3(a: anytype, b: anytype, c: anytype) Tuple3(@TypeOf(a), @TypeOf(b), @TypeOf(c)) {
    return .{ .a = a, .b = b, .c = c };
}

pub fn t4(a: anytype, b: anytype, c: anytype, d: anytype) Tuple4(@TypeOf(a), @TypeOf(b), @TypeOf(c), @TypeOf(d)) {
    return .{ .a = a, .b = b, .c = c, .d = d };
}

pub fn Tuple2(comptime A: type, comptime B: type) type {
    return struct {
        a: A,
        b: B,

        const Self = @This();
        pub const Value = struct { A.Value, B.Value };
        pub const Tree = Tuple2Tree(A.Tree, B.Tree);

        pub fn newTree(self: Self, ctx: *runner.Runner, allocator: Allocator) !Tree {
            var a = try self.a.newTree(ctx, allocator);
            errdefer if (@hasDecl(A.Tree, "deinit")) a.deinit();
            const b = try self.b.newTree(ctx, allocator);
            return .{ .a = a, .b = b, .step = 0 };
        }
    };
}

pub fn Tuple2Tree(comptime A: type, comptime B: type) type {
    return struct {
        a: A,
        b: B,
        // Component currently being shrunk (0 -> a, 1 -> b, 2 -> done).
        step: u8,

        const Self = @This();
        pub const Value = struct { A.Value, B.Value };

        pub fn current(self: *Self) Value {
            return .{ self.a.current(), self.b.current() };
        }
        pub fn simplify(self: *Self) bool {
            while (self.step < 2) {
                const ok = switch (self.step) {
                    0 => self.a.simplify(),
                    1 => self.b.simplify(),
                    else => unreachable,
                };
                if (ok) return true;
                self.step += 1;
            }
            return false;
        }
        pub fn complicate(self: *Self) bool {
            return switch (self.step) {
                0 => self.a.complicate(),
                1 => self.b.complicate(),
                else => false,
            };
        }
        pub fn deinit(self: *Self) void {
            if (@hasDecl(A, "deinit")) self.a.deinit();
            if (@hasDecl(B, "deinit")) self.b.deinit();
        }
    };
}

pub fn Tuple3(comptime A: type, comptime B: type, comptime C: type) type {
    return struct {
        a: A,
        b: B,
        c: C,

        const Self = @This();
        pub const Value = struct { A.Value, B.Value, C.Value };
        pub const Tree = Tuple3Tree(A.Tree, B.Tree, C.Tree);

        pub fn newTree(self: Self, ctx: *runner.Runner, allocator: Allocator) !Tree {
            var a = try self.a.newTree(ctx, allocator);
            errdefer if (@hasDecl(A.Tree, "deinit")) a.deinit();
            var b = try self.b.newTree(ctx, allocator);
            errdefer if (@hasDecl(B.Tree, "deinit")) b.deinit();
            const c = try self.c.newTree(ctx, allocator);
            return .{ .a = a, .b = b, .c = c, .step = 0 };
        }
    };
}

pub fn Tuple3Tree(comptime A: type, comptime B: type, comptime C: type) type {
    return struct {
        a: A,
        b: B,
        c: C,
        step: u8,

        const Self = @This();
        pub const Value = struct { A.Value, B.Value, C.Value };

        pub fn current(self: *Self) Value {
            return .{ self.a.current(), self.b.current(), self.c.current() };
        }
        pub fn simplify(self: *Self) bool {
            while (self.step < 3) {
                const ok = switch (self.step) {
                    0 => self.a.simplify(),
                    1 => self.b.simplify(),
                    2 => self.c.simplify(),
                    else => unreachable,
                };
                if (ok) return true;
                self.step += 1;
            }
            return false;
        }
        pub fn complicate(self: *Self) bool {
            return switch (self.step) {
                0 => self.a.complicate(),
                1 => self.b.complicate(),
                2 => self.c.complicate(),
                else => false,
            };
        }
        pub fn deinit(self: *Self) void {
            if (@hasDecl(A, "deinit")) self.a.deinit();
            if (@hasDecl(B, "deinit")) self.b.deinit();
            if (@hasDecl(C, "deinit")) self.c.deinit();
        }
    };
}

pub fn Tuple4(comptime A: type, comptime B: type, comptime C: type, comptime D: type) type {
    return struct {
        a: A,
        b: B,
        c: C,
        d: D,

        const Self = @This();
        pub const Value = struct { A.Value, B.Value, C.Value, D.Value };
        pub const Tree = Tuple4Tree(A.Tree, B.Tree, C.Tree, D.Tree);

        pub fn newTree(self: Self, ctx: *runner.Runner, allocator: Allocator) !Tree {
            var a = try self.a.newTree(ctx, allocator);
            errdefer if (@hasDecl(A.Tree, "deinit")) a.deinit();
            var b = try self.b.newTree(ctx, allocator);
            errdefer if (@hasDecl(B.Tree, "deinit")) b.deinit();
            var c = try self.c.newTree(ctx, allocator);
            errdefer if (@hasDecl(C.Tree, "deinit")) c.deinit();
            const d = try self.d.newTree(ctx, allocator);
            return .{ .a = a, .b = b, .c = c, .d = d, .step = 0 };
        }
    };
}

pub fn Tuple4Tree(comptime A: type, comptime B: type, comptime C: type, comptime D: type) type {
    return struct {
        a: A,
        b: B,
        c: C,
        d: D,
        step: u8,

        const Self = @This();
        pub const Value = struct { A.Value, B.Value, C.Value, D.Value };

        pub fn current(self: *Self) Value {
            return .{ self.a.current(), self.b.current(), self.c.current(), self.d.current() };
        }
        pub fn simplify(self: *Self) bool {
            while (self.step < 4) {
                const ok = switch (self.step) {
                    0 => self.a.simplify(),
                    1 => self.b.simplify(),
                    2 => self.c.simplify(),
                    3 => self.d.simplify(),
                    else => unreachable,
                };
                if (ok) return true;
                self.step += 1;
            }
            return false;
        }
        pub fn complicate(self: *Self) bool {
            return switch (self.step) {
                0 => self.a.complicate(),
                1 => self.b.complicate(),
                2 => self.c.complicate(),
                3 => self.d.complicate(),
                else => false,
            };
        }
        pub fn deinit(self: *Self) void {
            if (@hasDecl(A, "deinit")) self.a.deinit();
            if (@hasDecl(B, "deinit")) self.b.deinit();
            if (@hasDecl(C, "deinit")) self.c.deinit();
            if (@hasDecl(D, "deinit")) self.d.deinit();
        }
    };
}
