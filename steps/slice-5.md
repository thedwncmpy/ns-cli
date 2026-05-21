# Slice 5 Summary: Ship Upload Vertical Slice With Strict Guardrails

Date: 2026-05-19
Issue: (fill after creation)

## Goal
Implement `notion upload <file.md>` with strict guardrails, mapping resolution, and exact-match sync behavior.

## Planned Guardrails
- Require `.md` files.
- Require file path inside configured `notes_root`.
- Resolve relation from first-level path segment under `notes_root`.
- Require mapping for that first-level segment.
- Require token via env/file credential flow.
- Fail on ambiguity (multiple exact title + relation matches).

## Implementation Logic (Upload Flow)

The `notion upload` command follows a **Research -> Query -> Act** lifecycle to ensure data integrity:

1.  **Parsing & Conversion**:
    - **Title**: Derived from the filename (e.g., `My Note.md` -> `My Note`).
    - **Content**: `notion_parser.py` converts Markdown into a JSON array of Notion blocks.
2.  **State Detection (The Query)**:
    - Performs a `POST /databases/{id}/query` with a filter matching both the **Title** and the resolved **Notebook Relation**.
    - **Ambiguity Guard**: If more than one page matches, the process aborts to prevent accidental corruption.
3.  **Sync Execution**:
    - **Update Path** (If page exists):
        - `GET /blocks/{id}/children` to list all existing content.
        - `DELETE /blocks/{id}` for every child block to clear the page.
        - `PATCH /blocks/{id}/children` to append the new parsed blocks.
    - **Create Path** (If page is missing):
        - `POST /pages` with properties (Title, Relation) and the full block array in the initial payload.

## Files Involved
- `lib/notion_cli.zsh`
- `notion/notion_parser.py` (integration dependency)
- `tests/test_slice5_upload.sh`

## Test Reference
- `./tests/test_slice5_upload.sh`

## Notes
- This file is a scaffold and should be updated with actual implementation details and commit hash once slice 5 is completed.
