# autodoc

Static HTML API documentation for a Zig package. Point it at a root source
file; it writes one `index.html` with the public declarations, their doc
comments, and links to the source on GitHub.

This is a POC. It reads Zig syntax with `std.zig.Ast`. It does not use the
compiler's WebAssembly docs viewer, and it ships no JavaScript or
`sources.tar`.

## Use

`nix develop` provides Zig 0.16 and the tools.

```sh
zig build run -- --root src/root.zig --out zig-out/docs --title mylib \
  --repo-url https://github.com/baskingspot/mylib --rev main
```

`just doc` builds the reference for this repository into `zig-out/docs`.
`just serve` serves it at <http://127.0.0.1:8000>. Set `PORT` to change the port:
`PORT=9000 just serve`.

### Document another repository

The command above runs from this repository, so it documents this
repository. Build the binary once, then run it from the checkout you want to
document:

```sh
cd ~/code/baskingspot/autodoc
zig build

cd ~/code/baskingspot/stdx
../autodoc/zig-out/bin/autodoc \
  --root src/root.zig \
  --out /tmp/stdx-api \
  --title stdx \
  --repo-url https://github.com/baskingspot/stdx \
  --rev main
```

Open `/tmp/stdx-api/index.html` directly, or serve the directory with
`python3 -m http.server -b 127.0.0.1 -d /tmp/stdx-api 8000`. Run from the
target repository root so `--root` and the GitHub source paths are relative
to that repository.

## Build integration

Add autodoc as a dependency, then run its artifact as a build step:

```zig
const autodoc_dep = b.dependency("autodoc", .{});
const autodoc = autodoc_dep.artifact("autodoc");

const docs = b.addRunArtifact(autodoc);
docs.addArgs(&.{
    "--root",     "src/root.zig",
    "--title",    "mylib",
    "--repo-url", "https://github.com/baskingspot/mylib",
    "--rev",      "main",
    "--out",
});
const api = docs.addOutputDirectoryArg("api");
const install = b.addInstallDirectory(.{
    .source_dir = api,
    .install_dir = .prefix,
    .install_subdir = "docs",
});
const docs_step = b.step("docs", "Generate the API reference");
docs_step.dependOn(&install.step);
```

`--out` comes immediately before the output directory. `addOutputDirectoryArg`
creates that directory and gives the install step a `LazyPath`.

## What it does

- Follows relative `@import("file.zig")` declarations and conditional
  aliases such as `pub const pages = if (...) pages_mod else void;`.
- Collects `pub` declarations and public container members.
- Renders doc comments as paragraphs, headings, and inline code.
- Writes one page with an inline stylesheet. The page makes no network
  requests.

On stdx, run from the stdx checkout with `--root src/root.zig`, it writes
527 sections in 269 KB. Gzipped, the page is 42 KB.

## Limits

- It is an AST reader. It does not resolve types or type aliases; import
  aliases are followed.
- It expands a generic type function when the body directly returns a
  container, such as `pub fn Array(comptime len: usize) type { return struct { ... }; }`.
  It does not follow a return that names another type, a call, or a
  conditional.
- It follows relative imports only. Imports of packages (`@import("std")`,
  `@import("testingx")`) appear as constants with no members.
- The page is one file. A large package produces a large page.
- Source links assume `--root` is relative to the repository root.

## Work on it

`nix develop` provides the toolchain. `just test`, `just doc`, and `just lint`
are the commands, and `just ci` runs what CI runs.

## License

MIT. See `LICENSE`.
