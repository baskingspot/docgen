//! The docgen command-line interface: parse the flags, then read and write
//! through the `docgen` library.

const std = @import("std");
const cli = @import("cli");
const docgen = @import("docgen");
const stdx = @import("stdx");

const usage =
    \\Usage: docgen --root PATH --out DIR [options]
    \\
    \\Generate a static API reference from a Zig package.
    \\
    \\Options:
    \\  --root PATH      Root source file, for example src/root.zig
    \\  --out DIR        Directory for index.html or api.json
    \\  --title TEXT     Package name and page title (default: the root file stem)
    \\  --repo-url URL   Repository URL for source links
    \\  --rev REF        Commit or branch for source links (default: main)
    \\  --format FORMAT  Output format: html or json (default: html)
    \\  -h, --help       Show this help
    \\  --version        Show the version
    \\
;

/// Report through the same buffered stream as the rest of the CLI. The parse
/// error the library logs names the file, line, and column; wrapping it here
/// keeps the failure to one line and keeps Zig's default log prefix off it.
pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    stdx.stdio.err.print("docgen: " ++ format ++ "\n", args);
}

const Config = struct {
    root: []const u8,
    out: []const u8,
    title: ?[]const u8 = null,
    repo_url: []const u8 = "",
    rev: []const u8 = "main",
    format: docgen.Format = .html,
};

const UsageError = union(enum) {
    missing_value: cli.Option,
    unknown_option: cli.Option,
    unexpected_argument: []const u8,
    unknown_format: []const u8,
    missing_root,
    missing_out,

    pub fn format(self: UsageError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .missing_value => |opt| try writer.print("{f} needs a value", .{opt}),
            .unknown_option => |opt| try writer.print("unknown option '{f}'", .{opt}),
            .unexpected_argument => |arg| try writer.print("unexpected argument '{s}'", .{arg}),
            .unknown_format => |value| try writer.print(
                "unknown format '{s}' (expected html or json)",
                .{value},
            ),
            .missing_root => try writer.writeAll("--root is required"),
            .missing_out => try writer.writeAll("--out is required"),
        }
    }
};

const ParseResult = union(enum) {
    run: Config,
    help,
    version,
    invalid: UsageError,
};

/// Classify the cursor into one action. Kept separate from `main` so the
/// grammar is testable with `cli.Args.fromSlice`.
fn parse(args: *cli.Args) ParseResult {
    var root: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var repo_url: []const u8 = "";
    var rev: []const u8 = "main";
    var format: docgen.Format = .html;

    while (args.next()) |token| switch (token) {
        .positional => |arg| return .{ .invalid = .{ .unexpected_argument = arg } },
        .option => |opt| {
            if (opt.isSwitch("help", 'h')) {
                return .help;
            } else if (opt.isSwitch("version", null)) {
                return .version;
            } else if (opt.is("root", null)) {
                root = args.takeValue(opt) orelse
                    return .{ .invalid = .{ .missing_value = opt } };
            } else if (opt.is("out", null)) {
                out = args.takeValue(opt) orelse
                    return .{ .invalid = .{ .missing_value = opt } };
            } else if (opt.is("title", null)) {
                title = args.takeValue(opt) orelse
                    return .{ .invalid = .{ .missing_value = opt } };
            } else if (opt.is("repo-url", null)) {
                repo_url = args.takeValue(opt) orelse
                    return .{ .invalid = .{ .missing_value = opt } };
            } else if (opt.is("rev", null)) {
                rev = args.takeValue(opt) orelse
                    return .{ .invalid = .{ .missing_value = opt } };
            } else if (opt.is("format", null)) {
                const value = args.takeValue(opt) orelse
                    return .{ .invalid = .{ .missing_value = opt } };
                format = std.meta.stringToEnum(docgen.Format, value) orelse
                    return .{ .invalid = .{ .unknown_format = value } };
            } else {
                return .{ .invalid = .{ .unknown_option = opt } };
            }
        },
    };

    const root_path = root orelse return .{ .invalid = .missing_root };
    const out_dir = out orelse return .{ .invalid = .missing_out };
    return .{ .run = .{
        .root = root_path,
        .out = out_dir,
        .title = title,
        .repo_url = repo_url,
        .rev = rev,
        .format = format,
    } };
}

pub fn main(init: std.process.Init) u8 {
    defer stdx.stdio.flush();

    const allocator = init.arena.allocator();
    var args = cli.Args.initAllocator(init.minimal.args, allocator) catch |err| {
        stdx.stdio.err.print("docgen: cannot read arguments: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer args.deinit();

    switch (parse(&args)) {
        .help => {
            stdx.stdio.out.writeAll(usage);
            return 0;
        },
        .version => {
            stdx.stdio.out.print("{s} {s}\n", .{
                docgen.model.generator_name,
                docgen.model.generator_version,
            });
            return 0;
        },
        .invalid => |err| {
            stdx.stdio.err.print("docgen: {f}\n\n{s}", .{ err, usage });
            return 2;
        },
        .run => |config| return run(allocator, init.io, config),
    }
}

fn run(allocator: std.mem.Allocator, io: std.Io, config: Config) u8 {
    const title = config.title orelse std.fs.path.stem(config.root);

    // Do the phases here instead of calling `docgen.generate` so a failure can
    // name the path that produced it: the root file for reads and parsing, and
    // the output file for writes.
    const document = docgen.extract(allocator, io, .{
        .root_path = config.root,
        .name = title,
        .repo_url = config.repo_url,
        .rev = config.rev,
    }) catch |err| {
        // The library already logged the file, line, and column for a parse
        // error through `logFn`.
        if (err == error.ParseError) return 1;
        return fail(config.root, err);
    };

    const output = switch (config.format) {
        .html => docgen.renderHtml(allocator, &document),
        .json => docgen.writeJson(allocator, &document),
    } catch |err| return fail("render", err);

    std.Io.Dir.cwd().createDirPath(io, config.out) catch |err| return fail(config.out, err);
    const out_path = std.fs.path.join(allocator, &.{
        config.out,
        config.format.fileName(),
    }) catch |err| return fail(config.out, err);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = output }) catch |err|
        return fail(out_path, err);

    stdx.stdio.out.print("wrote {s} ({d} symbols)\n", .{ out_path, document.symbols.len });
    return 0;
}

fn fail(path: []const u8, err: anyerror) u8 {
    stdx.stdio.err.print("docgen: {s}: {s}\n", .{ path, @errorName(err) });
    return 1;
}

fn expectTag(expected: std.meta.Tag(ParseResult), result: ParseResult) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(result));
}

fn expectRun(result: ParseResult) !Config {
    return switch (result) {
        .run => |config| config,
        else => error.TestUnexpectedResult,
    };
}

fn expectMessage(expected: []const u8, err: UsageError) !void {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try err.format(&writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "defaults apply when only the required flags are set" {
    var args: cli.Args = .fromSlice(&.{ "--root", "src/root.zig", "--out", "zig-out/docs" });
    const config = try expectRun(parse(&args));
    try std.testing.expectEqualStrings("src/root.zig", config.root);
    try std.testing.expectEqualStrings("zig-out/docs", config.out);
    try std.testing.expectEqual(@as(?[]const u8, null), config.title);
    try std.testing.expectEqualStrings("", config.repo_url);
    try std.testing.expectEqualStrings("main", config.rev);
    try std.testing.expectEqual(docgen.Format.html, config.format);
}

test "every flag parses, including --format json" {
    var args: cli.Args = .fromSlice(&.{
        "--root",     "src/root.zig",
        "--out",      "zig-out/api",
        "--title",    "mylib",
        "--repo-url", "https://github.com/baskingspot/mylib",
        "--rev",      "v1.2.3",
        "--format",   "json",
    });
    const config = try expectRun(parse(&args));
    try std.testing.expectEqualStrings("src/root.zig", config.root);
    try std.testing.expectEqualStrings("zig-out/api", config.out);
    try std.testing.expectEqualStrings("mylib", config.title orelse "");
    try std.testing.expectEqualStrings(
        "https://github.com/baskingspot/mylib",
        config.repo_url,
    );
    try std.testing.expectEqualStrings("v1.2.3", config.rev);
    try std.testing.expectEqual(docgen.Format.json, config.format);
}

test "--name=value forms parse like separate values" {
    var args: cli.Args = .fromSlice(&.{
        "--root=src/root.zig",
        "--out=zig-out/api",
        "--title=mylib",
        "--repo-url=https://example.com/mylib",
        "--rev=dev",
        "--format=json",
    });
    const config = try expectRun(parse(&args));
    try std.testing.expectEqualStrings("src/root.zig", config.root);
    try std.testing.expectEqualStrings("zig-out/api", config.out);
    try std.testing.expectEqualStrings("mylib", config.title orelse "");
    try std.testing.expectEqualStrings("https://example.com/mylib", config.repo_url);
    try std.testing.expectEqualStrings("dev", config.rev);
    try std.testing.expectEqual(docgen.Format.json, config.format);
}

test "help and version short-circuit the required flags" {
    var short_help: cli.Args = .fromSlice(&.{"-h"});
    try expectTag(.help, parse(&short_help));

    var long_help: cli.Args = .fromSlice(&.{"--help"});
    try expectTag(.help, parse(&long_help));

    var version: cli.Args = .fromSlice(&.{"--version"});
    try expectTag(.version, parse(&version));
}

test "unknown flags are usage errors" {
    var args: cli.Args = .fromSlice(&.{ "--root", "src/root.zig", "--bogus" });
    const result = parse(&args);
    try expectTag(.invalid, result);
    try expectMessage("unknown option '--bogus'", result.invalid);
}

test "a missing value is a usage error naming the option" {
    var args: cli.Args = .fromSlice(&.{"--root"});
    const result = parse(&args);
    try expectTag(.invalid, result);
    try expectMessage("--root needs a value", result.invalid);
}

test "required flags and positionals are usage errors" {
    var missing_root: cli.Args = .fromSlice(&.{ "--out", "zig-out/docs" });
    const no_root = parse(&missing_root);
    try expectTag(.invalid, no_root);
    try expectMessage("--root is required", no_root.invalid);

    var missing_out: cli.Args = .fromSlice(&.{ "--root", "src/root.zig" });
    const no_out = parse(&missing_out);
    try expectTag(.invalid, no_out);
    try expectMessage("--out is required", no_out.invalid);

    var positional: cli.Args = .fromSlice(&.{"src/root.zig"});
    const unexpected = parse(&positional);
    try expectTag(.invalid, unexpected);
    try expectMessage("unexpected argument 'src/root.zig'", unexpected.invalid);
}

test "an unknown format is a usage error" {
    var args: cli.Args = .fromSlice(&.{
        "--root",   "src/root.zig",
        "--out",    "zig-out/api",
        "--format", "bogus",
    });
    const result = parse(&args);
    try expectTag(.invalid, result);
    try expectMessage("unknown format 'bogus' (expected html or json)", result.invalid);
}
