# Slice 8: Publish Homebrew Tap Package for MVP

## Scope
Ship MVP packaging for public Homebrew tap with single `notion` executable and declared runtime dependencies.

## Implemented
- Added Homebrew formula: `Formula/notion.rb`.
- Formula installs `bin/notion` and `lib/` parser/CLI files.
- Formula rewrites runtime `source` path so installed binary loads `lib/notion_cli.zsh` from `libexec`.
- Declared runtime dependencies aligned with current stack: `jq`, `python@3.12`.
- Added packaging contract test: `tests/test_slice8_homebrew.sh`.

## Notes
- `sha256` is intentionally a placeholder (`REPLACE_WITH_RELEASE_TARBALL_SHA256`) until a tagged release tarball is cut.

## Validation
- Formula Ruby syntax check.
- Formula structure assertions.
- Local `notion help` smoke check.
