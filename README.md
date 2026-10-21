<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="docgen" height="48">
  </picture>
</h1>

API documentation for Zig packages, as JSON.

docgen reads a Zig package's public API into one JSON document or one HTML
page. The JSON is the interface; the HTML page is a renderer. The baskingspot
docs theme is another renderer.

It parses the source with `std.zig.Ast`. It does not run the compiler or
resolve the build graph.

## Use

`nix develop` provides Zig 0.16 and the tools.

```sh
zig build run -- --root src/root.zig --out zig-out/docs --title mylib \
  --repo-url https://github.com/baskingspot/mylib --rev main
```

`just doc` builds the reference for this repository into `zig-out/docs`.
`just serve` serves it at <http://127.0.0.1:8000>. Set `PORT` to change the
port: `PORT=9000 just serve`.

### JSON

`--format json` writes the model instead of the page:

```sh
zig build run -- --root src/root.zig --out /tmp/docgen-api --format json
```

That writes `/tmp/docgen-api/api.json`. The document has:

- `schema_version`: 1
- `package`: name, root, repository URL, revision
- `module_docs`: the root `//!` markdown
- `symbols`: a flat pre-order list
- `diagnostics`: an empty array

A symbol has `name`, `fqn`, `kind`, `depth`, `parent`, `signature`, `docs`,
`file`, and `line`. Doc comments stay raw markdown. Signatures keep their
source line breaks. The JSON contains no HTML and no source URLs; a consumer
can build the URL from the package and the symbol's `file` and `line`. `fqn`
is the path inside the package; a renderer can prefix the package name for a
page anchor.

The schema version is part of the file. A change to the schema is a breaking
change.

### In a baskingspot repo

The `baskingspot` flake's `docs` devshell provides docgen, Zola, and
`baskingspot-docs`. A repository's `just doc` runs:

```sh
docgen --root src/root.zig --title NAME --repo-url https://github.com/baskingspot/NAME --rev main --format json --out docs/data
baskingspot-docs build NAME
```

The theme reads `docs/data/api.json` at build time and renders the API page.
Zola does not publish the JSON. The theme reads the JSON; it does not change
the generator.

### Document another repository

Run from the checkout you want to document, with docgen on PATH:

```sh
docgen \
  --root src/root.zig \
  --out /tmp/mylib-api \
  --title mylib \
  --repo-url https://github.com/baskingspot/mylib \
  --rev main
```

`--root` and the GitHub source paths are relative to the repository root. Open
`/tmp/mylib-api/index.html` directly, or serve the directory with
`python3 -m http.server -b 127.0.0.1 -d /tmp/mylib-api 8000`.

## Build integration

A Zig build can run the CLI as an artifact. A consumer that only calls the
library gets the module and no executable; pass `.exe = true` to build the
command:

```zig
const docgen_dep = b.dependency("docgen", .{ .exe = true });
const docgen = docgen_dep.artifact("docgen");

const docs = b.addRunArtifact(docgen);
docs.addArgs(&.{
    "--root",     "src/root.zig",
    "--title",    "mylib",
    "--repo-url", "https://github.com/baskingspot/mylib",
    "--rev",      "main",
    "--format",   "json",
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
creates that directory and gives the install step a `LazyPath`. This example
writes `api.json` to `zig-out/docs`. Leave out `--format` and its value to
write `index.html` instead.

## What it does

- Follows relative `@import("file.zig")` declarations, chained
  `@import("file.zig").Name` re-exports, local aliases, and conditional
  aliases such as `pub const pages = if (...) pages_mod else void;`.
- Collects `pub` declarations and public container members, including tagged
  unions (`union(enum)` and `union(enum(T))`).
- Keeps signatures with their initializer and source layout. `pub const empty
= 0x80;` keeps its value; a multi-line parameter list keeps its lines.
- Keeps doc comments as raw markdown in the model. The standalone page renders
  paragraphs, headings, and inline code; the Zola theme uses its own markdown.
- Writes one JSON document or one self-contained HTML page. The standalone
  page has inline CSS and no script, and it makes no network requests.
- On stdx, the model has 869 symbols; the standalone page is 509 KB, or 57 KB
  gzipped.

## Limits

- It is an AST reader. It follows relative imports, local aliases, and chained
  re-exports. It does not resolve package imports (`@import("std")`,
  `@import("stdx")`), primitives, or foreign types. A package import is a
  module with no members.
- A type function expands when its body returns a container directly, names a
  local container or type function, calls a local type function, or selects
  one with `if` or `switch`. An instantiation alias such as `pub const Bytes =
buf.Array(u8, 32);` stays a constant. Member signatures keep the callee's
  parameter names.
- An alias that names a sibling declaration inside the same container is not
  followed. An error set keeps its initializer text and does not list its
  members.
- The page is one file. A large package produces a large page.
- Source links are relative to the repository root. Run docgen from that root.

## Work on it

`nix develop` provides the toolchain. `just test`, `just doc`, `just lint`, and
`just ci` are the commands. Run `just fmt` before a commit.

## License

MIT. See `LICENSE`. The logo files in `docs/static/` are baskingspot marks and
are not covered by it. See `docs/static/LICENSE`.

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
