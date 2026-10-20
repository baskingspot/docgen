//! A widget module.

/// A widget.
pub const Widget = struct {
    /// Identifier.
    id: u32,

    /// Make one.
    pub fn init(id: u32) Widget {
        return .{ .id = id };
    }
};
