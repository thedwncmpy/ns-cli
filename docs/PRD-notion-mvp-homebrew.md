## Problem Statement

Users need a reliable way to install and use this Notion sync CLI via Homebrew without copying shell snippets manually. The current workflow works for one local setup but is not portable because configuration is hardcoded and tied to local machine paths and notebook IDs.

The MVP must preserve current two-way sync behavior (upload and download) while introducing a project-based configuration model that supports different user setups.

## Solution

Ship a Homebrew-installable CLI with a single executable command surface: `notion`.

The CLI supports four subcommands:
- `notion init --database-id <id> --notes-root <path>`
- `notion link <subdir> <relation_page_id>`
- `notion upload <file.md>`
- `notion download <file.md>`

Project metadata is stored in a versioned project config (`.notion-cli/config.json`) and secrets are stored separately (`NOTION_TOKEN` via environment variable or `~/.config/notion-cli/secrets.zsh`). Upload/download behavior remains strict and deterministic: exact filename stem to exact Notion title, strict root enforcement, explicit failures on ambiguity or mismatch.

## User Stories

1. As a CLI user, I want to install the tool from a public Homebrew tap, so that setup is fast and repeatable.
2. As a new user, I want one command entrypoint (`notion`), so that the interface is simple to discover.
3. As a project owner, I want to initialize project config with `notion init`, so that project metadata is explicit and reproducible.
4. As a project owner, I want `notion init` to require a `--database-id`, so that setup is deterministic.
5. As a project owner, I want `notion init` to refuse overwriting existing config unless `--force` is provided, so that I do not accidentally lose mappings.
6. As a contributor, I want project mapping config committed to git, so that collaborators share relation mappings.
7. As a security-conscious user, I want auth token storage separated from project config, so that secrets are not committed.
8. As a power user, I want to provide `NOTION_TOKEN` via runtime environment variable, so that I can run automation and CI jobs.
9. As a local user, I want fallback token loading from `~/.config/notion-cli/secrets.zsh`, so that daily usage is convenient.
10. As a note organizer, I want to link first-level subdirectories to relation page IDs, so that folder structure maps to Notion relations.
11. As a cautious user, I want `notion link` to fail if subdirectory does not exist, so that mappings cannot drift.
12. As a cautious user, I want changing an existing subdirectory mapping to require `--force`, so that accidental remaps are prevented.
13. As a note author, I want to upload markdown files to Notion, so that local content syncs to remote pages.
14. As a note author, I want upload to only accept `.md` files, so that format expectations are consistent.
15. As a note author, I want upload to reject files outside configured `notes_root`, so that sync scope is explicit.
16. As a note author, I want nested directories under a mapped first-level folder to be allowed, so that project structures remain flexible.
17. As a note author, I want relation resolution based on the first path segment under `notes_root`, so that mapping behavior is predictable.
18. As a note author, I want upload matching to require exact title plus mapped relation, so that updates are unambiguous.
19. As a note downloader, I want to pull a page into a markdown file, so that local notes can be refreshed from Notion.
20. As a note downloader, I want download to create missing local files when a unique exact remote match exists, so that bootstrap is frictionless.
21. As a note downloader, I want download to create parent directories when needed, so that nested paths work reliably.
22. As a user, I want case-sensitive exact filename-stem to title matching, so that sync behavior is strict and transparent.
23. As a user, I want ambiguous matches to fail hard, so that data cannot sync to the wrong page.
24. As a user, I want actionable error messages with expected title and close matches, so that fixes are quick.
25. As a maintainer, I want parser behavior preserved, so that existing markdown-to-Notion fidelity does not regress in MVP.
26. As a maintainer, I want a strict non-zero exit code on all failures, so that scripts can trust command outcomes.
27. As a maintainer, I want deterministic sync rules with no legacy fallback path, so that operation is predictable across environments.
28. As a maintainer, I want the same toolchain stack retained (`zsh + python3 + jq + curl`), so that MVP risk stays low.
29. As a release owner, I want a clear pre-publish test checklist, so that the Homebrew release candidate is reliable.
30. As a future contributor, I want the command surface and config schema versioned, so that future migrations are manageable.

## Implementation Decisions

- Build a single-command CLI interface (`notion`) with explicit subcommands rather than multiple binaries.
- Preserve existing two-way sync capabilities as the MVP behavioral baseline.
- Introduce a project configuration module for `.notion-cli/config.json` with versioned schema.
- Keep project metadata in config: `version`, `notes_root`, `database_id`, and first-level directory relation mappings.
- Separate secret management into a credential-loading module with precedence:
  - `NOTION_TOKEN` from runtime environment
  - fallback to `~/.config/notion-cli/secrets.zsh`
- Remove dependency on `NOTION_NOTES_DB_ID` as a secret; database ID is project metadata.
- Enforce initialization-first workflow: upload/download/link require valid project config.
- Enforce strict guardrails:
  - `.md` only
  - file path must be inside configured `notes_root`
  - subdirectory mapping must exist
  - exact case-sensitive filename-stem to Notion title matching
- Keep first-level relation model while allowing deeper nested note paths.
- Resolve relation from first path segment under `notes_root`.
- Require exact title + mapped relation constraints in both upload and download lookup logic.
- Fail fast on ambiguous matches and API failures with non-zero exit status.
- Keep markdown parsing logic via existing parser module unchanged for MVP.
- Package via public Homebrew tap with declared runtime dependencies consistent with current stack.
- Structure internals into deep modules:
  - command router module (`init/link/upload/download` contract)
  - config repository module (read/write/validate/versioning)
  - relation resolver module (path-to-first-level mapping)
  - Notion API client module (query/create/update/delete/fetch behavior)
  - sync engine module (upload and download orchestration)
  - parser adapter module (forward/reverse parser integration)
  - diagnostics module (actionable errors and exit codes)

## Testing Decisions

- Good tests assert external behavior and contract outcomes (exit codes, created/updated artifacts, API request selection, and produced markdown), not shell implementation details.
- Test coverage will prioritize modules with stable public behavior:
  - command router behavior for subcommand parsing and required flags
  - config repository behavior for init/overwrite protection/schema correctness
  - link workflow behavior for existing-subdir validation and `--force` remap semantics
  - relation resolver behavior for first-level mapping across nested paths
  - upload guardrails (`.md`, inside-root, mapping present, exact+relation match)
  - download behavior for file creation and ambiguity handling
  - parser adapter parity with existing parser behavior on fixtures
  - end-to-end happy path and failure path checks for roundtrip sync expectations
- MVP release gate includes six acceptance checks:
  - `init` writes valid config
  - `link` validates subdir and updates config
  - `upload` rejects outside-root and non-markdown
  - `download` creates missing local file when unique exact remote match exists
  - upload/download roundtrip preserves parser behavior on fixture
  - clean-machine brew install exposes working `notion` command
- Prior-art style for tests in this codebase is currently minimal; the test suite should establish command-contract-first patterns that future work can extend.

## Out of Scope

- Legacy fallback to hardcoded notebook mappings.
- Multiple binary wrappers (`notion-upload`, `notion-download`, etc.).
- Interactive prompts or wizard-style setup.
- Support for non-markdown note formats.
- Automatic title normalization or fuzzy matching acceptance.
- Homebrew core submission in MVP.
- Large parser feature expansion beyond current forward/reverse behavior.
- Team-shared secret distribution workflows.

## Further Notes

- This MVP intentionally prioritizes deterministic behavior over permissive convenience to reduce sync risk.
- Config is designed for git-sharing of mapping metadata while keeping credentials local.
- The architecture should make future additions straightforward (e.g., migrations, additional relation strategies, richer sync conflict reporting).
