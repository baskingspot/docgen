const std = @import("std");
const autodoc = @import("autodoc");

const usage =
    \\Usage: autodoc --root PATH --out DIR [options]
    \\
    \\Generate a static HTML API reference from a Zig package.
    \\
    \\Options:
    \\  --root PATH      Root source file, for example src/root.zig
    \\  --out DIR        Directory for index.html
    \\  --title TEXT     Page title (default: the root file stem)
    \\  --repo-url URL   Repository URL for source links
    \\  --rev REF        Commit or branch for source links (default: main)
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
        } else {
            std.debug.print("unknown argument: {s}\n\n{s}", .{ arg, usage });
            return error.BadArgs;
        }
    }

    const root = root_path orelse return usageError("--root is required");
    const out = out_dir orelse return usageError("--out is required");
    const page_title = title orelse std.fs.path.stem(root);

    const result = try autodoc.generate(allocator, init.io, .{
        .root_path = root,
        .out_dir = out,
        .title = page_title,
        .repo_url = repo_url,
        .rev = rev,
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
    _ = autodoc;
}
