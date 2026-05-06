/// proptest-zig: a small Hypothesis-style property-based testing library
/// with integrated binary-search shrinking.
///
/// Two contracts make the whole thing work, and they are duck-typed via
/// comptime:
///
///   * **Strategy**: any value with the declarations
///         pub const Value: type
///         pub const Tree:  type
///         pub fn newTree(self, runner: *Runner, allocator: Allocator) !Tree
///
///   * **Value tree**: any value with the declarations
///         pub const Value: type
///         pub fn current(self) Value
///         pub fn simplify(self) bool
///         pub fn complicate(self) bool
///         pub fn deinit(self) void   // optional
///
/// Build a strategy with the helpers in `num`, `boolean`, `tuple`,
/// `collection`, etc., then drive it with `Runner.check`.
pub const runner_mod = @import("runner.zig");
pub const Runner = runner_mod.Runner;
pub const Config = runner_mod.Config;

pub const num = @import("num.zig");
pub const collection = @import("collection.zig");
pub const tuple = @import("tuple.zig");

const bool_mod = @import("bool.zig");
pub const boolean = bool_mod.boolean;
pub const weightedBoolean = bool_mod.weightedBoolean;

const strategy = @import("strategy.zig");
pub const just = strategy.just;
pub const map = strategy.map;
pub const filter = strategy.filter;
pub const oneOf = strategy.oneOf;

pub const Just = strategy.Just;
pub const Map = strategy.Map;
pub const Filter = strategy.Filter;
pub const OneOf = strategy.OneOf;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
