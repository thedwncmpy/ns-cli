# Slice 10 Summary: P1 Reliability Hardening (Pagination + Retry + Stress Coverage)

Date: 2026-05-26
Issue: https://github.com/thedwncmpy/notion-cli/issues/11

## Scope

Implement P1 reliability hardening from roadmap:

- Add pagination handling for Notion query and block-children retrieval paths.
- Add bounded retry/backoff for transient API/network failures.
- Add contract/stress coverage for large uploads and nested-path downloads.

## Implemented

1. Added Notion API reliability helpers in CLI core

- Introduced `notion_api_request` with bounded retry/backoff (3 attempts) for:
  - transient transport failures (curl non-zero exit)
  - transient Notion errors (`rate_limited`, `service_unavailable`, `internal_server_error`)
- Added paginated collectors:
  - `notion_query_all` for `/v1/databases/{id}/query`
  - `notion_fetch_all_children_ids` for page child-block id traversal
  - `notion_fetch_all_children_blocks` for full child-block retrieval
- File changed: `lib/notion_cli.zsh`

2. Wired upload/download flows to reliability helpers

- `upload` now uses paginated query reads and paginated existing-child discovery before delete/update.
- `download` now uses paginated query reads and paginated child-block fetch before reverse parsing.
- Replaced direct `curl` calls in these paths with helper-based calls for consistent retry behavior.
- File changed: `lib/notion_cli.zsh`

3. Added P1 stress/contract test coverage

- New test: `tests/test_slice10_reliability.sh`
- Validates:
  - retry behavior on transient create-path failure (POST `/v1/pages` retried and succeeds)
  - upload existing-page path consumes paginated child pages and deletes all discovered block ids
  - large upload chunking over 250 blocks (create + expected PATCH continuation count)
  - nested-path download create works and paginated block retrieval is used
- File added: `tests/test_slice10_reliability.sh`

## Validation

- `./tests/test_slice10_reliability.sh` : PASS
- `./tests/test_slice7_roundtrip_contract.sh` : PASS
- `./tests/test_slice5_upload.sh` : PASS
- `./tests/test_slice6_download.sh` : PASS
