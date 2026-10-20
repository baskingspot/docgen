//! Function value fixtures.

const util = @import("util.zig");

/// A function value from another module.
pub const clamp = util.clamp;
/// A function value from this module.
pub const twice = twiceImpl;

fn twiceImpl(value: u32) u32 {
    return value * 2;
}
