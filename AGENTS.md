# AGENTS.md

Working notes for AI coding agents in baskingspot/docgen.

## What this is

An API reference generator for Zig packages. It reads a package's public API
into one JSON document. The standalone HTML page is one renderer; the
baskingspot Zola theme is another. It is incubating: the schema, the HTML, and
the supported syntax will change.

The tool has two shapes. `docgen` is the standalone CLI. The `docgen` module
exposes the model and the functions a consumer calls: `extract`,
`renderHtml`, `writeJson`, and `generate`.

The org's docs sites use the CLI from the `baskingspot` flake's `docs`
devshell, next to Zola and `baskingspot-docs`. The repo's own `zig build` and
justfile build the standalone page.

## Environment

Zig 0.16 only. The flake is the tool contract, from `baskingspot/nix`:
`nix develop` provides Zig, `ziglint`, and the base tools. The justfile is the
command interface: `just test`, `just doc`, `just serve`, `just lint`, and
`just ci`. Run `just fmt` before you commit.

The README uses the org voice. Read `.github/docs/VOICE.md` before changing
public text. The header, tagline, marks, badge, and "How it's made" follow the
org README template. The brand assets live in `docs/static`; the social
preview is `docs/static/social.png`, which Matt uploads by hand. The marks are
under `docs/static/LICENSE`; the code is MIT.

## Design

The reader is deliberately small. It parses source with `std.zig.Ast`, follows
relative imports and local aliases, collects public declarations, and writes
one document. `src/model.zig` holds the public model and the JSON writer;
`src/generate.zig` holds the reader, the HTML renderer, and the flatten;
`src/main.zig` only parses flags. `src/style.css` is the standalone page's
theme. The Zola theme lives in `baskingspot/nix`, not here.

The JSON is the interface. `schema_version` is 1; a schema change is a
breaking change. Symbols are a flat pre-order list with `depth` and `parent`.
`docs` and `signature` are source text: doc comments are raw markdown;
signatures keep their source line breaks. `fqn` is the path inside the
package; a renderer prefixes the package name for a page anchor
(`stdx.base32`). The JSON contains no HTML and no source URLs. `diagnostics`
stays empty until extraction emits one.

The org's docs pipeline runs `docgen --format json` into `docs/data/api.json`,
then `baskingspot-docs build NAME`. Zola reads the JSON at build time and does
not publish it. The theme can add progressive enhancement; the standalone page
has no JavaScript and makes no network requests. The `docgen` package in
`baskingspot/nix` pins the source; the repos get it from the `baskingspot`
flake input. After a docgen change, bump `pkgs/docgen` to the new commit,
regenerate `build.zig.zon.nix` with zon2nix when the dependencies change, and
run `nix build .#docgen`.

It does not use `lib/zig/docs/wasm`, `sources.tar`, or WebAssembly.

Source links go to GitHub. Run docgen from the repository root; `--root` and
the symbol file paths are relative to it. `--rev` names the commit or branch.

## POC limits

- AST only. No build graph and no package resolution. Relative imports, local
  aliases, chained `@import("x.zig").Name` re-exports, and a private import
  alias selected by an `if` are followed. A package import (`@import("std")`,
  `@import("stdx")`) is an opaque module.
- A type function is expanded when its body directly returns a container,
  names a local container or type function, calls a local type function, or
  selects one with `if` or `switch`. An instantiation alias such as
  `pub const Bytes = buf.Array(u8, 32);` stays a constant. Member signatures
  keep the callee's parameter names.
- An alias to a sibling declaration inside the same container is not followed.
  An error set keeps its initializer text but does not list its members.
- One page. A large package produces a large page.
- Source links are relative to the repository root.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed.
  Do not rewrite pushed history.
- Gate commands on their exit codes, and claim only what you ran.
- Format with `zig fmt` and lint with `ziglint`. `just fmt` and `just lint`
  run both.
- This repo's GitHub settings come from `baskingspot/.github`, with
  `just settings`. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: marks,
  README, topics, settings, and the audit. The marks and README are in place;
  the audit and the repo stage remain.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, or the build requirements. Docs, CI,
and internal refactors do not need one unless they change how someone uses the
package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.
