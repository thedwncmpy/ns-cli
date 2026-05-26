# Slice 9 Summary: P0 Upload Relation Property Fix + Test Stabilization

Date: 2026-05-26
Issue: https://github.com/thedwncmpy/notion-cli/issues/10

## Scope
Implement P0 correctness work (excluding Homebrew formula updates):
- Fix upload create-path relation property behavior.
- Clean up slice-5 test hygiene.
- Add regression coverage for non-default relation property on create-path uploads.

## Implemented
1. Fixed upload create-path relation property bug
- Updated `notion_cmd_upload` page-create payload to use mapped `relation_property` from config instead of hardcoded `notebook`.
- File changed: `lib/notion_cli.zsh`

2. Stabilized slice-5 test file
- Removed accidental stray lines at top of `tests/test_slice5_upload.sh`.
- File changed: `tests/test_slice5_upload.sh`

3. Added regression coverage for create-path mapping behavior
- Extended `tests/test_slice7_roundtrip_contract.sh` to include an upload create-path case (`create-path.md`).
- Assertion verifies create-page payload includes mapped relation property (`relation_prop`) and mapped relation id (`rel_123`).
- File changed: `tests/test_slice7_roundtrip_contract.sh`

## Validation
- `./tests/test_slice5_upload.sh` : PASS
- `./tests/test_slice7_roundtrip_contract.sh` : PASS
- `zsh -n lib/notion_cli.zsh` : PASS

## Notes
- Per request, Homebrew formula/release-SHA work was intentionally not modified.
