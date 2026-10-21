# Changelog

All notable changes to docgen are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `docgen` CLI and library. It generates a static HTML API reference from a
  Zig root source file, follows relative imports, and links declarations to
  GitHub.
- Type functions that return a container inline, such as
  `pub fn Array(...) type { return struct { ... }; }`, list their members.
- `--format json` writes the extracted document as `api.json`, and the library
  exports the public `Document` model with `extract`, `renderHtml`, and
  `writeJson`.
- Tagged unions (`union(enum)` and `union(enum(T))`) list their fields.
- Chained imports (`@import("x.zig").Name`) and local aliases or re-exports
  list the target's members under the alias.
- Constant and variable signatures keep their initializer, including error
  sets.
- Type functions that name a local type, call one, or select one with `if` or
  `switch` expand; every `fn ... type` is labeled `type fn`.
- `--version` prints the docgen version.

### Changed

- Signatures keep their source line breaks and indentation, so multi-line
  parameter lists and error sets render as written.
- The CLI uses `baskingspot/cli` for flags and `baskingspot/stdx` for buffered
  output. Expected errors print one line; usage errors exit 2 and I/O errors
  exit 1.
- A consumer that runs the CLI as a build step passes `.exe = true` to
  `b.dependency`; the default dependency is the library module.
- The HTML sidebar lists every symbol at every depth.

### Fixed

- Resolve a public alias that selects a private import in an `if`, such as
  stdx's `pages` and `slot_ring`.
- Module `//!` docs stay at module level instead of attaching to the first
  declaration.
- Two aliases of the same file both list the file's members.
- `--out` creates missing parent directories.
- The footer and CLI count every rendered symbol, including modules that
  inherit a file's docs.
