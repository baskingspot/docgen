//! Type function fixtures.

/// A sized buffer.
pub fn Alloc(comptime n: usize) type {
    return struct {
        /// Length.
        len: usize,
    };
}

/// A buffer through a call.
pub fn Buffer(comptime n: usize) type {
    return Alloc(n);
}

/// A named container.
pub fn Named(comptime T: type) type {
    return Item;
}

/// A conditional container.
pub fn Conditional(comptime flag: bool) type {
    return if (flag) Item else Other;
}

/// A switched container.
pub fn Switched(comptime value: u8) type {
    return switch (value) {
        0 => Item,
        else => Other,
    };
}

/// A nested block.
pub fn Nested(comptime n: usize) type {
    return blk: {
        return struct {
            /// Nested field.
            count: usize,
        };
    };
}

/// A type function we cannot expand.
pub fn Unresolved(comptime x: usize) type {
    return @TypeOf(x);
}

/// The item.
pub const Item = struct {
    /// Identifier.
    id: u32,
};

/// Another item.
pub const Other = struct {
    /// Name.
    name: []const u8,
};
