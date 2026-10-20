/// Clamp a value.
pub fn clamp(value: u32, low: u32, high: u32) u32 {
    return @min(@max(value, low), high);
}
