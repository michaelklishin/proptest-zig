# proptest-zig

A small, Hypothesis-style property-based testing library for Zig with
integrated binary-search shrinking.

Ported from [Rust `proptest`](https://github.com/proptest-rs/proptest)
and inspired by [Hypothesis](https://hypothesis.readthedocs.io/) (Python)
and [Hedgehog](https://hedgehog.qa/).


## Before We Start

Most unit tests pick a few example inputs and assert what each should do.
A property-based test instead states a rule that should always hold, and
the framework throws hundreds of random inputs at it looking for one that
breaks the rule.

When the rule breaks, the random input that triggered it is usually big
and messy. The library then *shrinks* it down to the minimal
counterexample that still fails, so you debug `{ 0, 0 }` instead of a
wall of noise.

You describe inputs with typed generators (called **strategies**), write
the rule as a Zig function, and the runner does the rest.


## Project Maturity

This is a very young project. Breaking API changes are likely before `1.0`.


## Target Zig Version

 * Zig 0.16.0 or later


## Installation

Fetch the latest release into your `build.zig.zon`:

```bash
zig fetch --save=proptest https://github.com/michaelklishin/proptest-zig/archive/refs/tags/v0.5.0.tar.gz
```

This adds an entry like:

```zig
.dependencies = .{
    .proptest = .{
        .url = "https://github.com/michaelklishin/proptest-zig/archive/refs/tags/v0.5.0.tar.gz",
        .hash = "proptest-0.5.0-_GA2m_WOAQCxB73yCtolGqKufs39NkNg6TJlJHdtZqu0",
    },
},
```

Then in your `build.zig`:

```zig
const proptest_dep = b.dependency("proptest", .{
    .target = target,
    .optimize = optimize,
});
test_module.addImport("proptest", proptest_dep.module("proptest"));
```


## Quick Start

```zig
const std = @import("std");
const pt = @import("proptest");

test "addition is commutative" {
    var runner = pt.Runner.initDefault();
    defer runner.deinit();

    const ints = pt.num.intInRange(i32, -1000, 1000);
    const pair = pt.tuple.t2(ints, ints);

    try runner.check(std.testing.allocator, pair, struct {
        fn run(p: struct { i32, i32 }) !void {
            if (p[0] + p[1] != p[1] + p[0]) return error.NotCommutative;
        }
    }.run);
}
```

When the property fails, the runner shrinks the failing case to a local
minimum and logs both the initial and shrunk counterexample together with
the seed needed to reproduce.


## Strategies

A **strategy** describes how to generate values of a given type. Each
strategy carries a value tree that supports binary-search shrinking via
`current()`, `simplify()`, `complicate()`, and an optional `deinit()`.

### Numeric

```zig
// Inclusive integer range, shrinks toward zero (or `lo` when zero is out of range)
const small = pt.num.intInRange(i32, -50, 50);

// Full type range
const any_u32 = pt.num.int(u32);

// Float range. `pt.num.float(T)` defaults to [-1e6, +1e6] to avoid
// routine overflow into infinity in user predicates.
const positive_floats = pt.num.floatInRange(f64, 0.0, 1e9);
```

### Booleans

```zig
const fair = pt.boolean();        // 50/50
const biased = pt.weightedBoolean(0.9);   // true ~90% of the time
```

### Constants

```zig
const always_42 = pt.just(@as(u32, 42));
```

### Slices, Bytes, ASCII Strings

```zig
const ints = pt.collection.slice(pt.num.intInRange(i32, 0, 9), 0, 16);
const blob = pt.collection.bytes(0, 256);
const name = pt.collection.asciiString(1, 32);
```

Slice shrinking removes elements down to `min_len` first, then shrinks
each surviving element.


## Combinators

### `map`: transform values

```zig
fn doubleI32(x: i32) i32 { return x * 2; }

const evens = pt.map(pt.num.intInRange(i32, 0, 100), i32, doubleI32);
```

The inner value tree continues to shrink in its own value space; the
mapping function is applied on every read.

### `filter`: accept or reject values

```zig
fn isOdd(x: i32) bool { return @rem(x, 2) != 0; }

const odd = pt.filter(pt.num.intInRange(i32, 0, 100), isOdd);
```

If the predicate rejects too many values in a row, `newTree` returns
`error.FilterTooRestrictive`. The threshold is configurable via
`Config.max_filter_rejections` (default `65536`).

### `oneOf`: weighted union

```zig
const flag_or_value = pt.oneOf(i32, .{
    .{ @as(u32, 9), pt.just(@as(i32, 0)) },
    .{ @as(u32, 1), pt.num.intInRange(i32, 1, 100) },
});
```

Weights must be unsigned integers (compile-time enforced). All branches
must produce the same `Value` type. `oneOf` does not switch branches
during shrinking; the chosen branch shrinks within itself.

### Tuples

```zig
const pair = pt.tuple.t2(pt.num.intInRange(i32, 0, 10), pt.boolean());
const triple = pt.tuple.t3(strategy_a, strategy_b, strategy_c);
const quad = pt.tuple.t4(strategy_a, strategy_b, strategy_c, strategy_d);
```

Components shrink left-to-right.


## Configuring the Runner

```zig
var runner = pt.Runner.initFromSeed(.{
    .cases = 1024,            // how many random inputs to try
    .max_shrink_iters = 8192, // shrink budget
    .max_filter_rejections = 1024,
    .log_failures = true,     // print to stderr on failure
}, 0xdeadbeef);
```

`Runner.initFromSeed` is hermetic and ignores environment variables.
`Runner.initFromEnvOrEntropy(config)` reads `PROPTEST_SEED`,
`PROPTEST_CASES`, and `PROPTEST_MAX_SHRINK_ITERS` from the environment;
unset values fall back to `config`. `Runner.initDefault()` is a shorthand
for the env/entropy path with default config.


## Inspecting the Counterexample

After `check` returns `error.PropertyFailed`, the most recent shrunk
counterexample is available as a formatted string:

```zig
const result = runner.check(allocator, strategy, predicate);
try std.testing.expectError(error.PropertyFailed, result);
std.debug.print("minimal failing input: {s}\n", .{runner.lastFailing()});
```

The string is reset on every `check` call, so a passing run leaves
`lastFailing()` empty.


## Reproducing a Failure

Failed runs print the seed that produced the counterexample:

```
property failed at case 17 after 12 shrinks: NotCommutative
  shrunk counterexample: { -1, 1 }
  initial counterexample: { -847, 23 } (NotCommutative)
  reproduce with PROPTEST_SEED=12345
```

Re-run with the same seed to get the same sequence:

```bash
PROPTEST_SEED=12345 zig build test
```


## Environment Variables

| Variable | Effect |
|---|---|
| `PROPTEST_SEED` | Override the runner's RNG seed |
| `PROPTEST_CASES` | Override `Config.cases` |
| `PROPTEST_MAX_SHRINK_ITERS` | Override `Config.max_shrink_iters` (set to `0` to disable shrinking) |

Variables are read by `Runner.initDefault` and
`Runner.initFromEnvOrEntropy`. `Runner.initFromSeed` ignores them.


## Writing Custom Strategies

Strategies and value trees are duck-typed via comptime: any value with the
right declarations works. Every strategy provides:

```zig
pub const Value: type;
pub const Tree:  type;
pub fn newTree(self, runner: *pt.Runner, allocator: std.mem.Allocator) !Tree;
```

Every value tree provides:

```zig
pub const Value: type;
pub fn current(self: *Self) Value;
pub fn simplify(self: *Self) bool;
pub fn complicate(self: *Self) bool;
pub fn deinit(self: *Self) void;   // optional
```

`simplify` returns true if it produced a smaller candidate; `complicate`
walks back when the runner determines the simplification went too far.
The runner tests `current()` after every transform.


## Building and Testing

```bash
# Install Zig
brew install zig

# Build
zig build

# Run the full test suite (no external dependencies)
zig build test

# Generate documentation
zig build docs
```

Tests are split between in-file `test "..."` blocks and integration tests
under `tests/`. The meta-tests in `tests/meta_test.zig` use proptest-zig
itself to test its own primitives.


## License

Dual-licensed under Apache License 2.0 and MIT, matching upstream Rust
`proptest`. See [LICENSE-APACHE](LICENSE-APACHE) and
[LICENSE-MIT](LICENSE-MIT).


## Copyright

(c) 2025-2026 Michael S. Klishin and Contributors.
