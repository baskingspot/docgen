//! Tagged union fixtures.

/// A two-variant tagged union.
pub const Two = union(enum) {
    /// A number.
    number: u32,
    /// A name.
    name: []const u8,
};

/// A byte-tagged union.
pub const ByTag = union(enum(u8)) {
    a: u8,
    b: u8,
};

/// A plain union.
pub const Plain = union {
    int: i32,
    float: f32,
};

/// A container with a nested tagged union.
pub const Ops = struct {
    pub const Variant = union(enum) {
        one: void,
        two: void,
    };
};

/// A backed enum.
pub const Kind = enum(u16) {
    small,
    large,
};
