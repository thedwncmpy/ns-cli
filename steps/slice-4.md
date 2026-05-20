# Slice 4 Summary: Implement Credential Loading and Secret Separation

Date: 2026-05-19
Issue: https://github.com/thedwncmpy/notion-cli/issues/4

## Delivered
- Added credential loading helpers with source precedence:
  - `NOTION_TOKEN` environment variable first
  - fallback to `~/.config/notion-cli/secrets.zsh`
- Added required-token guard helper with actionable error output.
- Kept secrets out of project config (`.notion-cli/config.json`).

## Files Changed
- `lib/notion_cli.zsh`
- `tests/test_slice4_credentials.sh`

## Behavior Confirmed
- If `NOTION_TOKEN` is set in env, that value is used.
- If env var is missing and secrets file exports token, fallback works.
- If both are missing, command fails non-zero with actionable message.

## Test Evidence
- `./tests/test_slice4_credentials.sh` passes.

## Notes
- TODO markers use `TODO:` / `NOTE:` format for `folke/todo-comments` compatibility.
