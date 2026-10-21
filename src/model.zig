//! The public, style-free document model.
//!
//! Everything in this file is extracted data: raw doc comments, source
//! signatures, and source locations. Renderers (HTML) and serializers (JSON)
//! consume the model and do not influence it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Name of the tool recorded in `Document.generator`.
pub const generator_name = "docgen";
/// Mirrors `.version` in `build.zig.zon`.
pub const generator_version = "0.0.0";

pub const Format = enum {
    html,
    json,

    /// File the format is written to inside the output directory.
    pub fn fileName(format: Format) []const u8 {
        return switch (format) {
            .html => "index.html",
            .json => "api.json",
        };
    }
};

/// What a symbol is. The JSON names are the tag names, so `@"struct"`
/// serializes as `"struct"`.
pub const Kind = enum {
    function,
    constant,
    variable,
    module,
    @"struct",
    @"enum",
    @"union",
    @"opaque",
    type_function,
    field,

    /// Short human label used by the HTML renderer.
    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .function => "fn",
            .constant => "const",
            .variable => "var",
            .module => "module",
            .@"struct" => "struct",
            .@"enum" => "enum",
            .@"union" => "union",
            .@"opaque" => "opaque",
            .type_function => "type fn",
            .field => "field",
        };
    }
};

pub const Severity = enum {
    warning,
    @"error",
};

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    file: []const u8,
    line: usize,
};

pub const GeneratorInfo = struct {
    name: []const u8,
    version: []const u8,
};

pub const Package = struct {
    /// Human name, for example `stdx`.
    name: []const u8,
    /// Root source file, as passed to `extract`.
    root: []const u8,
    /// For example `https://github.com/baskingspot/stdx`.
    repo_url: []const u8,
    /// Commit or branch the source locations refer to.
    rev: []const u8,
};

pub const Symbol = struct {
    name: []const u8,
    /// Fully qualified name, for example `mem.Array`.
    fqn: []const u8,
    kind: Kind,
    /// Nesting level; 0 for a top-level declaration.
    depth: usize,
    /// The parent's `fqn`, or null at the top level.
    parent: ?[]const u8,
    /// Source text, preserving the source's line breaks and indentation.
    signature: []const u8,
    /// Raw doc comment markdown, without the `///` markers.
    docs: []const u8,
    file: []const u8,
    line: usize,
};

pub const Document = struct {
    schema_version: u32 = 1,
    generator: GeneratorInfo,
    package: Package,
    /// Raw `//!` markdown from the root source file.
    module_docs: []const u8,
    /// Every symbol in document order: pre-order, parents before children.
    /// Use `depth` and `parent` to rebuild the tree.
    symbols: []const Symbol,
    diagnostics: []const Diagnostic,
};

pub const ExtractOptions = struct {
    /// Root source file of the package, relative to the current directory.
    root_path: []const u8,
    /// Package name, for example `stdx`.
    name: []const u8,
    /// For example `https://github.com/baskingspot/stdx`.
    repo_url: []const u8 = "",
    /// Commit or branch recorded in the document.
    rev: []const u8 = "main",
};

/// Serialize a document as JSON schema v1. Caller owns the returned bytes.
pub fn writeJson(allocator: Allocator, document: *const Document) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, document.*, .{
        .whitespace = .indent_2,
    });
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}
