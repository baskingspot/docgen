//! The docgen library: read a Zig source tree into a public document model,
//! then render it as HTML or JSON.

pub const model = @import("model.zig");

pub const Document = model.Document;
pub const GeneratorInfo = model.GeneratorInfo;
pub const Package = model.Package;
pub const Symbol = model.Symbol;
pub const Kind = model.Kind;
pub const Severity = model.Severity;
pub const Diagnostic = model.Diagnostic;
pub const Format = model.Format;
pub const ExtractOptions = model.ExtractOptions;
pub const writeJson = model.writeJson;

pub const generate = @import("generate.zig").generate;
pub const extract = @import("generate.zig").extract;
pub const renderHtml = @import("generate.zig").renderHtml;
pub const Options = @import("generate.zig").Options;
pub const Result = @import("generate.zig").Result;

test {
    _ = model;
    _ = @import("generate.zig");
}
