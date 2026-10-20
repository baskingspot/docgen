# AGENTS.md

Working notes for AI coding agents in baskingspot/autodoc.

## What this is

A static HTML API reference generator for Zig packages. It is incubating and
is a POC: the API, the HTML, and the supported syntax will change.

The tool has two shapes. The `autodoc` executable is the standalone CLI. The
`autodoc` module is the library API, so a consumer can call
`autodoc.generate` from a build step.

## Environment

Zig 0.16 only. The flake is the tool contract, from `baskingspot/nix`:
`nix develop` provides Zig, `ziglint`, and the base tools. The justfile is the
command interface: `just test`, `just doc`, `just serve`, `just lint`, and
`just ci`. Run `just fmt` before you commit.

## Design

The POC is deliberately small. It parses source with `std.zig.Ast`, follows
relative imports, collects public declarations, and writes one HTML page. It
does not use `lib/zig/docs/wasm`, `sources.tar`, WebAssembly, or JavaScript.

`src/style.css` is the theme. It is embedded into the page at build time.
`src/generate.zig` holds the reader and the renderer. `src/main.zig` only
parses flags.

Source links go to GitHub. `--root` must be relative to the repository root,
and `--rev` names the commit or branch.

## POC limits

- AST only. No type resolution, alias resolution, or build graph.
- Generic type functions are not expanded, so their methods are absent.
- Relative imports only.
- One page.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed.
  Do not rewrite pushed history.
- Gate commands on their exit codes, and claim only what you ran.
- Format with `zig fmt` and lint with `ziglint`. `just fmt` and `just lint`
  run both.
- This repo's GitHub settings come from `baskingspot/.github`, with
  `just settings`. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a
  real README, and the audit passing.

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
