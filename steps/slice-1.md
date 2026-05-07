# Slice 1 Summary: Bootstrap notion Command Router

Date: 2026-05-07
Issue: https://github.com/thedwncmpy/notion-cli/issues/2

## Delivered
- Introduced single executable command surface: `notion`
- Added subcommand router for:
  - `init`
  - `link`
  - `upload`
  - `download`
  - `help`
- Preserved intended command shape for legacy functionality migration (`upload`/`download`) via the new router interface.

## Files Added
- `bin/notion`
- `lib/notion_cli.zsh`
- `tests/test_slice1_router.sh`

## Behavior Confirmed
- `notion` with no args prints usage and exits non-zero.
- `notion help` prints help and exits zero.
- Unknown command fails with explicit error.
- `notion <subcommand> --help` works for `init`, `link`, `upload`, `download`.
- Subcommands currently return "not implemented" for non-help paths (expected in slice 1 bootstrap).

## Test Evidence
- `./tests/test_slice1_router.sh` passes.
