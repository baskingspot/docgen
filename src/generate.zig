//! Read a Zig package into the public document model, then render that model.
//!
//! This is deliberately an AST-only reader. It follows relative `@import`
//! paths, collects public declarations and their doc comments into
//! `model.Document`, and renders the document as one HTML page. It does not
//! resolve types, aliases, or the build graph.

const std = @import("std");
const model = @import("model.zig");
const Ast = std.zig.Ast;

const Allocator = std.mem.Allocator;

pub const Document = model.Document;
pub const Format = model.Format;
pub const Kind = model.Kind;
pub const ExtractOptions = model.ExtractOptions;
pub const writeJson = model.writeJson;

pub const Options = struct {
    /// Root source file of the package, relative to the current directory.
    root_path: []const u8,
    /// Directory to write `index.html` or `api.json` into.
    out_dir: []const u8,
    /// Package name, used as the page title and the JSON `package.name`.
    title: []const u8,
    /// For example `https://github.com/baskingspot/stdx`.
    repo_url: []const u8 = "",
    /// Commit or branch used in source links.
    rev: []const u8 = "main",
    /// Output format. The document model is the same either way.
    format: Format = .html,
};

pub const Result = struct {
    out_path: []const u8,
    symbols: usize,
    format: Format,
};

/// A symbol and its children while reading. `extract` flattens this tree into
/// the pre-order list the public model exposes.
const Node = struct {
    name: []const u8,
    fqn: []const u8,
    kind: Kind,
    signature: []const u8,
    docs: []const u8,
    file: []const u8,
    line: usize,
    children: []const Node,
};

const FileResult = struct {
    docs: []const u8,
    symbols: []const Node,
};

const Generator = struct {
    allocator: Allocator,
    io: std.Io,
    visited: std.StringHashMap(void),

    fn parseFile(gen: *Generator, path: []const u8, prefix: []const u8) anyerror!FileResult {
        if (gen.visited.contains(path)) {
            return .{ .docs = "", .symbols = &.{} };
        }
        try gen.visited.put(path, {});

        const raw = try std.Io.Dir.cwd().readFileAlloc(
            gen.io,
            path,
            gen.allocator,
            .limited(16 * 1024 * 1024),
        );
        const source = try gen.allocator.dupeZ(u8, raw);
        return gen.parseSource(path, source, prefix);
    }

    fn parseSource(
        gen: *Generator,
        path: []const u8,
        source: [:0]const u8,
        prefix: []const u8,
    ) anyerror!FileResult {
        var ast = try Ast.parse(gen.allocator, source, .zig);
        defer ast.deinit(gen.allocator);

        if (ast.errors.len != 0) {
            const tok = ast.tokens.items(.start)[ast.errors[0].token];
            const loc = std.zig.findLineColumn(ast.source, tok + ast.errorOffset(ast.errors[0]));
            std.log.err("{s}:{d}:{d}: parse error", .{ path, loc.line + 1, loc.column + 1 });
            return error.ParseError;
        }

        const docs = try containerDocs(gen.allocator, &ast);
        var symbols: std.ArrayList(Node) = .empty;
        for (ast.rootDecls()) |node| {
            if (try gen.parseDecl(&ast, node, path, prefix)) |symbol| {
                try symbols.append(gen.allocator, symbol);
            }
        }
        return .{
            .docs = docs,
            .symbols = try symbols.toOwnedSlice(gen.allocator),
        };
    }

    fn parseDecl(
        gen: *Generator,
        ast: *const Ast,
        node: Ast.Node.Index,
        file_path: []const u8,
        prefix: []const u8,
    ) anyerror!?Node {
        switch (ast.nodeTag(node)) {
            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_decl,
            => {
                var buf: [1]Ast.Node.Index = undefined;
                const proto = ast.fullFnProto(&buf, node) orelse return null;
                if (proto.visib_token == null) return null;
                const name_token = proto.name_token orelse return null;
                const name = ast.tokenSlice(name_token);
                const proto_node = protoNode(ast, node);
                const signature = try collapsedSource(gen.allocator, ast, proto_node);
                const docs = try docText(gen.allocator, ast, node);
                const fqn = try joinFqn(gen.allocator, prefix, name);
                var kind: Kind = .function;
                var children: []const Node = &.{};
                if (typeFunctionContainer(ast, node)) |container_node| {
                    kind = .type_function;
                    children = try gen.parseMembers(ast, container_node, file_path, fqn);
                }
                return .{
                    .name = name,
                    .fqn = fqn,
                    .kind = kind,
                    .signature = signature,
                    .docs = docs,
                    .file = file_path,
                    .line = sourceLine(ast, node),
                    .children = children,
                };
            },

            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                const var_decl = ast.fullVarDecl(node) orelse return null;
                if (var_decl.visib_token == null) return null;
                const name_token = var_decl.ast.mut_token + 1;
                if (ast.tokenTag(name_token) != .identifier) return null;
                const name = ast.tokenSlice(name_token);
                const fqn = try joinFqn(gen.allocator, prefix, name);
                const docs = try docText(gen.allocator, ast, node);

                var kind: Kind = if (ast.tokenTag(var_decl.ast.mut_token) == .keyword_var)
                    .variable
                else
                    .constant;
                var children: []const Node = &.{};
                var signature: []const u8 = try varSignature(gen.allocator, ast, var_decl);

                if (var_decl.ast.init_node.unwrap()) |init_node| {
                    if (containerKind(ast, init_node)) |container_kind| {
                        kind = container_kind;
                        signature = try containerSignature(gen.allocator, ast, var_decl, init_node);
                        children = try gen.parseMembers(ast, init_node, file_path, fqn);
                    } else if (try resolveInitImport(gen.allocator, ast, init_node, 0)) |import_path| {
                        kind = .module;
                        signature = try collapsedBetween(
                            gen.allocator,
                            ast,
                            var_decl.firstToken(),
                            ast.lastToken(init_node),
                        );
                        if (std.mem.endsWith(u8, import_path, ".zig") and
                            !std.fs.path.isAbsolute(import_path))
                        {
                            if (try gen.resolveImport(file_path, import_path)) |resolved| {
                                const child = try gen.parseFile(resolved, fqn);
                                children = child.symbols;
                                if (docs.len == 0) {
                                    // Keep the file's own docs with the module.
                                    return .{
                                        .name = name,
                                        .fqn = fqn,
                                        .kind = kind,
                                        .signature = signature,
                                        .docs = child.docs,
                                        .file = file_path,
                                        .line = sourceLine(ast, node),
                                        .children = children,
                                    };
                                }
                            }
                        }
                    }
                }

                return .{
                    .name = name,
                    .fqn = fqn,
                    .kind = kind,
                    .signature = signature,
                    .docs = docs,
                    .file = file_path,
                    .line = sourceLine(ast, node),
                    .children = children,
                };
            },

            else => return null,
        }
    }

    fn parseMembers(
        gen: *Generator,
        ast: *const Ast,
        container_node: Ast.Node.Index,
        file_path: []const u8,
        prefix: []const u8,
    ) anyerror![]const Node {
        var buf: [2]Ast.Node.Index = undefined;
        const container = ast.fullContainerDecl(&buf, container_node) orelse return &.{};
        var members: std.ArrayList(Node) = .empty;
        for (container.ast.members) |member| {
            switch (ast.nodeTag(member)) {
                .container_field,
                .container_field_align,
                .container_field_init,
                => {
                    const field = ast.fullContainerField(member) orelse continue;
                    const name_token = field.ast.main_token;
                    const name = ast.tokenSlice(name_token);
                    const fqn = try joinFqn(gen.allocator, prefix, name);
                    const signature = try collapsedSource(gen.allocator, ast, member);
                    const docs = try docText(gen.allocator, ast, member);
                    try members.append(gen.allocator, .{
                        .name = name,
                        .fqn = fqn,
                        .kind = .field,
                        .signature = signature,
                        .docs = docs,
                        .file = file_path,
                        .line = sourceLine(ast, member),
                        .children = &.{},
                    });
                },
                else => {
                    if (try gen.parseDecl(ast, member, file_path, prefix)) |symbol| {
                        try members.append(gen.allocator, symbol);
                    }
                },
            }
        }
        return members.toOwnedSlice(gen.allocator);
    }

    fn resolveImport(gen: *Generator, file_path: []const u8, import_path: []const u8) !?[]const u8 {
        const dir = std.fs.path.dirname(file_path) orelse ".";
        const joined = try std.fs.path.join(gen.allocator, &.{ dir, import_path });
        const resolved = try std.fs.path.resolve(gen.allocator, &.{joined});
        return resolved;
    }
};

/// Read a package into the public model. The returned document borrows the
/// allocator; use an arena if the whole document has the same lifetime.
pub fn extract(allocator: Allocator, io: std.Io, options: ExtractOptions) !Document {
    var gen: Generator = .{
        .allocator = allocator,
        .io = io,
        .visited = std.StringHashMap(void).init(allocator),
    };
    const root = try gen.parseFile(options.root_path, "");

    var symbols: std.ArrayList(model.Symbol) = .empty;
    try flatten(allocator, root.symbols, 0, null, &symbols);

    return .{
        .generator = .{
            .name = model.generator_name,
            .version = model.generator_version,
        },
        .package = .{
            .name = options.name,
            .root = options.root_path,
            .repo_url = options.repo_url,
            .rev = options.rev,
        },
        .module_docs = root.docs,
        .symbols = try symbols.toOwnedSlice(allocator),
        .diagnostics = &.{},
    };
}

/// Pre-order: append the parent, then its children. The public model is flat
/// because consumers such as Tera have no recursion.
fn flatten(
    allocator: Allocator,
    nodes: []const Node,
    depth: usize,
    parent: ?[]const u8,
    out: *std.ArrayList(model.Symbol),
) !void {
    for (nodes) |node| {
        try out.append(allocator, .{
            .name = node.name,
            .fqn = node.fqn,
            .kind = node.kind,
            .depth = depth,
            .parent = parent,
            .signature = node.signature,
            .docs = node.docs,
            .file = node.file,
            .line = node.line,
        });
        try flatten(allocator, node.children, depth + 1, node.fqn, out);
    }
}

pub fn generate(allocator: Allocator, io: std.Io, options: Options) !Result {
    const document = try extract(allocator, io, .{
        .root_path = options.root_path,
        .name = options.title,
        .repo_url = options.repo_url,
        .rev = options.rev,
    });

    const output = switch (options.format) {
        .html => try renderHtml(allocator, &document),
        .json => try writeJson(allocator, &document),
    };

    try std.Io.Dir.cwd().createDirPath(io, options.out_dir);
    const out_path = try std.fs.path.join(allocator, &.{ options.out_dir, options.format.fileName() });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = output });
    return .{
        .out_path = out_path,
        .symbols = document.symbols.len,
        .format = options.format,
    };
}

/// Render a document as one HTML page. The model is rendered in flat order;
/// `depth` selects the heading level and restores the member nesting.
pub fn renderHtml(allocator: Allocator, document: *const model.Document) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = &out;

    try w.appendSlice(
        allocator,
        "<!doctype html>\n" ++
            "<html lang=\"en\">\n" ++
            "<head>\n" ++
            "<meta charset=\"utf-8\">\n" ++
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" ++
            "<title>",
    );
    try appendEscaped(w, allocator, document.package.name);
    try w.appendSlice(allocator, " API reference</title>\n<style>\n");
    try w.appendSlice(allocator, @embedFile("style.css"));
    try w.appendSlice(
        allocator,
        "</style>\n" ++
            "</head>\n" ++
            "<body>\n" ++
            "<header class=\"top\">\n" ++
            "<div class=\"brand\"><span class=\"brand-dot\"></span>docgen</div>\n" ++
            "<h1>",
    );
    try appendEscaped(w, allocator, document.package.name);
    try w.appendSlice(allocator, "</h1>\n<p class=\"lede\">API reference</p>\n");
    if (document.package.repo_url.len != 0) {
        try w.appendSlice(allocator, "<a class=\"repo\" href=\"");
        try appendEscaped(w, allocator, document.package.repo_url);
        try w.appendSlice(allocator, "\">");
        try appendEscaped(w, allocator, stripScheme(document.package.repo_url));
        try w.appendSlice(allocator, "</a>\n");
    }
    try w.appendSlice(
        allocator,
        "</header>\n" ++
            "<div class=\"layout\">\n" ++
            "<aside class=\"sidebar\">\n" ++
            "<nav class=\"nav\">\n" ++
            "<ul>\n",
    );
    for (document.symbols) |symbol| {
        try renderNav(w, allocator, symbol);
    }
    try w.appendSlice(allocator, "</ul>\n</nav>\n</aside>\n<main class=\"content\">\n");

    if (document.module_docs.len != 0) {
        try w.appendSlice(allocator, "<div class=\"module-docs\">\n");
        try renderDocs(w, allocator, document.module_docs);
        try w.appendSlice(allocator, "</div>\n");
    }

    if (document.symbols.len == 0) {
        try w.appendSlice(allocator, "<p class=\"empty\">No public declarations found.</p>\n");
    }
    try renderSections(w, allocator, document);

    try w.appendSlice(allocator, "</main>\n</div>\n<footer class=\"footer\">Generated by docgen from <code>");
    try appendEscaped(w, allocator, document.package.root);
    try w.appendSlice(allocator, "</code>.");
    if (document.symbols.len != 0) {
        try w.print(allocator, " {d} symbols.", .{document.symbols.len});
    }
    try w.appendSlice(allocator, "</footer>\n</body>\n</html>\n");
    return out.toOwnedSlice(allocator);
}

/// Render the flat symbol list in order. A section stays open while the next
/// symbols are its descendants, so the DOM keeps the `.members` nesting of
/// the old recursive renderer.
fn renderSections(out: *std.ArrayList(u8), allocator: Allocator, document: *const model.Document) !void {
    const Open = struct {
        depth: usize,
        has_children: bool,
    };
    var open: std.ArrayList(Open) = .empty;
    defer open.deinit(allocator);

    for (document.symbols) |symbol| {
        while (open.items.len != 0 and open.items[open.items.len - 1].depth >= symbol.depth) {
            const entry = open.pop().?;
            if (entry.has_children) try out.appendSlice(allocator, "</div>\n");
            try out.appendSlice(allocator, "</section>\n");
        }
        if (open.items.len != 0) {
            const parent = &open.items[open.items.len - 1];
            std.debug.assert(parent.depth + 1 == symbol.depth);
            if (!parent.has_children) {
                try out.appendSlice(allocator, "<div class=\"members\">\n");
                parent.has_children = true;
            }
        }
        try renderSymbol(out, allocator, document, symbol);
        try open.append(allocator, .{ .depth = symbol.depth, .has_children = false });
    }

    while (open.pop()) |entry| {
        if (entry.has_children) try out.appendSlice(allocator, "</div>\n");
        try out.appendSlice(allocator, "</section>\n");
    }
}

fn renderNav(out: *std.ArrayList(u8), allocator: Allocator, symbol: model.Symbol) !void {
    try out.appendSlice(allocator, "<li");
    if (symbol.depth != 0) {
        try out.print(allocator, " class=\"depth-{d}\"", .{@min(symbol.depth, 5)});
    }
    try out.appendSlice(allocator, "><a href=\"#");
    try appendEscaped(out, allocator, symbol.fqn);
    try out.appendSlice(allocator, "\">");
    try appendEscaped(out, allocator, symbol.name);
    try out.appendSlice(allocator, "</a><span class=\"kind\">");
    try out.appendSlice(allocator, symbol.kind.label());
    try out.appendSlice(allocator, "</span></li>\n");
}

/// Render one section's opening tag and content. `renderSections` owns the
/// closing `</section>` so it can interleave the child member divs.
fn renderSymbol(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    document: *const model.Document,
    symbol: model.Symbol,
) !void {
    const level = @min(symbol.depth + 2, 5);
    try out.appendSlice(allocator, "<section class=\"symbol\" id=\"");
    try appendEscaped(out, allocator, symbol.fqn);
    try out.appendSlice(allocator, "\">\n");
    try out.print(allocator, "<h{d}><span class=\"sym-name\">", .{level});
    try appendEscaped(out, allocator, symbol.name);
    try out.appendSlice(allocator, "</span><span class=\"kind\">");
    try out.appendSlice(allocator, symbol.kind.label());
    try out.appendSlice(allocator, "</span></h");
    try out.print(allocator, "{d}>\n", .{level});

    if (symbol.signature.len != 0) {
        try out.appendSlice(allocator, "<pre class=\"sig\"><code>");
        try appendEscaped(out, allocator, symbol.signature);
        try out.appendSlice(allocator, "</code></pre>\n");
    }
    if (symbol.docs.len != 0) {
        try out.appendSlice(allocator, "<div class=\"doc\">\n");
        try renderDocs(out, allocator, symbol.docs);
        try out.appendSlice(allocator, "</div>\n");
    }
    if (document.package.repo_url.len != 0) {
        const url = try std.fmt.allocPrint(allocator, "{s}/blob/{s}/{s}#L{d}", .{
            document.package.repo_url, document.package.rev, symbol.file, symbol.line,
        });
        try out.appendSlice(allocator, "<a class=\"src\" href=\"");
        try appendEscaped(out, allocator, url);
        try out.appendSlice(allocator, "\">source</a>\n");
    }
}

fn protoNode(ast: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    return switch (ast.nodeTag(node)) {
        .fn_decl => ast.nodeData(node).node_and_node[0],
        else => node,
    };
}

fn containerKind(ast: *const Ast, node: Ast.Node.Index) ?Kind {
    switch (ast.nodeTag(node)) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => {},
        else => return null,
    }
    var buf: [2]Ast.Node.Index = undefined;
    const container = ast.fullContainerDecl(&buf, node) orelse return null;
    return switch (ast.tokenTag(container.ast.main_token)) {
        .keyword_struct => .@"struct",
        .keyword_enum => .@"enum",
        .keyword_union => .@"union",
        .keyword_opaque => .@"opaque",
        else => null,
    };
}

/// A function that returns `type` and directly returns a container. This is
/// the common `pub fn Array(...) type { return struct { ... }; }` shape.
fn typeFunctionContainer(ast: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    if (ast.nodeTag(node) != .fn_decl) return null;
    var proto_buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&proto_buf, node) orelse return null;
    const return_node = proto.ast.return_type.unwrap() orelse return null;
    if (ast.nodeTag(return_node) != .identifier) return null;
    if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(return_node)), "type")) return null;

    const body = ast.nodeData(node).node_and_node[1];
    var block_buf: [2]Ast.Node.Index = undefined;
    const statements = ast.blockStatements(&block_buf, body) orelse return null;
    for (statements) |statement| {
        if (ast.nodeTag(statement) != .@"return") continue;
        const expression = ast.nodeData(statement).opt_node.unwrap() orelse continue;
        if (containerKind(ast, expression) != null) return expression;
    }
    return null;
}

fn importPath(allocator: Allocator, ast: *const Ast, node: Ast.Node.Index) !?[]const u8 {
    var buf: [2]Ast.Node.Index = undefined;
    const params = ast.builtinCallParams(&buf, node) orelse return null;
    const main = ast.nodeMainToken(node);
    if (!std.mem.eql(u8, ast.tokenSlice(main), "@import")) return null;
    if (params.len != 1) return null;
    if (ast.nodeTag(params[0]) != .string_literal) return null;
    const lit = ast.tokenSlice(ast.nodeMainToken(params[0]));
    return std.zig.string_literal.parseAlloc(allocator, lit) catch null;
}

/// Follow `@import`, a private import alias, or an `if` that selects one.
/// This is the shape `pub const pages = if (builtin.os.tag == .linux) pages_mod else void;`.
fn resolveInitImport(
    allocator: Allocator,
    ast: *const Ast,
    node: Ast.Node.Index,
    depth: usize,
) !?[]const u8 {
    if (depth > 8) return null;
    if (try importPath(allocator, ast, node)) |path| return path;

    switch (ast.nodeTag(node)) {
        .identifier => {
            const name = ast.tokenSlice(ast.nodeMainToken(node));
            for (ast.rootDecls()) |decl_node| {
                const var_decl = ast.fullVarDecl(decl_node) orelse continue;
                const name_token = var_decl.ast.mut_token + 1;
                if (!std.mem.eql(u8, ast.tokenSlice(name_token), name)) continue;
                const init = var_decl.ast.init_node.unwrap() orelse return null;
                return resolveInitImport(allocator, ast, init, depth + 1);
            }
            return null;
        },
        .if_simple, .@"if" => {
            const if_expr = ast.fullIf(node) orelse return null;
            if (try resolveInitImport(allocator, ast, if_expr.ast.then_expr, depth + 1)) |path| {
                return path;
            }
            if (if_expr.ast.else_expr.unwrap()) |else_node| {
                return resolveInitImport(allocator, ast, else_node, depth + 1);
            }
            return null;
        },
        else => return null,
    }
}

fn varSignature(allocator: Allocator, ast: *const Ast, var_decl: Ast.full.VarDecl) ![]const u8 {
    const type_node = var_decl.ast.type_node.unwrap();
    const last_token = if (type_node) |node|
        ast.lastToken(node)
    else
        var_decl.ast.mut_token + 1;
    return collapsedBetween(allocator, ast, var_decl.firstToken(), last_token);
}

fn containerSignature(
    allocator: Allocator,
    ast: *const Ast,
    var_decl: Ast.full.VarDecl,
    init_node: Ast.Node.Index,
) ![]const u8 {
    var buf: [2]Ast.Node.Index = undefined;
    const container = ast.fullContainerDecl(&buf, init_node) orelse
        return collapsedBetween(allocator, ast, var_decl.firstToken(), ast.lastToken(init_node));
    return collapsedBetween(allocator, ast, var_decl.firstToken(), container.ast.main_token);
}

fn collapsedSource(allocator: Allocator, ast: *const Ast, node: Ast.Node.Index) ![]const u8 {
    return collapsedBetween(allocator, ast, ast.firstToken(node), ast.lastToken(node));
}

fn collapsedBetween(allocator: Allocator, ast: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) ![]const u8 {
    const start = ast.tokenStart(first);
    const end = ast.tokenStart(last) + ast.tokenSlice(last).len;
    return collapseWhitespace(allocator, ast.source[start..end]);
}

fn collapseWhitespace(allocator: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            space = true;
            continue;
        }
        if (space and out.items.len != 0) try out.append(allocator, ' ');
        space = false;
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

fn sourceLine(ast: *const Ast, node: Ast.Node.Index) usize {
    return ast.tokenLocation(0, ast.firstToken(node)).line + 1;
}

fn joinFqn(allocator: Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, name });
}

fn containerDocs(allocator: Allocator, ast: *const Ast) ![]const u8 {
    var end: Ast.TokenIndex = 0;
    while (end < ast.tokens.len and ast.tokenTag(end) == .container_doc_comment) : (end += 1) {}
    return docTokens(allocator, ast, 0, end);
}

fn docText(allocator: Allocator, ast: *const Ast, node: Ast.Node.Index) ![]const u8 {
    const first = ast.firstToken(node);
    var start = first;
    while (start > 0) {
        const tag = ast.tokenTag(start - 1);
        if (tag != .doc_comment and tag != .container_doc_comment) break;
        start -= 1;
    }
    return docTokens(allocator, ast, start, first);
}

fn docTokens(allocator: Allocator, ast: *const Ast, start: Ast.TokenIndex, end: Ast.TokenIndex) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i = start;
    while (i < end) : (i += 1) {
        const token = ast.tokenSlice(i);
        if (token.len < 3) continue;
        var line = token[3..];
        if (line.len != 0 and line[0] == ' ') line = line[1..];
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn renderDocs(out: *std.ArrayList(u8), allocator: Allocator, docs: []const u8) !void {
    var lines = std.mem.splitScalar(u8, docs, '\n');
    var in_para = false;
    var in_code = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (in_para) {
                try out.appendSlice(allocator, "</p>\n");
                in_para = false;
            }
            if (in_code) {
                try out.appendSlice(allocator, "</code></pre>\n");
            } else {
                try out.appendSlice(allocator, "<pre class=\"code\"><code>");
            }
            in_code = !in_code;
            continue;
        }
        if (in_code) {
            try appendEscaped(out, allocator, line);
            try out.append(allocator, '\n');
            continue;
        }
        if (trimmed.len == 0) {
            if (in_para) {
                try out.appendSlice(allocator, "</p>\n");
                in_para = false;
            }
            continue;
        }
        if (trimmed[0] == '#') {
            if (in_para) {
                try out.appendSlice(allocator, "</p>\n");
                in_para = false;
            }
            var level: usize = 0;
            while (level < trimmed.len and trimmed[level] == '#') : (level += 1) {}
            const text = std.mem.trimStart(u8, trimmed[level..], " ");
            try out.print(allocator, "<h4>", .{});
            try appendEscaped(out, allocator, text);
            try out.appendSlice(allocator, "</h4>\n");
            continue;
        }
        if (!in_para) {
            try out.appendSlice(allocator, "<p>");
            in_para = true;
        } else {
            try out.append(allocator, ' ');
        }
        try renderInline(out, allocator, trimmed);
    }
    if (in_para) try out.appendSlice(allocator, "</p>\n");
    if (in_code) try out.appendSlice(allocator, "</code></pre>\n");
}

fn renderInline(out: *std.ArrayList(u8), allocator: Allocator, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            if (std.mem.findScalarPos(u8, line, i + 1, '`')) |end| {
                try out.appendSlice(allocator, "<code>");
                try appendEscaped(out, allocator, line[i + 1 .. end]);
                try out.appendSlice(allocator, "</code>");
                i = end + 1;
                continue;
            }
        }
        try appendEscapedChar(out, allocator, line[i]);
        i += 1;
    }
}

fn appendEscaped(out: *std.ArrayList(u8), allocator: Allocator, text: []const u8) !void {
    for (text) |c| try appendEscapedChar(out, allocator, c);
}

fn appendEscapedChar(out: *std.ArrayList(u8), allocator: Allocator, c: u8) !void {
    switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\'' => try out.appendSlice(allocator, "&#39;"),
        else => try out.append(allocator, c),
    }
}

fn stripScheme(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "https://")) return url["https://".len..];
    if (std.mem.startsWith(u8, url, "http://")) return url["http://".len..];
    return url;
}

test "docs render paragraphs, code, and headings" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try renderDocs(&out, std.testing.allocator,
        \\First paragraph with `code`.
        \\
        \\## Details
        \\
        \\Second paragraph.
    );
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<p>First paragraph with <code>code</code>.</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<h4>Details</h4>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<p>Second paragraph.</p>") != null);
}

test "escaping" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendEscaped(&out, std.testing.allocator, "<a & \"b\">");
    try std.testing.expectEqualStrings("&lt;a &amp; &quot;b&quot;&gt;", out.items);
}

test "type function members are collected" {
    const source =
        \\pub fn Array(comptime len: usize) type {
        \\    return struct {
        \\        /// The bytes.
        \\        data: [len]u8,
        \\
        \\        /// Make one.
        \\        pub fn init(data: [len]u8) @This() {
        \\            return .{ .data = data };
        \\        }
        \\    };
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var gen: Generator = .{
        .allocator = arena,
        .io = std.testing.io,
        .visited = std.StringHashMap(void).init(arena),
    };
    const file = try gen.parseSource("test.zig", source, "");
    try std.testing.expectEqual(1, file.symbols.len);
    try std.testing.expectEqual(Kind.type_function, file.symbols[0].kind);
    try std.testing.expectEqual(2, file.symbols[0].children.len);
    try std.testing.expectEqualStrings("data", file.symbols[0].children[0].name);
    try std.testing.expectEqualStrings("init", file.symbols[0].children[1].name);
}

test "conditional import aliases resolve" {
    const source =
        \\const pages_mod = @import("pages.zig");
        \\pub const pages = if (true) pages_mod else void;
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ast = try Ast.parse(arena, source, .zig);
    defer ast.deinit(arena);
    try std.testing.expectEqual(0, ast.errors.len);

    const pages_decl = ast.rootDecls()[1];
    const var_decl = ast.fullVarDecl(pages_decl).?;
    const init = var_decl.ast.init_node.unwrap().?;
    const resolved = try resolveInitImport(arena, &ast, init, 0);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("pages.zig", resolved.?);
}

const fixture_root = "tests/fixtures/tiny/root.zig";
const fixture_internal = "tests/fixtures/tiny/internal.zig";
const fixture_maybe = "tests/fixtures/tiny/maybe.zig";

const ExpectedSymbol = struct {
    name: []const u8,
    fqn: []const u8,
    kind: Kind,
    depth: usize,
    parent: ?[]const u8,
    signature: []const u8,
    docs: []const u8,
    file: []const u8,
    line: usize,
};

const expected_fixture_symbols = [_]ExpectedSymbol{
    .{
        .name = "Point",
        .fqn = "Point",
        .kind = .@"struct",
        .depth = 0,
        .parent = null,
        .signature = "pub const Point = struct",
        .docs = "A point in the plane.\n",
        .file = fixture_root,
        .line = 12,
    },
    .{
        .name = "x",
        .fqn = "Point.x",
        .kind = .field,
        .depth = 1,
        .parent = "Point",
        .signature = "x: f64",
        .docs = "Horizontal coordinate.\n",
        .file = fixture_root,
        .line = 14,
    },
    .{
        .name = "y",
        .fqn = "Point.y",
        .kind = .field,
        .depth = 1,
        .parent = "Point",
        .signature = "y: f64",
        .docs = "Vertical coordinate.\n",
        .file = fixture_root,
        .line = 17,
    },
    .{
        .name = "magnitude",
        .fqn = "Point.magnitude",
        .kind = .function,
        .depth = 1,
        .parent = "Point",
        .signature = "pub fn magnitude(self: Point) f64",
        .docs = "Distance from the origin.\n",
        .file = fixture_root,
        .line = 20,
    },
    .{
        .name = "Color",
        .fqn = "Color",
        .kind = .@"enum",
        .depth = 0,
        .parent = null,
        .signature = "pub const Color = enum",
        .docs = "A color.\n",
        .file = fixture_root,
        .line = 26,
    },
    .{
        .name = "red",
        .fqn = "Color.red",
        .kind = .field,
        .depth = 1,
        .parent = "Color",
        .signature = "red",
        .docs = "",
        .file = fixture_root,
        .line = 27,
    },
    .{
        .name = "green",
        .fqn = "Color.green",
        .kind = .field,
        .depth = 1,
        .parent = "Color",
        .signature = "green",
        .docs = "",
        .file = fixture_root,
        .line = 28,
    },
    .{
        .name = "Array",
        .fqn = "Array",
        .kind = .type_function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn Array(comptime len: usize) type",
        .docs = "A fixed-length array.\n",
        .file = fixture_root,
        .line = 32,
    },
    .{
        .name = "data",
        .fqn = "Array.data",
        .kind = .field,
        .depth = 1,
        .parent = "Array",
        .signature = "data: [len]u8",
        .docs = "The bytes.\n",
        .file = fixture_root,
        .line = 35,
    },
    .{
        .name = "empty",
        .fqn = "Array.empty",
        .kind = .function,
        .depth = 1,
        .parent = "Array",
        .signature = "pub fn empty() @This()",
        .docs = "An empty array.\n",
        .file = fixture_root,
        .line = 38,
    },
    .{
        .name = "internal",
        .fqn = "internal",
        .kind = .module,
        .depth = 0,
        .parent = null,
        .signature = "pub const internal = @import(\"internal.zig\")",
        .docs = "",
        .file = fixture_root,
        .line = 44,
    },
    .{
        .name = "add",
        .fqn = "internal.add",
        .kind = .function,
        .depth = 1,
        .parent = "internal",
        .signature = "pub fn add(a: i32, b: i32) i32",
        .docs = "Add two numbers.\n",
        .file = fixture_internal,
        .line = 4,
    },
    .{
        .name = "maybe",
        .fqn = "maybe",
        .kind = .module,
        .depth = 0,
        .parent = null,
        .signature = "pub const maybe = if (true) maybe_mod else void",
        .docs = "",
        .file = fixture_root,
        .line = 46,
    },
    .{
        .name = "flag",
        .fqn = "maybe.flag",
        .kind = .constant,
        .depth = 1,
        .parent = "maybe",
        .signature = "pub const flag",
        .docs = "A flag.\n",
        .file = fixture_maybe,
        .line = 2,
    },
};

fn extractFixture(allocator: Allocator) !Document {
    return extract(allocator, std.testing.io, .{
        .root_path = fixture_root,
        .name = "tiny",
        .repo_url = "https://example.com/tiny",
        .rev = "v1",
    });
}

test "extract fixture into a flat pre-order list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try extractFixture(arena);

    try std.testing.expectEqual(@as(u32, 1), document.schema_version);
    try std.testing.expectEqualStrings("docgen", document.generator.name);
    try std.testing.expectEqualStrings("0.0.0", document.generator.version);
    try std.testing.expectEqualStrings("tiny", document.package.name);
    try std.testing.expectEqualStrings(fixture_root, document.package.root);
    try std.testing.expectEqualStrings("https://example.com/tiny", document.package.repo_url);
    try std.testing.expectEqualStrings("v1", document.package.rev);
    try std.testing.expectEqualStrings(
        "Tiny fixture package.\n\nIt exercises the reader.\n\n## Layout\n\nThe modules live beside this file.\n",
        document.module_docs,
    );
    try std.testing.expectEqual(0, document.diagnostics.len);

    try std.testing.expectEqual(expected_fixture_symbols.len, document.symbols.len);
    for (expected_fixture_symbols, document.symbols) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqualStrings(want.fqn, got.fqn);
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqual(want.depth, got.depth);
        if (want.parent) |parent| {
            try std.testing.expectEqualStrings(parent, got.parent.?);
        } else {
            try std.testing.expect(got.parent == null);
        }
        try std.testing.expectEqualStrings(want.signature, got.signature);
        try std.testing.expectEqualStrings(want.docs, got.docs);
        try std.testing.expectEqualStrings(want.file, got.file);
        try std.testing.expectEqual(want.line, got.line);
    }
}

test "writeJson emits schema v1 with raw markdown" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try extractFixture(arena);
    const json = try writeJson(arena, &document);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    const root = parsed.value.object;

    const top_level_keys = [_][]const u8{
        "schema_version",
        "generator",
        "package",
        "module_docs",
        "symbols",
        "diagnostics",
    };
    try std.testing.expectEqual(top_level_keys.len, root.count());
    var top_level = root.iterator();
    for (top_level_keys) |key| {
        const entry = top_level.next() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(key, entry.key_ptr.*);
    }
    try std.testing.expect(top_level.next() == null);

    try std.testing.expectEqual(@as(i64, 1), root.get("schema_version").?.integer);

    const generator = root.get("generator").?.object;
    try std.testing.expectEqual(@as(usize, 2), generator.count());
    try std.testing.expectEqualStrings("docgen", generator.get("name").?.string);
    try std.testing.expectEqualStrings("0.0.0", generator.get("version").?.string);

    const package = root.get("package").?.object;
    try std.testing.expectEqual(@as(usize, 4), package.count());
    try std.testing.expectEqualStrings("tiny", package.get("name").?.string);
    try std.testing.expectEqualStrings(fixture_root, package.get("root").?.string);
    try std.testing.expectEqualStrings("https://example.com/tiny", package.get("repo_url").?.string);
    try std.testing.expectEqualStrings("v1", package.get("rev").?.string);

    try std.testing.expectEqualStrings(
        "Tiny fixture package.\n\nIt exercises the reader.\n\n## Layout\n\nThe modules live beside this file.\n",
        root.get("module_docs").?.string,
    );
    try std.testing.expectEqual(@as(usize, 0), root.get("diagnostics").?.array.items.len);

    const symbols = root.get("symbols").?.array.items;
    try std.testing.expectEqual(expected_fixture_symbols.len, symbols.len);

    const symbol_keys = [_][]const u8{
        "name", "fqn", "kind", "depth", "parent", "signature", "docs", "file", "line",
    };
    const point = symbols[0].object;
    try std.testing.expectEqual(symbol_keys.len, point.count());
    var point_fields = point.iterator();
    for (symbol_keys) |key| {
        const entry = point_fields.next() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(key, entry.key_ptr.*);
    }
    try std.testing.expect(point_fields.next() == null);

    try std.testing.expectEqualStrings("Point", point.get("name").?.string);
    try std.testing.expectEqualStrings("Point", point.get("fqn").?.string);
    try std.testing.expectEqualStrings("struct", point.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 0), point.get("depth").?.integer);
    switch (point.get("parent").?) {
        .null => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("pub const Point = struct", point.get("signature").?.string);
    // The JSON keeps markdown as written, including the trailing newline.
    try std.testing.expectEqualStrings("A point in the plane.\n", point.get("docs").?.string);
    try std.testing.expectEqualStrings(fixture_root, point.get("file").?.string);
    try std.testing.expectEqual(@as(i64, 12), point.get("line").?.integer);

    const magnitude = symbols[3].object;
    try std.testing.expectEqualStrings("Point.magnitude", magnitude.get("fqn").?.string);
    try std.testing.expectEqualStrings("function", magnitude.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), magnitude.get("depth").?.integer);
    try std.testing.expectEqualStrings("Point", magnitude.get("parent").?.string);
    try std.testing.expectEqualStrings("Distance from the origin.\n", magnitude.get("docs").?.string);

    const add = symbols[11].object;
    try std.testing.expectEqualStrings("module", symbols[10].object.get("kind").?.string);
    try std.testing.expectEqualStrings(fixture_internal, add.get("file").?.string);
    try std.testing.expectEqual(@as(i64, 4), add.get("line").?.integer);
    try std.testing.expectEqualStrings("internal", add.get("parent").?.string);

    for (expected_fixture_symbols, symbols) |want, symbol| {
        try std.testing.expectEqualStrings(@tagName(want.kind), symbol.object.get("kind").?.string);
    }
}

test "JSON round-trips into the model and renders the same HTML" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try extractFixture(arena);
    const json = try writeJson(arena, &document);
    const parsed = try std.json.parseFromSlice(model.Document, arena, json, .{});

    try std.testing.expectEqualStrings(document.module_docs, parsed.value.module_docs);
    try std.testing.expectEqual(document.symbols.len, parsed.value.symbols.len);

    const direct = try renderHtml(arena, &document);
    const round_trip = try renderHtml(arena, &parsed.value);
    try std.testing.expectEqualStrings(direct, round_trip);
}

test "renderHtml escapes <, &, and quotes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const symbols = [_]model.Symbol{.{
        .name = "less<",
        .fqn = "mod.less<",
        .kind = .function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn less(a: &T, b: &T) bool",
        .docs = "Use <tag> & \"quotes\".",
        .file = "src/mod.zig",
        .line = 7,
    }};
    const document: model.Document = .{
        .generator = .{ .name = "docgen", .version = "0.0.0" },
        .package = .{
            .name = "a<b & \"c\"",
            .root = "src/<root>.zig",
            .repo_url = "https://example.com/r?a=1&b=2",
            .rev = "main",
        },
        .module_docs = "Root <docs> & \"more\".",
        .symbols = &symbols,
        .diagnostics = &.{},
    };

    const html = try renderHtml(arena, &document);

    try std.testing.expect(std.mem.indexOf(u8, html, "<tag>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "less<") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<root>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;tag&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "less&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;root&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "a&lt;b &amp; &quot;c&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "a=1&amp;b=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;quotes&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;more&quot;") != null);
}
