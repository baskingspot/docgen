//! Constant signature fixtures.

/// A port with an explicit type.
pub const default_port: u16 = 8080;
/// An inferred integer.
pub const DefaultPort = 8080;
/// A callback type.
pub const Handler = *const fn () void;
/// An error set.
pub const ParseError = error{
    UnexpectedEof,
    InvalidLength,
};
/// A call initializer.
pub const Clamped = @min(300, max_port);
/// A forward value.
pub const max_port = 1024;

/// A mutable counter.
pub var counter: u32 = 0;

/// A package import.
pub const std_pkg = @import("std");
