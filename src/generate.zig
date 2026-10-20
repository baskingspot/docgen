//! Generate one static HTML page from a Zig package's public declarations.
//!
//! This is deliberately an AST-only reader. It follows relative `@import`
//! paths, collects public declarations and their doc comments, and writes a
//! single `index.html`. It does not resolve types, aliases, or the build
//! graph.

const std = @import("std");
const Ast = std.zig.Ast;

const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Root source file of the package, relative to the current directory.
    root_path: []const u8,
    /// Directory to write `index.html` into.
    out_dir: []const u8,
    title: []const u8,
    /// For example `https://github.com/baskingspot/stdx`.
    repo_url: []const u8 = "",
    /// Commit or branch used in source links.
    rev: []const u8 = "main",
};

const Kind = enum {
    function,
    constant,
    variable,
    namespace,
    struct_decl,
    enum_decl,
    union_decl,
    opaque_decl,
    type_function,
    field,

    fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .function => "fn",
            .constant => "const",
            .variable => "var",
            .namespace => "module",
            .struct_decl => "struct",
            .enum_decl => "enum",
            .union_decl => "union",
            .opaque_decl => "opaque",
            .type_function => "type fn",
            .field => "field",
        };
    }
};

const Symbol = struct {
    name: []const u8,
    fqn: []const u8,
    kind: Kind,
    signature: []const u8,
    docs: []const u8,
    file: []const u8,
    line: usize,
    children: []const Symbol,
};

const FileResult = struct {
    docs: []const u8,
    symbols: []const Symbol,
};

const Generator = struct {
    allocator: Allocator,
    io: std.Io,
    repo_url: []const u8,
    rev: []const u8,
    visited: std.StringHashMap(void),
    symbol_count: usize = 0,

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
        var symbols: std.ArrayList(Symbol) = .empty;
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
    ) anyerror!?Symbol {
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
                var children: []const Symbol = &.{};
                if (typeFunctionContainer(ast, node)) |container_node| {
                    kind = .type_function;
                    children = try gen.parseMembers(ast, container_node, file_path, fqn);
                }
                gen.symbol_count += 1;
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
                var children: []const Symbol = &.{};
                var signature: []const u8 = try varSignature(gen.allocator, ast, var_decl);

                if (var_decl.ast.init_node.unwrap()) |init_node| {
                    if (containerKind(ast, init_node)) |container_kind| {
                        kind = container_kind;
                        signature = try containerSignature(gen.allocator, ast, var_decl, init_node);
                        children = try gen.parseMembers(ast, init_node, file_path, fqn);
                    } else if (try resolveInitImport(gen.allocator, ast, init_node, 0)) |import_path| {
                        kind = .namespace;
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

                gen.symbol_count += 1;
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
    ) anyerror![]const Symbol {
        var buf: [2]Ast.Node.Index = undefined;
        const container = ast.fullContainerDecl(&buf, container_node) orelse return &.{};
        var members: std.ArrayList(Symbol) = .empty;
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
                    gen.symbol_count += 1;
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

    fn render(
        gen: *Generator,
        root_path: []const u8,
        root_docs: []const u8,
        symbols: []const Symbol,
        title: []const u8,
    ) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const w = &out;

        try w.appendSlice(
            gen.allocator,
            "<!doctype html>\n" ++
                "<html lang=\"en\">\n" ++
                "<head>\n" ++
                "<meta charset=\"utf-8\">\n" ++
                "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" ++
                "<title>",
        );
        try appendEscaped(w, gen.allocator, title);
        try w.appendSlice(gen.allocator, " API reference</title>\n<style>\n");
        try w.appendSlice(gen.allocator, @embedFile("style.css"));
        try w.appendSlice(
            gen.allocator,
            "</style>\n" ++
                "</head>\n" ++
                "<body>\n" ++
                "<header class=\"top\">\n" ++
                "<div class=\"brand\"><span class=\"brand-dot\"></span>docgen</div>\n" ++
                "<h1>",
        );
        try appendEscaped(w, gen.allocator, title);
        try w.appendSlice(gen.allocator, "</h1>\n<p class=\"lede\">API reference</p>\n");
        if (gen.repo_url.len != 0) {
            try w.appendSlice(gen.allocator, "<a class=\"repo\" href=\"");
            try appendEscaped(w, gen.allocator, gen.repo_url);
            try w.appendSlice(gen.allocator, "\">");
            try appendEscaped(w, gen.allocator, stripScheme(gen.repo_url));
            try w.appendSlice(gen.allocator, "</a>\n");
        }
        try w.appendSlice(
            gen.allocator,
            "</header>\n" ++
                "<div class=\"layout\">\n" ++
                "<aside class=\"sidebar\">\n" ++
                "<nav class=\"nav\">\n" ++
                "<ul>\n",
        );
        for (symbols) |symbol| {
            try renderNav(w, gen.allocator, symbol);
        }
        try w.appendSlice(gen.allocator, "</ul>\n</nav>\n</aside>\n<main class=\"content\">\n");

        if (root_docs.len != 0) {
            try w.appendSlice(gen.allocator, "<div class=\"module-docs\">\n");
            try renderDocs(w, gen.allocator, root_docs);
            try w.appendSlice(gen.allocator, "</div>\n");
        }

        if (symbols.len == 0) {
            try w.appendSlice(gen.allocator, "<p class=\"empty\">No public declarations found.</p>\n");
        }
        for (symbols) |symbol| {
            try renderSymbol(w, gen.allocator, gen.repo_url, gen.rev, symbol, 0);
        }

        try w.appendSlice(gen.allocator, "</main>\n</div>\n<footer class=\"footer\">Generated by docgen from <code>");
        try appendEscaped(w, gen.allocator, root_path);
        try w.appendSlice(gen.allocator, "</code>.");
        if (gen.symbol_count != 0) {
            try w.print(gen.allocator, " {d} symbols.", .{gen.symbol_count});
        }
        try w.appendSlice(gen.allocator, "</footer>\n</body>\n</html>\n");
        return out.toOwnedSlice(gen.allocator);
    }
};

pub const Result = struct {
    out_path: []const u8,
    symbols: usize,
};

pub fn generate(allocator: Allocator, io: std.Io, options: Options) !Result {
    var gen: Generator = .{
        .allocator = allocator,
        .io = io,
        .repo_url = options.repo_url,
        .rev = options.rev,
        .visited = std.StringHashMap(void).init(allocator),
    };
    const root = try gen.parseFile(options.root_path, "");
    const html = try gen.render(options.root_path, root.docs, root.symbols, options.title);

    std.Io.Dir.cwd().createDir(io, options.out_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const out_path = try std.fs.path.join(allocator, &.{ options.out_dir, "index.html" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = html });
    return .{ .out_path = out_path, .symbols = gen.symbol_count };
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
        .keyword_struct => .struct_decl,
        .keyword_enum => .enum_decl,
        .keyword_union => .union_decl,
        .keyword_opaque => .opaque_decl,
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

fn renderNav(out: *std.ArrayList(u8), allocator: Allocator, symbol: Symbol) !void {
    try out.appendSlice(allocator, "<li><a href=\"#");
    try appendEscaped(out, allocator, symbol.fqn);
    try out.appendSlice(allocator, "\">");
    try appendEscaped(out, allocator, symbol.name);
    try out.appendSlice(allocator, "</a><span class=\"kind\">");
    try out.appendSlice(allocator, symbol.kind.label());
    try out.appendSlice(allocator, "</span>");
    if (symbol.children.len != 0) {
        try out.appendSlice(allocator, "<ul>");
        for (symbol.children) |child| {
            try out.appendSlice(allocator, "<li><a href=\"#");
            try appendEscaped(out, allocator, child.fqn);
            try out.appendSlice(allocator, "\">");
            try appendEscaped(out, allocator, child.name);
            try out.appendSlice(allocator, "</a></li>");
        }
        try out.appendSlice(allocator, "</ul>");
    }
    try out.appendSlice(allocator, "</li>");
}

fn renderSymbol(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    repo_url: []const u8,
    rev: []const u8,
    symbol: Symbol,
    depth: usize,
) !void {
    const level = @min(depth + 2, 5);
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
    if (repo_url.len != 0) {
        const url = try std.fmt.allocPrint(allocator, "{s}/blob/{s}/{s}#L{d}", .{
            repo_url, rev, symbol.file, symbol.line,
        });
        try out.appendSlice(allocator, "<a class=\"src\" href=\"");
        try appendEscaped(out, allocator, url);
        try out.appendSlice(allocator, "\">source</a>\n");
    }
    if (symbol.children.len != 0) {
        try out.appendSlice(allocator, "<div class=\"members\">\n");
        for (symbol.children) |child| {
            try renderSymbol(out, allocator, repo_url, rev, child, depth + 1);
        }
        try out.appendSlice(allocator, "</div>\n");
    }
    try out.appendSlice(allocator, "</section>\n");
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
        .repo_url = "",
        .rev = "main",
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
