const std = @import("std");
const docgen = @import("docgen");

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
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    var root_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var repo_url: []const u8 = "";
    var rev: []const u8 = "main";
    var format: docgen.Format = .html;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "--root")) {
            root_path = args.next() orelse return usageError("--root needs a value");
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_dir = args.next() orelse return usageError("--out needs a value");
        } else if (std.mem.eql(u8, arg, "--title")) {
            title = args.next() orelse return usageError("--title needs a value");
        } else if (std.mem.eql(u8, arg, "--repo-url")) {
            repo_url = args.next() orelse return usageError("--repo-url needs a value");
        } else if (std.mem.eql(u8, arg, "--rev")) {
            rev = args.next() orelse return usageError("--rev needs a value");
        } else if (std.mem.eql(u8, arg, "--format")) {
            const value = args.next() orelse return usageError("--format needs a value");
            if (std.mem.eql(u8, value, "html")) {
                format = .html;
            } else if (std.mem.eql(u8, value, "json")) {
                format = .json;
            } else {
                std.debug.print("unknown format: {s}\n\n{s}", .{ value, usage });
                return error.BadArgs;
            }
        } else {
            std.debug.print("unknown argument: {s}\n\n{s}", .{ arg, usage });
            return error.BadArgs;
        }
    }

    const root = root_path orelse return usageError("--root is required");
    const out = out_dir orelse return usageError("--out is required");
    const package_name = title orelse std.fs.path.stem(root);

    const result = try docgen.generate(allocator, init.io, .{
        .root_path = root,
        .out_dir = out,
        .title = package_name,
        .repo_url = repo_url,
        .rev = rev,
        .format = format,
    });
    var buf: [1024]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "wrote {s} ({d} symbols)\n", .{
        result.out_path, result.symbols,
    });
    try std.Io.File.stdout().writeStreamingAll(init.io, message);
}

fn usageError(message: []const u8) error{BadArgs} {
    std.debug.print("{s}\n\n{s}", .{ message, usage });
    return error.BadArgs;
}

test {
    _ = docgen;
}
