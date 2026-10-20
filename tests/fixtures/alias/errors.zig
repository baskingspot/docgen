/// A parse error.
pub const ParseError = error{
    UnexpectedEof,
    InvalidLength,
};
