const std = @import("std");
const runner = @import("runner.zig");
const Allocator = std.mem.Allocator;

//
// Just: a strategy that always produces the same value.
//

pub fn just(value: anytype) Just(@TypeOf(value)) {
    const T = @TypeOf(value);
    comptime {
        const info = @typeInfo(T);
        if (info == .comptime_int or info == .comptime_float) {
            @compileError("just: pass a runtime-typed value, e.g. `just(@as(i32, " ++ "..))` " ++
                "instead of `just(literal)`. Untyped numeric literals can't be stored at runtime.");
        }
    }
    return .{ .value = value };
}

pub fn Just(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();
        pub const Value = T;
        pub const Tree = JustTree(T);

        pub fn newTree(self: Self, ctx: *runner.Runner, allocator: Allocator) !Tree {
            _ = ctx;
            _ = allocator;
            return .{ .value = self.value };
        }
    };
}

pub fn JustTree(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();
        pub const Value = T;

        pub fn current(self: *Self) T {
            return self.value;
        }
        pub fn simplify(_: *Self) bool {
            return false;
        }
        pub fn complicate(_: *Self) bool {
            return false;
        }
    };
}

//
// Map: transform values produced by an inner strategy.
//
// The inner tree continues to shrink in its own value space; the mapping
// function is called on every read.
//

pub fn map(strategy: anytype, comptime Out: type, f: *const fn (@TypeOf(strategy).Value) Out) Map(@TypeOf(strategy), @TypeOf(strategy).Value, Out) {
    return .{ .source = strategy, .f = f };
}

pub fn Map(comptime S: type, comptime In: type, comptime Out: type) type {
    return struct {
        source: S,
        f: *const fn (In) Out,

        const Self = @This();
        pub const Value = Out;
        pub const Tree = MapTree(S.Tree, In, Out);

        pub fn newTree(self: Self, ctx: *runner.Runner, allocator: Allocator) !Tree {
            const inner = try self.source.newTree(ctx, allocator);
            return .{ .inner = inner, .f = self.f };
        }
    };
}

pub fn MapTree(comptime InnerTree: type, comptime In: type, comptime Out: type) type {
    return struct {
        inner: InnerTree,
        f: *const fn (In) Out,

        const Self = @This();
        pub const Value = Out;

        pub fn current(self: *Self) Out {
            return self.f(self.inner.current());
        }
        pub fn simplify(self: *Self) bool {
            return self.inner.simplify();
        }
        pub fn complicate(self: *Self) bool {
            return self.inner.complicate();
        }
        pub fn deinit(self: *Self) void {
            if (@hasDecl(InnerTree, "deinit")) self.inner.deinit();
        }
    };
}

//
// Filter: only emit values that satisfy a predicate.
//
// Resamples the inner strategy until the predicate accepts; bails after
// `max_filter_rejections` consecutive rejections to avoid infinite loops.
//

pub fn filter(strategy: anytype, predicate: *const fn (@TypeOf(strategy).Value) bool) Filter(@TypeOf(strategy), @TypeOf(strategy).Value) {
    return .{ .source = strategy, .predicate = predicate };
}

pub fn Filter(comptime S: type, comptime V: type) type {
    return struct {
        source: S,
        predicate: *const fn (V) bool,

        const Self = @This();
        pub const Value = V;
        pub const Tree = FilterTree(S.Tree, V);

        pub fn newTree(self: Self, ctx: *runner.Runner, allocator: Allocator) !Tree {
            var attempts: u32 = 0;
            while (attempts < ctx.config.max_filter_rejections) : (attempts += 1) {
                var t = try self.source.newTree(ctx, allocator);
                if (self.predicate(t.current())) {
                    return .{ .inner = t, .predicate = self.predicate };
                }
                if (@hasDecl(@TypeOf(t), "deinit")) t.deinit();
            }
            return error.FilterTooRestrictive;
        }
    };
}

pub fn FilterTree(comptime InnerTree: type, comptime V: type) type {
    return struct {
        inner: InnerTree,
        predicate: *const fn (V) bool,

        const Self = @This();
        pub const Value = V;

        pub fn current(self: *Self) V {
            return self.inner.current();
        }
        pub fn simplify(self: *Self) bool {
            while (self.inner.simplify()) {
                if (self.predicate(self.inner.current())) return true;
                // The simplification produced a rejected value; walk back via
                // complicate and try the next simplification step.
                if (!self.inner.complicate()) return false;
            }
            return false;
        }
        pub fn complicate(self: *Self) bool {
            while (self.inner.complicate()) {
                if (self.predicate(self.inner.current())) return true;
            }
            return false;
        }
        pub fn deinit(self: *Self) void {
            if (@hasDecl(InnerTree, "deinit")) self.inner.deinit();
        }
    };
}

//
// OneOf: pick one of N homogeneous-value strategies, weighted.
//
// All branches must produce the same value type. Shrinking shrinks within
// the chosen branch; we do *not* attempt to switch branches during shrink,
// matching Rust proptest's `Union::new` semantics for non-Box variants.
//

pub fn oneOf(comptime T: type, branches: anytype) OneOf(T, @TypeOf(branches)) {
    return .{ .branches = branches };
}

pub fn OneOf(comptime T: type, comptime Branches: type) type {
    const branches_info = @typeInfo(Branches);
    if (branches_info != .@"struct" or !branches_info.@"struct".is_tuple) {
        @compileError("oneOf branches must be a tuple of `.{ weight, strategy }` pairs");
    }
    const fields = branches_info.@"struct".fields;
    if (fields.len == 0) @compileError("oneOf needs at least one branch");
    inline for (fields, 0..) |f, idx| {
        const tuple_info = @typeInfo(f.type);
        if (tuple_info != .@"struct" or !tuple_info.@"struct".is_tuple or tuple_info.@"struct".fields.len != 2) {
            @compileError(std.fmt.comptimePrint(
                "oneOf branch {d} must be a `.{{ weight, strategy }}` 2-tuple",
                .{idx},
            ));
        }
        const WeightType = tuple_info.@"struct".fields[0].type;
        const w_info = @typeInfo(WeightType);
        const weight_ok = switch (w_info) {
            .int => |i| i.signedness == .unsigned,
            .comptime_int => true,
            else => false,
        };
        if (!weight_ok) {
            @compileError(std.fmt.comptimePrint(
                "oneOf branch {d}: weight must be an unsigned integer, got `{s}`",
                .{ idx, @typeName(WeightType) },
            ));
        }
        const StrategyType = tuple_info.@"struct".fields[1].type;
        if (!@hasDecl(StrategyType, "Value")) {
            @compileError(std.fmt.comptimePrint(
                "oneOf branch {d}: strategy type `{s}` has no `pub const Value`",
                .{ idx, @typeName(StrategyType) },
            ));
        }
        if (StrategyType.Value != T) {
            @compileError(std.fmt.comptimePrint(
                "oneOf branch {d}: strategy `{s}` produces `{s}` but oneOf was declared for `{s}`",
                .{ idx, @typeName(StrategyType), @typeName(StrategyType.Value), @typeName(T) },
            ));
        }
    }

    return struct {
        branches: Branches,

        const Self = @This();
        pub const Value = T;
        pub const Tree = OneOfTree(T, Branches);

        pub fn newTree(self: Self, ctx: *runner.Runner, allocator: Allocator) !Tree {
            // Weight type is comptime-checked above to be unsigned, so the
            // sum is non-negative by construction.
            var total_weight: f64 = 0;
            inline for (fields) |f| {
                const branch = @field(self.branches, f.name);
                const w: f64 = @floatFromInt(branch[0]);
                total_weight += w;
            }
            // All-zero weights would make every branch unreachable; bail
            // loudly rather than silently funnelling every pick to the last
            // branch, which is what naive `pick < w` comparison does.
            if (total_weight == 0) return error.OneOfAllZeroWeights;

            const r = ctx.random();
            var pick = r.float(f64) * total_weight;

            var chosen: Tree.Inner = undefined;
            inline for (fields, 0..) |f, idx| {
                const branch = @field(self.branches, f.name);
                const w: f64 = @floatFromInt(branch[0]);
                if (pick < w) {
                    const tree = try branch[1].newTree(ctx, allocator);
                    chosen = @unionInit(Tree.Inner, std.fmt.comptimePrint("v{d}", .{idx}), tree);
                    return .{ .inner = chosen };
                }
                pick -= w;
            }
            // Floating-point rounding fallthrough: use the last non-zero
            // branch (the last branch may itself have weight 0).
            const last_idx = lastNonZeroIndex(self.branches) orelse unreachable;
            inline for (fields, 0..) |f, idx| {
                if (idx == last_idx) {
                    const branch = @field(self.branches, f.name);
                    const tree = try branch[1].newTree(ctx, allocator);
                    chosen = @unionInit(Tree.Inner, std.fmt.comptimePrint("v{d}", .{idx}), tree);
                    return .{ .inner = chosen };
                }
            }
            unreachable;
        }

        fn lastNonZeroIndex(branches: Branches) ?usize {
            var found: ?usize = null;
            inline for (fields, 0..) |f, idx| {
                const branch = @field(branches, f.name);
                if (@as(f64, @floatFromInt(branch[0])) > 0) found = idx;
            }
            return found;
        }
    };
}

pub fn OneOfTree(comptime T: type, comptime Branches: type) type {
    const fields = @typeInfo(Branches).@"struct".fields;

    return struct {
        inner: Inner,

        const Self = @This();
        pub const Value = T;

        pub const Tag = blk: {
            var names: [fields.len][]const u8 = undefined;
            var values: [fields.len]u8 = undefined;
            for (fields, 0..) |_, idx| {
                names[idx] = std.fmt.comptimePrint("v{d}", .{idx});
                values[idx] = @intCast(idx);
            }
            break :blk @Enum(u8, .exhaustive, &names, &values);
        };

        pub const Inner = blk: {
            var names: [fields.len][]const u8 = undefined;
            var types: [fields.len]type = undefined;
            for (fields, 0..) |f, idx| {
                const tuple_fields = @typeInfo(f.type).@"struct".fields;
                const StrategyType = tuple_fields[1].type;
                names[idx] = std.fmt.comptimePrint("v{d}", .{idx});
                types[idx] = StrategyType.Tree;
            }
            break :blk @Union(.auto, Tag, &names, &types, &@as([fields.len]std.builtin.Type.UnionField.Attributes, @splat(.{})));
        };

        pub fn current(self: *Self) T {
            switch (self.inner) {
                inline else => |*inner_tree| return inner_tree.current(),
            }
        }
        pub fn simplify(self: *Self) bool {
            switch (self.inner) {
                inline else => |*inner_tree| return inner_tree.simplify(),
            }
        }
        pub fn complicate(self: *Self) bool {
            switch (self.inner) {
                inline else => |*inner_tree| return inner_tree.complicate(),
            }
        }
        pub fn deinit(self: *Self) void {
            switch (self.inner) {
                inline else => |*inner_tree| {
                    if (@hasDecl(@TypeOf(inner_tree.*), "deinit")) inner_tree.deinit();
                },
            }
        }
    };
}

//
// Unit Tests
//

const testing = std.testing;

test "JustTree never shrinks" {
    var t = JustTree(u32){ .value = 7 };
    try testing.expectEqual(@as(u32, 7), t.current());
    try testing.expect(!t.simplify());
    try testing.expect(!t.complicate());
}
