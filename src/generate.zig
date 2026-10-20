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

/// One parsed source file, cached once per resolved path. Import expansions
/// rebuild the declarations under each alias prefix, so the cached AST stays
/// prefix-free.
const ParsedFile = struct {
    path: []const u8,
    ast: Ast,
    docs: []const u8,
    /// Top-level declarations by name, built before any declaration is read so
    /// forward references resolve.
    decls: std.StringHashMap(Ast.Node.Index),
};

/// A declaration found while resolving an alias initializer.
const DeclRef = struct {
    file: *ParsedFile,
    node: Ast.Node.Index,
};

/// What an alias initializer names: a file (`@import` or a module alias) or a
/// declaration in a file.
const Target = union(enum) {
    file: []const u8,
    decl: DeclRef,
};

/// A resolved alias target, classified for rendering.
const AliasTarget = union(enum) {
    container: struct {
        file: *ParsedFile,
        node: Ast.Node.Index,
        kind: Kind,
        docs: []const u8,
    },
    type_function: struct {
        file: *ParsedFile,
        node: Ast.Node.Index,
        docs: []const u8,
    },
    function: struct {
        signature: []const u8,
        docs: []const u8,
    },
    value: struct {
        docs: []const u8,
    },
    module: struct {
        path: []const u8,
    },
};

const Generator = struct {
    allocator: Allocator,
    io: std.Io,
    /// Parsed files keyed by resolved path. The AST is shared by every alias.
    files: std.StringHashMap(*ParsedFile),
    /// Resolved paths on the current expansion path, for cycle detection.
    stack: std.ArrayList([]const u8),
    /// Alias targets on the current expansion path. A container that re-exports
    /// itself through a member terminates instead of recursing forever.
    alias_stack: std.ArrayList(DeclRef),

    fn loadFile(gen: *Generator, path: []const u8) anyerror!*ParsedFile {
        if (gen.files.get(path)) |file| return file;

        const raw = try std.Io.Dir.cwd().readFileAlloc(
            gen.io,
            path,
            gen.allocator,
            .limited(16 * 1024 * 1024),
        );
        const source = try gen.allocator.dupeZ(u8, raw);
        const file = try gen.parseSource(path, source);
        try gen.files.put(try gen.allocator.dupe(u8, path), file);
        return file;
    }

    /// Parse one file and index its top-level declarations. The caller owns
    /// the source through the generator allocator; nothing is deinitialized
    /// because the arena outlives the whole extraction.
    fn parseSource(
        gen: *Generator,
        path: []const u8,
        source: [:0]const u8,
    ) anyerror!*ParsedFile {
        const ast = try Ast.parse(gen.allocator, source, .zig);
        if (ast.errors.len != 0) {
            const tok = ast.tokens.items(.start)[ast.errors[0].token];
            const loc = std.zig.findLineColumn(ast.source, tok + ast.errorOffset(ast.errors[0]));
            std.log.err("{s}:{d}:{d}: parse error", .{ path, loc.line + 1, loc.column + 1 });
            return error.ParseError;
        }

        const file = try gen.allocator.create(ParsedFile);
        file.* = .{
            .path = path,
            .ast = ast,
            .docs = try containerDocs(gen.allocator, &ast),
            .decls = std.StringHashMap(Ast.Node.Index).init(gen.allocator),
        };
        for (file.ast.rootDecls()) |node| {
            const name = declName(&file.ast, node) orelse continue;
            if (file.decls.contains(name)) continue;
            try file.decls.put(name, node);
        }
        return file;
    }

    fn parseFile(gen: *Generator, path: []const u8, prefix: []const u8) anyerror!FileResult {
        if (gen.inStack(path)) {
            return .{ .docs = "", .symbols = &.{} };
        }
        try gen.stack.append(gen.allocator, path);
        defer _ = gen.stack.pop();

        const file = try gen.loadFile(path);
        return .{
            .docs = file.docs,
            .symbols = try gen.parseDecls(file, prefix),
        };
    }

    fn inStack(gen: *const Generator, path: []const u8) bool {
        for (gen.stack.items) |entry| {
            if (std.mem.eql(u8, entry, path)) return true;
        }
        return false;
    }

    fn parseAliasMembers(
        gen: *Generator,
        file: *ParsedFile,
        node: Ast.Node.Index,
        prefix: []const u8,
    ) anyerror![]const Node {
        for (gen.alias_stack.items) |entry| {
            if (entry.file == file and entry.node == node) return &.{};
        }
        try gen.alias_stack.append(gen.allocator, .{ .file = file, .node = node });
        defer _ = gen.alias_stack.pop();
        return gen.parseMembers(file, node, prefix);
    }

    fn parseDecls(gen: *Generator, file: *ParsedFile, prefix: []const u8) anyerror![]const Node {
        var symbols: std.ArrayList(Node) = .empty;
        for (file.ast.rootDecls()) |node| {
            if (try gen.parseDecl(file, node, prefix)) |symbol| {
                try symbols.append(gen.allocator, symbol);
            }
        }
        return symbols.toOwnedSlice(gen.allocator);
    }

    fn parseDecl(
        gen: *Generator,
        file: *ParsedFile,
        node: Ast.Node.Index,
        prefix: []const u8,
    ) anyerror!?Node {
        const ast = &file.ast;
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
                const kind: Kind = if (returnsType(ast, node)) .type_function else .function;
                var children: []const Node = &.{};
                if (kind == .type_function) {
                    if (typeFunctionContainer(file, node, 0)) |container_node| {
                        children = try gen.parseMembers(file, container_node, fqn);
                    }
                }
                return .{
                    .name = name,
                    .fqn = fqn,
                    .kind = kind,
                    .signature = signature,
                    .docs = docs,
                    .file = file.path,
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
                const call_site_signature = try varSignature(gen.allocator, ast, var_decl);

                if (var_decl.ast.init_node.unwrap()) |init_node| {
                    if (containerKind(ast, init_node)) |container_kind| {
                        return .{
                            .name = name,
                            .fqn = fqn,
                            .kind = container_kind,
                            .signature = try containerSignature(gen.allocator, ast, var_decl, init_node),
                            .docs = docs,
                            .file = file.path,
                            .line = sourceLine(ast, node),
                            .children = try gen.parseMembers(file, init_node, fqn),
                        };
                    }

                    if (try gen.resolveTarget(file, init_node, 0)) |target| {
                        switch (target) {
                            .file => |import_path| {
                                var children: []const Node = &.{};
                                var child_docs: []const u8 = "";
                                if (isRelativeZigPath(import_path)) {
                                    const child = try gen.parseFile(import_path, fqn);
                                    children = child.symbols;
                                    child_docs = child.docs;
                                }
                                return .{
                                    .name = name,
                                    .fqn = fqn,
                                    .kind = .module,
                                    .signature = call_site_signature,
                                    .docs = if (docs.len != 0) docs else child_docs,
                                    .file = file.path,
                                    .line = sourceLine(ast, node),
                                    .children = children,
                                };
                            },
                            .decl => |ref| {
                                if (try gen.classifyDecl(ref, 0)) |resolved| {
                                    return try gen.buildAlias(
                                        file,
                                        node,
                                        name,
                                        fqn,
                                        docs,
                                        call_site_signature,
                                        resolved,
                                    );
                                }
                            },
                        }
                    }
                }

                return .{
                    .name = name,
                    .fqn = fqn,
                    .kind = if (ast.tokenTag(var_decl.ast.mut_token) == .keyword_var)
                        .variable
                    else
                        .constant,
                    .signature = call_site_signature,
                    .docs = docs,
                    .file = file.path,
                    .line = sourceLine(ast, node),
                    .children = &.{},
                };
            },

            else => return null,
        }
    }

    fn parseMembers(
        gen: *Generator,
        file: *ParsedFile,
        container_node: Ast.Node.Index,
        prefix: []const u8,
    ) anyerror![]const Node {
        const ast = &file.ast;
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
                        .file = file.path,
                        .line = sourceLine(ast, member),
                        .children = &.{},
                    });
                },
                else => {
                    if (try gen.parseDecl(file, member, prefix)) |symbol| {
                        try members.append(gen.allocator, symbol);
                    }
                },
            }
        }
        return members.toOwnedSlice(gen.allocator);
    }

    /// Resolve the expression a `const`/`var` initializer names. Only imports,
    /// identifiers, field access, `if`, and grouped expressions are followed;
    /// calls and other value expressions stay opaque.
    fn resolveTarget(
        gen: *Generator,
        file: *ParsedFile,
        node: Ast.Node.Index,
        depth: usize,
    ) anyerror!?Target {
        if (depth > 12) return null;
        const ast = &file.ast;

        if (try importPath(gen.allocator, ast, node)) |path| {
            if (try gen.resolveImport(file.path, path)) |resolved| {
                return .{ .file = resolved };
            }
            // A package or absolute import stays an opaque module.
            return .{ .file = path };
        }

        switch (ast.nodeTag(node)) {
            .identifier => {
                const name = ast.tokenSlice(ast.nodeMainToken(node));
                const decl = file.decls.get(name) orelse return null;
                return .{ .decl = .{ .file = file, .node = decl } };
            },
            .field_access => {
                const data = ast.nodeData(node).node_and_token;
                const selector = ast.tokenSlice(data[1]);
                const base = try gen.resolveTarget(file, data[0], depth + 1) orelse return null;
                switch (base) {
                    .file => |path| {
                        if (!isRelativeZigPath(path)) return null;
                        const target_file = try gen.loadFile(path);
                        const decl = target_file.decls.get(selector) orelse return null;
                        return .{ .decl = .{ .file = target_file, .node = decl } };
                    },
                    .decl => |ref| return gen.resolveMemberTarget(ref, selector, depth + 1),
                }
            },
            .if_simple, .@"if" => {
                const if_expr = ast.fullIf(node) orelse return null;
                if (try gen.resolveTarget(file, if_expr.ast.then_expr, depth + 1)) |target| {
                    return target;
                }
                if (if_expr.ast.else_expr.unwrap()) |else_node| {
                    return gen.resolveTarget(file, else_node, depth + 1);
                }
                return null;
            },
            .grouped_expression => {
                const data = ast.nodeData(node).node_and_token;
                return gen.resolveTarget(file, data[0], depth + 1);
            },
            else => return null,
        }
    }

    fn resolveMemberTarget(
        gen: *Generator,
        ref: DeclRef,
        selector: []const u8,
        depth: usize,
    ) anyerror!?Target {
        if (depth > 12) return null;
        const ast = &ref.file.ast;
        switch (ast.nodeTag(ref.node)) {
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                const var_decl = ast.fullVarDecl(ref.node) orelse return null;
                const init = var_decl.ast.init_node.unwrap() orelse return null;
                if (containerKind(ast, init) != null) {
                    if (findMemberDecl(ref.file, init, selector)) |decl| {
                        return .{ .decl = decl };
                    }
                    return null;
                }
                if (try gen.resolveTarget(ref.file, init, depth + 1)) |target| {
                    switch (target) {
                        .file => |path| {
                            if (!isRelativeZigPath(path)) return null;
                            const target_file = try gen.loadFile(path);
                            const decl = target_file.decls.get(selector) orelse return null;
                            return .{ .decl = .{ .file = target_file, .node = decl } };
                        },
                        .decl => |next| return gen.resolveMemberTarget(next, selector, depth + 1),
                    }
                }
                return null;
            },
            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_decl,
            => {
                if (!returnsType(ast, ref.node)) return null;
                const container = typeFunctionContainer(ref.file, ref.node, 0) orelse return null;
                const decl = findMemberDecl(ref.file, container, selector) orelse return null;
                return .{ .decl = decl };
            },
            else => return null,
        }
    }

    /// Follow a declaration until it becomes a container, a function, a value,
    /// or a module. Alias chains are followed with a depth guard.
    fn classifyDecl(gen: *Generator, ref: DeclRef, depth: usize) anyerror!?AliasTarget {
        if (depth > 12) return null;
        const ast = &ref.file.ast;
        switch (ast.nodeTag(ref.node)) {
            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_decl,
            => {
                const docs = try docText(gen.allocator, ast, ref.node);
                if (returnsType(ast, ref.node)) {
                    return .{ .type_function = .{
                        .file = ref.file,
                        .node = ref.node,
                        .docs = docs,
                    } };
                }
                return .{ .function = .{
                    .signature = try collapsedSource(gen.allocator, ast, protoNode(ast, ref.node)),
                    .docs = docs,
                } };
            },
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                const var_decl = ast.fullVarDecl(ref.node) orelse return null;
                const docs = try docText(gen.allocator, ast, ref.node);
                if (var_decl.ast.init_node.unwrap()) |init| {
                    if (containerKind(ast, init)) |kind| {
                        return .{ .container = .{
                            .file = ref.file,
                            .node = init,
                            .kind = kind,
                            .docs = docs,
                        } };
                    }
                    if (try gen.resolveTarget(ref.file, init, depth + 1)) |target| {
                        switch (target) {
                            .file => |path| return .{ .module = .{ .path = path } },
                            .decl => |next| return gen.classifyDecl(next, depth + 1),
                        }
                    }
                }
                return .{ .value = .{ .docs = docs } };
            },
            else => return null,
        }
    }

    fn buildAlias(
        gen: *Generator,
        file: *ParsedFile,
        node: Ast.Node.Index,
        name: []const u8,
        fqn: []const u8,
        docs: []const u8,
        call_site_signature: []const u8,
        target: AliasTarget,
    ) anyerror!Node {
        var kind: Kind = .constant;
        var signature = call_site_signature;
        var children: []const Node = &.{};
        var final_docs = docs;

        switch (target) {
            .container => |container| {
                kind = container.kind;
                if (docs.len == 0) final_docs = container.docs;
                children = try gen.parseAliasMembers(container.file, container.node, fqn);
            },
            .type_function => |type_function| {
                kind = .type_function;
                if (docs.len == 0) final_docs = type_function.docs;
                if (typeFunctionContainer(type_function.file, type_function.node, 0)) |container_node| {
                    children = try gen.parseAliasMembers(type_function.file, container_node, fqn);
                }
            },
            .function => |function| {
                kind = .function;
                signature = function.signature;
                if (docs.len == 0) final_docs = function.docs;
            },
            .value => |value| {
                kind = .constant;
                if (docs.len == 0) final_docs = value.docs;
            },
            .module => |module| {
                kind = .module;
                if (isRelativeZigPath(module.path)) {
                    const child = try gen.parseFile(module.path, fqn);
                    children = child.symbols;
                    if (docs.len == 0) final_docs = child.docs;
                }
            },
        }

        return .{
            .name = name,
            .fqn = fqn,
            .kind = kind,
            .signature = signature,
            .docs = final_docs,
            .file = file.path,
            .line = sourceLine(&file.ast, node),
            .children = children,
        };
    }

    /// Resolve an import path relative to the importing file. Package imports
    /// and absolute paths stay opaque, as before.
    fn resolveImport(gen: *Generator, file_path: []const u8, import_path: []const u8) !?[]const u8 {
        if (!isRelativeZigPath(import_path)) return null;
        const dir = std.fs.path.dirname(file_path) orelse ".";
        const joined = try std.fs.path.join(gen.allocator, &.{ dir, import_path });
        const resolved = try std.fs.path.resolve(gen.allocator, &.{joined});
        return resolved;
    }
};

fn isRelativeZigPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") and !std.fs.path.isAbsolute(path);
}

fn declName(ast: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    switch (ast.nodeTag(node)) {
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&buf, node) orelse return null;
            const name_token = proto.name_token orelse return null;
            return ast.tokenSlice(name_token);
        },
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = ast.fullVarDecl(node) orelse return null;
            const name_token = var_decl.ast.mut_token + 1;
            if (ast.tokenTag(name_token) != .identifier) return null;
            return ast.tokenSlice(name_token);
        },
        else => return null,
    }
}

fn findMemberDecl(file: *ParsedFile, container_node: Ast.Node.Index, name: []const u8) ?DeclRef {
    const ast = &file.ast;
    var buf: [2]Ast.Node.Index = undefined;
    const container = ast.fullContainerDecl(&buf, container_node) orelse return null;
    for (container.ast.members) |member| {
        const member_name = declName(ast, member) orelse continue;
        if (std.mem.eql(u8, member_name, name)) {
            return .{ .file = file, .node = member };
        }
    }
    return null;
}

/// Read a package into the public model. The returned document borrows the
/// allocator; use an arena if the whole document has the same lifetime.
pub fn extract(allocator: Allocator, io: std.Io, options: ExtractOptions) !Document {
    var gen: Generator = .{
        .allocator = allocator,
        .io = io,
        .files = std.StringHashMap(*ParsedFile).init(allocator),
        .stack = .empty,
        .alias_stack = .empty,
    };
    const root_path = try std.fs.path.resolve(allocator, &.{options.root_path});
    const root = try gen.parseFile(root_path, "");

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
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
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

fn returnsType(ast: *const Ast, node: Ast.Node.Index) bool {
    if (ast.nodeTag(node) != .fn_decl) return false;
    var proto_buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&proto_buf, node) orelse return false;
    const return_node = proto.ast.return_type.unwrap() orelse return false;
    if (ast.nodeTag(return_node) != .identifier) return false;
    return std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(return_node)), "type");
}

/// Resolve the container a type function returns. Besides the direct
/// `return struct { ... };` shape, follow a named container or type function,
/// a call to a local type function, and `if`/`switch` branches.
fn typeFunctionContainer(file: *const ParsedFile, node: Ast.Node.Index, depth: usize) ?Ast.Node.Index {
    if (depth > 8) return null;
    const ast = &file.ast;
    if (ast.nodeTag(node) != .fn_decl) return null;
    if (!returnsType(ast, node)) return null;
    const body = ast.nodeData(node).node_and_node[1];
    return scanTypeStatements(file, body, depth + 1);
}

fn scanTypeStatements(file: *const ParsedFile, body: Ast.Node.Index, depth: usize) ?Ast.Node.Index {
    if (depth > 8) return null;
    const ast = &file.ast;
    var block_buf: [2]Ast.Node.Index = undefined;
    const statements = ast.blockStatements(&block_buf, body) orelse return null;
    for (statements) |statement| {
        switch (ast.nodeTag(statement)) {
            .@"return" => {
                const expression = ast.nodeData(statement).opt_node.unwrap() orelse continue;
                if (resolveTypeExpression(file, expression, depth + 1)) |container| return container;
            },
            .block,
            .block_semicolon,
            .block_two,
            .block_two_semicolon,
            => {
                if (scanTypeStatements(file, statement, depth + 1)) |container| return container;
            },
            else => {},
        }
    }
    return null;
}

fn resolveTypeExpression(file: *const ParsedFile, node: Ast.Node.Index, depth: usize) ?Ast.Node.Index {
    if (depth > 8) return null;
    const ast = &file.ast;
    if (containerKind(ast, node) != null) return node;

    switch (ast.nodeTag(node)) {
        .identifier => {
            const name = ast.tokenSlice(ast.nodeMainToken(node));
            const decl = file.decls.get(name) orelse return null;
            return typeContainerFromDecl(file, decl, depth + 1);
        },
        .call, .call_comma, .call_one, .call_one_comma => {
            const callee = callCallee(ast, node) orelse return null;
            if (ast.nodeTag(callee) != .identifier) return null;
            const name = ast.tokenSlice(ast.nodeMainToken(callee));
            const decl = file.decls.get(name) orelse return null;
            return typeFunctionContainer(file, decl, depth + 1);
        },
        .if_simple, .@"if" => {
            const if_expr = ast.fullIf(node) orelse return null;
            if (resolveTypeExpression(file, if_expr.ast.then_expr, depth + 1)) |container| {
                return container;
            }
            if (if_expr.ast.else_expr.unwrap()) |else_node| {
                return resolveTypeExpression(file, else_node, depth + 1);
            }
            return null;
        },
        .@"switch", .switch_comma => {
            const switch_expr = ast.fullSwitch(node) orelse return null;
            for (switch_expr.ast.cases) |case| {
                const full_case = ast.fullSwitchCase(case) orelse continue;
                if (resolveTypeExpression(file, full_case.ast.target_expr, depth + 1)) |container| {
                    return container;
                }
            }
            return null;
        },
        .grouped_expression => {
            const data = ast.nodeData(node).node_and_token;
            return resolveTypeExpression(file, data[0], depth + 1);
        },
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => return scanTypeStatements(file, node, depth + 1),
        else => return null,
    }
}

fn typeContainerFromDecl(file: *const ParsedFile, node: Ast.Node.Index, depth: usize) ?Ast.Node.Index {
    if (depth > 8) return null;
    const ast = &file.ast;
    switch (ast.nodeTag(node)) {
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = ast.fullVarDecl(node) orelse return null;
            const init = var_decl.ast.init_node.unwrap() orelse return null;
            if (containerKind(ast, init) != null) return init;
            return resolveTypeExpression(file, init, depth + 1);
        },
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => return typeFunctionContainer(file, node, depth + 1),
        else => return null,
    }
}

fn callCallee(ast: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    return switch (ast.nodeTag(node)) {
        .call, .call_comma => ast.nodeData(node).node_and_extra[0],
        .call_one, .call_one_comma => ast.nodeData(node).node_and_opt_node[0],
        else => null,
    };
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

fn varSignature(allocator: Allocator, ast: *const Ast, var_decl: Ast.full.VarDecl) ![]const u8 {
    const last_token = if (var_decl.ast.init_node.unwrap()) |init_node|
        ast.lastToken(init_node)
    else if (var_decl.ast.type_node.unwrap()) |type_node|
        ast.lastToken(type_node)
    else
        var_decl.ast.mut_token + 1;
    return collapsedBetween(allocator, ast, var_decl.firstToken(), last_token);
}

/// Container signatures stop at the container keyword and keep its argument:
/// `enum`, `enum(u16)`, `union`, `union(enum)`, `union(enum(u8))`.
fn containerSignature(
    allocator: Allocator,
    ast: *const Ast,
    var_decl: Ast.full.VarDecl,
    init_node: Ast.Node.Index,
) ![]const u8 {
    var buf: [2]Ast.Node.Index = undefined;
    const container = ast.fullContainerDecl(&buf, init_node) orelse
        return collapsedBetween(allocator, ast, var_decl.firstToken(), ast.lastToken(init_node));
    const head = try collapsedBetween(allocator, ast, var_decl.firstToken(), container.ast.main_token);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, head);
    if (container.ast.enum_token != null) {
        try out.appendSlice(allocator, "(enum");
        if (container.ast.arg.unwrap()) |arg| {
            try out.appendSlice(allocator, "(");
            try out.appendSlice(allocator, try collapsedSource(allocator, ast, arg));
            try out.appendSlice(allocator, ")");
        }
        try out.appendSlice(allocator, ")");
    } else if (container.ast.arg.unwrap()) |arg| {
        try out.appendSlice(allocator, "(");
        try out.appendSlice(allocator, try collapsedSource(allocator, ast, arg));
        try out.appendSlice(allocator, ")");
    }
    return out.toOwnedSlice(allocator);
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
        // Only `///` docs attach to a declaration. A `//!` block belongs to
        // the file and stays in `containerDocs`.
        if (ast.tokenTag(start - 1) != .doc_comment) break;
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
        .files = std.StringHashMap(*ParsedFile).init(arena),
        .stack = .empty,
        .alias_stack = .empty,
    };
    const file = try gen.parseSource("test.zig", source);
    const symbols = try gen.parseDecls(file, "");
    try std.testing.expectEqual(1, symbols.len);
    try std.testing.expectEqual(Kind.type_function, symbols[0].kind);
    try std.testing.expectEqual(2, symbols[0].children.len);
    try std.testing.expectEqualStrings("data", symbols[0].children[0].name);
    try std.testing.expectEqualStrings("init", symbols[0].children[1].name);
}

test "conditional import aliases resolve" {
    const source =
        \\const pages_mod = @import("pages.zig");
        \\pub const pages = if (true) pages_mod else void;
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var gen: Generator = .{
        .allocator = arena,
        .io = std.testing.io,
        .files = std.StringHashMap(*ParsedFile).init(arena),
        .stack = .empty,
        .alias_stack = .empty,
    };
    const file = try gen.parseSource("test.zig", source);

    const pages_decl = file.ast.rootDecls()[1];
    const var_decl = file.ast.fullVarDecl(pages_decl).?;
    const init = var_decl.ast.init_node.unwrap().?;
    const target = (try gen.resolveTarget(file, init, 0)).?;
    switch (target) {
        .decl => |ref| {
            const module_decl = ref.file.ast.fullVarDecl(ref.node).?;
            try std.testing.expectEqualStrings(
                "pages_mod",
                ref.file.ast.tokenSlice(module_decl.ast.mut_token + 1),
            );
        },
        .file => return error.TestUnexpectedResult,
    }
}

const fixture_root = "tests/fixtures/tiny/root.zig";
const fixture_internal = "tests/fixtures/tiny/internal.zig";
const fixture_maybe = "tests/fixtures/tiny/maybe.zig";
const fixture_tagged = "tests/fixtures/tagged/root.zig";
const fixture_signatures = "tests/fixtures/signatures/root.zig";
const fixture_chained = "tests/fixtures/chained/root.zig";
const fixture_chained_widget = "tests/fixtures/chained/widget.zig";
const fixture_alias = "tests/fixtures/alias/root.zig";
const fixture_alias_helpers = "tests/fixtures/alias/helpers.zig";
const fixture_fnvalue = "tests/fixtures/fnvalue/root.zig";
const fixture_docs = "tests/fixtures/docs/root.zig";
const fixture_dupes = "tests/fixtures/dupes/root.zig";
const fixture_dupes_shared = "tests/fixtures/dupes/shared.zig";
const fixture_cycle = "tests/fixtures/cycle/root.zig";
const fixture_cycle_a = "tests/fixtures/cycle/a.zig";
const fixture_cycle_b = "tests/fixtures/cycle/b.zig";
const fixture_typefn = "tests/fixtures/typefn/root.zig";

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
        .signature = "pub const flag = true",
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

fn extractRoot(allocator: Allocator, root: []const u8) !Document {
    return extract(allocator, std.testing.io, .{
        .root_path = root,
        .name = std.fs.path.stem(root),
    });
}

fn expectSymbols(expected: []const ExpectedSymbol, document: *const Document) !void {
    try std.testing.expectEqual(expected.len, document.symbols.len);
    for (expected, document.symbols) |want, got| {
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

    // The flattened tree must stay unique, and every parent must be the
    // immediately preceding depth.
    for (document.symbols, 0..) |symbol, i| {
        for (document.symbols[0..i]) |earlier| {
            if (std.mem.eql(u8, symbol.fqn, earlier.fqn)) return error.DuplicateFqn;
        }
        if (symbol.depth == 0) {
            try std.testing.expect(symbol.parent == null);
            continue;
        }
        const parent_fqn = symbol.parent orelse return error.MissingParent;
        var found = false;
        for (document.symbols[0..i]) |earlier| {
            if (!std.mem.eql(u8, earlier.fqn, parent_fqn)) continue;
            try std.testing.expectEqual(symbol.depth - 1, earlier.depth);
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
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

const expected_tagged = [_]ExpectedSymbol{
    .{
        .name = "Two",
        .fqn = "Two",
        .kind = .@"union",
        .depth = 0,
        .parent = null,
        .signature = "pub const Two = union(enum)",
        .docs = "A two-variant tagged union.\n",
        .file = fixture_tagged,
        .line = 4,
    },
    .{
        .name = "number",
        .fqn = "Two.number",
        .kind = .field,
        .depth = 1,
        .parent = "Two",
        .signature = "number: u32",
        .docs = "A number.\n",
        .file = fixture_tagged,
        .line = 6,
    },
    .{
        .name = "name",
        .fqn = "Two.name",
        .kind = .field,
        .depth = 1,
        .parent = "Two",
        .signature = "name: []const u8",
        .docs = "A name.\n",
        .file = fixture_tagged,
        .line = 8,
    },
    .{
        .name = "ByTag",
        .fqn = "ByTag",
        .kind = .@"union",
        .depth = 0,
        .parent = null,
        .signature = "pub const ByTag = union(enum(u8))",
        .docs = "A byte-tagged union.\n",
        .file = fixture_tagged,
        .line = 12,
    },
    .{
        .name = "a",
        .fqn = "ByTag.a",
        .kind = .field,
        .depth = 1,
        .parent = "ByTag",
        .signature = "a: u8",
        .docs = "",
        .file = fixture_tagged,
        .line = 13,
    },
    .{
        .name = "b",
        .fqn = "ByTag.b",
        .kind = .field,
        .depth = 1,
        .parent = "ByTag",
        .signature = "b: u8",
        .docs = "",
        .file = fixture_tagged,
        .line = 14,
    },
    .{
        .name = "Plain",
        .fqn = "Plain",
        .kind = .@"union",
        .depth = 0,
        .parent = null,
        .signature = "pub const Plain = union",
        .docs = "A plain union.\n",
        .file = fixture_tagged,
        .line = 18,
    },
    .{
        .name = "int",
        .fqn = "Plain.int",
        .kind = .field,
        .depth = 1,
        .parent = "Plain",
        .signature = "int: i32",
        .docs = "",
        .file = fixture_tagged,
        .line = 19,
    },
    .{
        .name = "float",
        .fqn = "Plain.float",
        .kind = .field,
        .depth = 1,
        .parent = "Plain",
        .signature = "float: f32",
        .docs = "",
        .file = fixture_tagged,
        .line = 20,
    },
    .{
        .name = "Ops",
        .fqn = "Ops",
        .kind = .@"struct",
        .depth = 0,
        .parent = null,
        .signature = "pub const Ops = struct",
        .docs = "A container with a nested tagged union.\n",
        .file = fixture_tagged,
        .line = 24,
    },
    .{
        .name = "Variant",
        .fqn = "Ops.Variant",
        .kind = .@"union",
        .depth = 1,
        .parent = "Ops",
        .signature = "pub const Variant = union(enum)",
        .docs = "",
        .file = fixture_tagged,
        .line = 25,
    },
    .{
        .name = "one",
        .fqn = "Ops.Variant.one",
        .kind = .field,
        .depth = 2,
        .parent = "Ops.Variant",
        .signature = "one: void",
        .docs = "",
        .file = fixture_tagged,
        .line = 26,
    },
    .{
        .name = "two",
        .fqn = "Ops.Variant.two",
        .kind = .field,
        .depth = 2,
        .parent = "Ops.Variant",
        .signature = "two: void",
        .docs = "",
        .file = fixture_tagged,
        .line = 27,
    },
    .{
        .name = "Kind",
        .fqn = "Kind",
        .kind = .@"enum",
        .depth = 0,
        .parent = null,
        .signature = "pub const Kind = enum(u16)",
        .docs = "A backed enum.\n",
        .file = fixture_tagged,
        .line = 32,
    },
    .{
        .name = "small",
        .fqn = "Kind.small",
        .kind = .field,
        .depth = 1,
        .parent = "Kind",
        .signature = "small",
        .docs = "",
        .file = fixture_tagged,
        .line = 33,
    },
    .{
        .name = "large",
        .fqn = "Kind.large",
        .kind = .field,
        .depth = 1,
        .parent = "Kind",
        .signature = "large",
        .docs = "",
        .file = fixture_tagged,
        .line = 34,
    },
};

test "tagged unions expand fields and keep the tag argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const document = try extractRoot(arena_state.allocator(), fixture_tagged);
    try expectSymbols(&expected_tagged, &document);
}

const expected_signatures = [_]ExpectedSymbol{
    .{
        .name = "default_port",
        .fqn = "default_port",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const default_port: u16 = 8080",
        .docs = "A port with an explicit type.\n",
        .file = fixture_signatures,
        .line = 4,
    },
    .{
        .name = "DefaultPort",
        .fqn = "DefaultPort",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const DefaultPort = 8080",
        .docs = "An inferred integer.\n",
        .file = fixture_signatures,
        .line = 6,
    },
    .{
        .name = "Handler",
        .fqn = "Handler",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const Handler = *const fn () void",
        .docs = "A callback type.\n",
        .file = fixture_signatures,
        .line = 8,
    },
    .{
        .name = "ParseError",
        .fqn = "ParseError",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const ParseError = error{ UnexpectedEof, InvalidLength, }",
        .docs = "An error set.\n",
        .file = fixture_signatures,
        .line = 10,
    },
    .{
        .name = "Clamped",
        .fqn = "Clamped",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const Clamped = @min(300, max_port)",
        .docs = "A call initializer.\n",
        .file = fixture_signatures,
        .line = 15,
    },
    .{
        .name = "max_port",
        .fqn = "max_port",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const max_port = 1024",
        .docs = "A forward value.\n",
        .file = fixture_signatures,
        .line = 17,
    },
    .{
        .name = "counter",
        .fqn = "counter",
        .kind = .variable,
        .depth = 0,
        .parent = null,
        .signature = "pub var counter: u32 = 0",
        .docs = "A mutable counter.\n",
        .file = fixture_signatures,
        .line = 20,
    },
    .{
        .name = "std_pkg",
        .fqn = "std_pkg",
        .kind = .module,
        .depth = 0,
        .parent = null,
        .signature = "pub const std_pkg = @import(\"std\")",
        .docs = "A package import.\n",
        .file = fixture_signatures,
        .line = 23,
    },
};

test "constant signatures keep their type and initializer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const document = try extractRoot(arena_state.allocator(), fixture_signatures);
    try expectSymbols(&expected_signatures, &document);
}

const expected_chained = [_]ExpectedSymbol{
    .{
        .name = "Widget",
        .fqn = "Widget",
        .kind = .@"struct",
        .depth = 0,
        .parent = null,
        .signature = "pub const Widget = @import(\"widget.zig\").Widget",
        .docs = "A widget.\n",
        .file = fixture_chained,
        .line = 3,
    },
    .{
        .name = "id",
        .fqn = "Widget.id",
        .kind = .field,
        .depth = 1,
        .parent = "Widget",
        .signature = "id: u32",
        .docs = "Identifier.\n",
        .file = fixture_chained_widget,
        .line = 6,
    },
    .{
        .name = "init",
        .fqn = "Widget.init",
        .kind = .function,
        .depth = 1,
        .parent = "Widget",
        .signature = "pub fn init(id: u32) Widget",
        .docs = "Make one.\n",
        .file = fixture_chained_widget,
        .line = 9,
    },
};

test "chained imports resolve the selected declaration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const document = try extractRoot(arena_state.allocator(), fixture_chained);
    try expectSymbols(&expected_chained, &document);
}

const expected_alias = [_]ExpectedSymbol{
    .{
        .name = "Widget",
        .fqn = "Widget",
        .kind = .@"struct",
        .depth = 0,
        .parent = null,
        .signature = "pub const Widget = helpers.Widget",
        .docs = "A forwarded widget.\n",
        .file = fixture_alias,
        .line = 9,
    },
    .{
        .name = "id",
        .fqn = "Widget.id",
        .kind = .field,
        .depth = 1,
        .parent = "Widget",
        .signature = "id: u32",
        .docs = "Identifier.\n",
        .file = fixture_alias_helpers,
        .line = 4,
    },
    .{
        .name = "Deep",
        .fqn = "Deep",
        .kind = .@"struct",
        .depth = 0,
        .parent = null,
        .signature = "pub const Deep = helpers.Sub",
        .docs = "A forwarded nested type.\n",
        .file = fixture_alias,
        .line = 11,
    },
    .{
        .name = "value",
        .fqn = "Deep.value",
        .kind = .field,
        .depth = 1,
        .parent = "Deep",
        .signature = "value: u8",
        .docs = "Value.\n",
        .file = fixture_alias_helpers,
        .line = 10,
    },
    .{
        .name = "Forward",
        .fqn = "Forward",
        .kind = .@"struct",
        .depth = 0,
        .parent = null,
        .signature = "pub const Forward = Later",
        .docs = "Forward reference to a local container.\n",
        .file = fixture_alias,
        .line = 13,
    },
    .{
        .name = "flag",
        .fqn = "Forward.flag",
        .kind = .field,
        .depth = 1,
        .parent = "Forward",
        .signature = "flag: bool",
        .docs = "A flag.\n",
        .file = fixture_alias,
        .line = 26,
    },
    .{
        .name = "atoi",
        .fqn = "atoi",
        .kind = .function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn atoi(text: []const u8) !u32",
        .docs = "A function value.\n",
        .file = fixture_alias,
        .line = 15,
    },
    .{
        .name = "isOption",
        .fqn = "isOption",
        .kind = .function,
        .depth = 0,
        .parent = null,
        .signature = "fn isOptionImpl(arg: []const u8) bool",
        .docs = "A same-file function value.\n",
        .file = fixture_alias,
        .line = 17,
    },
    .{
        .name = "empty",
        .fqn = "empty",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const empty = values.empty",
        .docs = "A value alias.\n",
        .file = fixture_alias,
        .line = 19,
    },
    .{
        .name = "ParseError",
        .fqn = "ParseError",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const ParseError = errors.ParseError",
        .docs = "An error alias.\n",
        .file = fixture_alias,
        .line = 21,
    },
    .{
        .name = "Later",
        .fqn = "Later",
        .kind = .@"struct",
        .depth = 0,
        .parent = null,
        .signature = "pub const Later = struct",
        .docs = "A later local container.\n",
        .file = fixture_alias,
        .line = 24,
    },
    .{
        .name = "flag",
        .fqn = "Later.flag",
        .kind = .field,
        .depth = 1,
        .parent = "Later",
        .signature = "flag: bool",
        .docs = "A flag.\n",
        .file = fixture_alias,
        .line = 26,
    },
};

test "local aliases keep the call site and copy the target members" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const document = try extractRoot(arena_state.allocator(), fixture_alias);
    try expectSymbols(&expected_alias, &document);
}

const expected_fnvalue = [_]ExpectedSymbol{
    .{
        .name = "clamp",
        .fqn = "clamp",
        .kind = .function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn clamp(value: u32, low: u32, high: u32) u32",
        .docs = "A function value from another module.\n",
        .file = fixture_fnvalue,
        .line = 6,
    },
    .{
        .name = "twice",
        .fqn = "twice",
        .kind = .function,
        .depth = 0,
        .parent = null,
        .signature = "fn twiceImpl(value: u32) u32",
        .docs = "A function value from this module.\n",
        .file = fixture_fnvalue,
        .line = 8,
    },
};

test "function values use the callee signature" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const document = try extractRoot(arena_state.allocator(), fixture_fnvalue);
    try expectSymbols(&expected_fnvalue, &document);
}

const expected_docs = [_]ExpectedSymbol{
    .{
        .name = "first",
        .fqn = "first",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const first = 1",
        .docs = "Real doc for first.\n",
        .file = fixture_docs,
        .line = 5,
    },
    .{
        .name = "second",
        .fqn = "second",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const second = 2",
        .docs = "",
        .file = fixture_docs,
        .line = 6,
    },
    .{
        .name = "third",
        .fqn = "third",
        .kind = .constant,
        .depth = 0,
        .parent = null,
        .signature = "pub const third = 3",
        .docs = "Real doc for third.\n",
        .file = fixture_docs,
        .line = 9,
    },
};

test "module docs stay at module level" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const document = try extractRoot(arena_state.allocator(), fixture_docs);
    try std.testing.expectEqualStrings("Module docs.\nSecond line.\n", document.module_docs);
    try expectSymbols(&expected_docs, &document);
}

const expected_dupes = [_]ExpectedSymbol{
    .{
        .name = "a",
        .fqn = "a",
        .kind = .module,
        .depth = 0,
        .parent = null,
        .signature = "pub const a = @import(\"shared.zig\")",
        .docs = "Shared module.\n",
        .file = fixture_dupes,
        .line = 3,
    },
    .{
        .name = "Thing",
        .fqn = "a.Thing",
        .kind = .@"struct",
        .depth = 1,
        .parent = "a",
        .signature = "pub const Thing = struct",
        .docs = "A shared thing.\n",
        .file = fixture_dupes_shared,
        .line = 4,
    },
    .{
        .name = "x",
        .fqn = "a.Thing.x",
        .kind = .field,
        .depth = 2,
        .parent = "a.Thing",
        .signature = "x: u8",
        .docs = "",
        .file = fixture_dupes_shared,
        .line = 5,
    },
    .{
        .name = "b",
        .fqn = "b",
        .kind = .module,
        .depth = 0,
        .parent = null,
        .signature = "pub const b = @import(\"shared.zig\")",
        .docs = "Shared module.\n",
        .file = fixture_dupes,
        .line = 4,
    },
    .{
        .name = "Thing",
        .fqn = "b.Thing",
        .kind = .@"struct",
        .depth = 1,
        .parent = "b",
        .signature = "pub const Thing = struct",
        .docs = "A shared thing.\n",
        .file = fixture_dupes_shared,
        .line = 4,
    },
    .{
        .name = "x",
        .fqn = "b.Thing.x",
        .kind = .field,
        .depth = 2,
        .parent = "b.Thing",
        .signature = "x: u8",
        .docs = "",
        .file = fixture_dupes_shared,
        .line = 5,
    },
};

test "two aliases of one file both expand" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const document = try extractRoot(arena_state.allocator(), fixture_dupes);
    try expectSymbols(&expected_dupes, &document);
}

const expected_cycle = [_]ExpectedSymbol{
    .{
        .name = "a",
        .fqn = "a",
        .kind = .module,
        .depth = 0,
        .parent = null,
        .signature = "pub const a = @import(\"a.zig\")",
        .docs = "Module a.\n",
        .file = fixture_cycle,
        .line = 3,
    },
    .{
        .name = "b",
        .fqn = "a.b",
        .kind = .module,
        .depth = 1,
        .parent = "a",
        .signature = "pub const b = @import(\"b.zig\")",
        .docs = "Module b.\n",
        .file = fixture_cycle_a,
        .line = 2,
    },
    .{
        .name = "a",
        .fqn = "a.b.a",
        .kind = .module,
        .depth = 2,
        .parent = "a.b",
        .signature = "pub const a = @import(\"a.zig\")",
        .docs = "",
        .file = fixture_cycle_b,
        .line = 2,
    },
    .{
        .name = "b",
        .fqn = "b",
        .kind = .module,
        .depth = 0,
        .parent = null,
        .signature = "pub const b = @import(\"b.zig\")",
        .docs = "Module b.\n",
        .file = fixture_cycle,
        .line = 4,
    },
    .{
        .name = "a",
        .fqn = "b.a",
        .kind = .module,
        .depth = 1,
        .parent = "b",
        .signature = "pub const a = @import(\"a.zig\")",
        .docs = "Module a.\n",
        .file = fixture_cycle_b,
        .line = 2,
    },
    .{
        .name = "b",
        .fqn = "b.a.b",
        .kind = .module,
        .depth = 2,
        .parent = "b.a",
        .signature = "pub const b = @import(\"b.zig\")",
        .docs = "",
        .file = fixture_cycle_a,
        .line = 2,
    },
};

test "a cycle terminates at one empty back edge" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const document = try extractRoot(arena_state.allocator(), fixture_cycle);
    try expectSymbols(&expected_cycle, &document);
}

const expected_typefn = [_]ExpectedSymbol{
    .{
        .name = "Alloc",
        .fqn = "Alloc",
        .kind = .type_function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn Alloc(comptime n: usize) type",
        .docs = "A sized buffer.\n",
        .file = fixture_typefn,
        .line = 4,
    },
    .{
        .name = "len",
        .fqn = "Alloc.len",
        .kind = .field,
        .depth = 1,
        .parent = "Alloc",
        .signature = "len: usize",
        .docs = "Length.\n",
        .file = fixture_typefn,
        .line = 7,
    },
    .{
        .name = "Buffer",
        .fqn = "Buffer",
        .kind = .type_function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn Buffer(comptime n: usize) type",
        .docs = "A buffer through a call.\n",
        .file = fixture_typefn,
        .line = 12,
    },
    .{
        .name = "len",
        .fqn = "Buffer.len",
        .kind = .field,
        .depth = 1,
        .parent = "Buffer",
        .signature = "len: usize",
        .docs = "Length.\n",
        .file = fixture_typefn,
        .line = 7,
    },
    .{
        .name = "Named",
        .fqn = "Named",
        .kind = .type_function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn Named(comptime T: type) type",
        .docs = "A named container.\n",
        .file = fixture_typefn,
        .line = 17,
    },
    .{
        .name = "id",
        .fqn = "Named.id",
        .kind = .field,
        .depth = 1,
        .parent = "Named",
        .signature = "id: u32",
        .docs = "Identifier.\n",
        .file = fixture_typefn,
        .line = 52,
    },
    .{
        .name = "Conditional",
        .fqn = "Conditional",
        .kind = .type_function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn Conditional(comptime flag: bool) type",
        .docs = "A conditional container.\n",
        .file = fixture_typefn,
        .line = 22,
    },
    .{
        .name = "id",
        .fqn = "Conditional.id",
        .kind = .field,
        .depth = 1,
        .parent = "Conditional",
        .signature = "id: u32",
        .docs = "Identifier.\n",
        .file = fixture_typefn,
        .line = 52,
    },
    .{
        .name = "Switched",
        .fqn = "Switched",
        .kind = .type_function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn Switched(comptime value: u8) type",
        .docs = "A switched container.\n",
        .file = fixture_typefn,
        .line = 27,
    },
    .{
        .name = "id",
        .fqn = "Switched.id",
        .kind = .field,
        .depth = 1,
        .parent = "Switched",
        .signature = "id: u32",
        .docs = "Identifier.\n",
        .file = fixture_typefn,
        .line = 52,
    },
    .{
        .name = "Nested",
        .fqn = "Nested",
        .kind = .type_function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn Nested(comptime n: usize) type",
        .docs = "A nested block.\n",
        .file = fixture_typefn,
        .line = 35,
    },
    .{
        .name = "count",
        .fqn = "Nested.count",
        .kind = .field,
        .depth = 1,
        .parent = "Nested",
        .signature = "count: usize",
        .docs = "Nested field.\n",
        .file = fixture_typefn,
        .line = 39,
    },
    .{
        .name = "Unresolved",
        .fqn = "Unresolved",
        .kind = .type_function,
        .depth = 0,
        .parent = null,
        .signature = "pub fn Unresolved(comptime x: usize) type",
        .docs = "A type function we cannot expand.\n",
        .file = fixture_typefn,
        .line = 45,
    },
    .{
        .name = "Item",
        .fqn = "Item",
        .kind = .@"struct",
        .depth = 0,
        .parent = null,
        .signature = "pub const Item = struct",
        .docs = "The item.\n",
        .file = fixture_typefn,
        .line = 50,
    },
    .{
        .name = "id",
        .fqn = "Item.id",
        .kind = .field,
        .depth = 1,
        .parent = "Item",
        .signature = "id: u32",
        .docs = "Identifier.\n",
        .file = fixture_typefn,
        .line = 52,
    },
    .{
        .name = "Other",
        .fqn = "Other",
        .kind = .@"struct",
        .depth = 0,
        .parent = null,
        .signature = "pub const Other = struct",
        .docs = "Another item.\n",
        .file = fixture_typefn,
        .line = 56,
    },
    .{
        .name = "name",
        .fqn = "Other.name",
        .kind = .field,
        .depth = 1,
        .parent = "Other",
        .signature = "name: []const u8",
        .docs = "Name.\n",
        .file = fixture_typefn,
        .line = 58,
    },
};

test "type functions follow named, called, and conditional returns" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const document = try extractRoot(arena_state.allocator(), fixture_typefn);
    try expectSymbols(&expected_typefn, &document);
}
