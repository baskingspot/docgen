//! Local alias fixtures.

const helpers = @import("helpers.zig");
const fmt_mod = @import("fmt.zig");
const values = @import("values.zig");
const errors = @import("errors.zig");

/// A forwarded widget.
pub const Widget = helpers.Widget;
/// A forwarded nested type.
pub const Deep = helpers.Sub;
/// Forward reference to a local container.
pub const Forward = Later;
/// A function value.
pub const atoi = fmt_mod.atoi;
/// A same-file function value.
pub const isOption = isOptionImpl;
/// A value alias.
pub const empty = values.empty;
/// An error alias.
pub const ParseError = errors.ParseError;

/// A later local container.
pub const Later = struct {
    /// A flag.
    flag: bool,
};

fn isOptionImpl(arg: []const u8) bool {
    return arg.len != 0 and arg[0] == '-';
}
