//! The docgen library: turn a Zig source tree into static HTML.

pub const generate = @import("generate.zig").generate;
pub const Options = @import("generate.zig").Options;
pub const Result = @import("generate.zig").Result;

test {
    _ = @import("generate.zig");
}
