//! Tiny fixture package.
//!
//! It exercises the reader.
//!
//! ## Layout
//!
//! The modules live beside this file.

const maybe_mod = @import("maybe.zig");

/// A point in the plane.
pub const Point = struct {
    /// Horizontal coordinate.
    x: f64,

    /// Vertical coordinate.
    y: f64,

    /// Distance from the origin.
    pub fn magnitude(self: Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
};

/// A color.
pub const Color = enum {
    red,
    green,
};

/// A fixed-length array.
pub fn Array(comptime len: usize) type {
    return struct {
        /// The bytes.
        data: [len]u8,

        /// An empty array.
        pub fn empty() @This() {
            return .{ .data = [_]u8{0} ** len };
        }
    };
}

pub const internal = @import("internal.zig");

pub const maybe = if (true) maybe_mod else void;
