# docgen: A static HTML generator for Zig API documentation. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests")]
[group("test")]
test:
    zig build test --summary all

[doc("Generate the API reference into zig-out/docs")]
[group("docs")]
doc:
    zig build docs --summary all

[doc("Serve the generated reference at http://127.0.0.1:8000 (override the port with PORT)")]
[group("docs")]
serve: doc
    python3 -m http.server -b 127.0.0.1 -d zig-out/docs "${PORT:-8000}"

[doc("Lint Zig, Nix, Markdown, CSS, the workflows, and this justfile")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src build.zig
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md src/style.css .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build.zig
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md src/style.css .github
    just --fmt

[doc("Everything CI runs: the tests, lint, and the API reference build")]
[group("ci")]
ci: test lint doc
