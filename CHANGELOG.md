# Changelog

All notable changes to autodoc are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `autodoc` CLI and library. It generates a static HTML API reference from a
  Zig root source file, follows relative imports, and links declarations to
  GitHub.
- Type functions that return a container inline, such as
  `pub fn Array(...) type { return struct { ... }; }`, list their members.

### Fixed

- Resolve a public alias that selects a private import in an `if`, such as
  stdx's `pages` and `slot_ring`.
