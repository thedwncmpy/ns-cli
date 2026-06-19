# notion-cli User Guide

`notion-cli` syncs Markdown files in a local notes tree with a Notion database through the `ns` command.

This guide is based on the current implementation in `lib/`, not on intended behavior.

## What the CLI Does

- Uses exact filename-to-page-title matching.
- Uses first-level directory mappings to scope relation-based sync.
- Stores project config in `.ns-cli/config.json` under your notes root.
- Stores downloaded page metadata in `.ns-cli/pages/**/*.json`.
- Uploads Markdown to Notion.
- Downloads Notion pages to Markdown.
- Fails hard on ambiguous matches.

## Requirements

- `zsh`
- `python3`
- `jq`
- `curl`
- A Notion integration token with access to the target database

## Authentication

Set `NOTION_TOKEN` in either of these places:

```bash
export NOTION_TOKEN="secret_xxx"
```

Or in `~/.config/ns-cli/secrets.zsh`:

```bash
export NOTION_TOKEN="secret_xxx"
```

Environment variables take precedence over the secrets file.

## Project Setup

Initialize a notes tree:

```bash
ns init --database-id <database_id> --notes-root ./notes
```

If your Notion database title property is not named `Name`, set it explicitly:

```bash
ns init --database-id <database_id> --notes-root ./notes --title-property Title
```

This creates:

```text
notes/
  .ns-cli/
    config.json
```

## Directory Mapping

`ns link` maps a first-level subdirectory under `notes_root` to:

- a Notion relation page id
- the relation property name used on database pages

Example:

```bash
ns link project rel_123 notebook
```

That means files under `notes/project/` sync against pages whose:

- title equals the Markdown filename stem
- `notebook` relation contains `rel_123`

Only first-level directories are mapped. A file at `notes/project/daily/today.md` still uses the `project` mapping.

## Config Format

Example `.ns-cli/config.json`:

```json
{
  "version": 1,
  "database_id": "db_test",
  "notes_root": "/absolute/path/to/notes",
  "title_property": "Name",
  "mappings": {
    "project": {
      "relation_page_id": "rel_123",
      "relation_property": "notebook"
    }
  },
  "watch": {
    "default_cooldown_seconds": 60,
    "files": {
      "project/today.md": {
        "enabled": true,
        "cooldown_seconds": 60,
        "last_uploaded_at": 1781899705
      }
    }
  }
}
```

Legacy mapping values are still accepted:

```json
{
  "mappings": {
    "project": "rel_123"
  }
}
```

In that case the relation property defaults to `notebook`.

## Command Reference

### `ns init`

```bash
ns init --database-id <id> --notes-root <path> [--title-property <name>] [--force]
```

- Creates `.ns-cli/config.json` inside the notes root.
- `--force` overwrites an existing config.

### `ns link`

```bash
ns link <subdir> <relation_page_id> <relation_property> [--force]
```

- `subdir` must already exist under `notes_root`.
- `--force` overwrites an existing mapping.

### `ns status`

```bash
ns status <file.md>
```

Shows resolved sync behavior for a single file:

- title
- notes root
- mapping directory
- relation page id
- relation property
- exact query filter used for sync

If you run `ns status` with no file argument, it prints the project config JSON.

### `ns upload`

```bash
ns upload [--dry-run] <file.md>
```

Behavior:

- File must exist.
- File must end in `.md`.
- File must be inside `notes_root`.
- If the file is under a subdirectory, that first-level directory must be mapped.
- Root-level files are allowed without a mapping.

Matching logic:

- Mapped file: query by exact title plus exact relation membership.
- Root-level file: query by exact title only.

If a single match exists:

- the existing remote page is archived
- a new page is created
- all Markdown blocks are appended to the new page

If no match exists:

- a new page is created

If multiple matches exist:

- the command fails

`--dry-run` prints intent only.

### `ns upload-all`

```bash
ns upload-all [--dry-run]
```

Uploads all Markdown files under the current directory recursively.

This is effectively a batch wrapper around `ns upload`. It works on local files only, not on every page in the Notion database.

### `ns upload-sync`

```bash
ns upload-sync [--dry-run]
```

Current implementation behavior matches `ns upload-all`: it uploads all Markdown files under the current directory recursively.

### `ns watch`

```bash
ns watch [<file.md>] [--enable|--disable] [--cooldown-seconds <n>]
```

Behavior:

- `ns watch <file.md> --enable` enables auto-upload for one Markdown file.
- `ns watch <file.md> --disable` disables auto-upload for one Markdown file.
- Bare `ns watch` runs the watcher loop.
- The watcher scans `notes_root` for changed `.md` files but only uploads files that are explicitly enabled in config.
- Reuses the existing `ns upload` flow for each changed file.
- Stores per-file state in `watch.files[<relative-path>]`.
- Stores per-file `last_uploaded_at` timestamps in project config.
- Skips re-uploading the same file until the cooldown window expires.
- Successful sync operations append a hidden audit line to `.ns-cli/sync.log`.

Examples:

```bash
ns watch project/today.md --enable --cooldown-seconds 60
ns watch
ns watch project/today.md --disable
```

### `ns download`

```bash
ns download [--dry-run] <file.md>
```

Behavior:

- Target path must end in `.md`.
- Target path must be inside `notes_root`.
- If the path is under a subdirectory, that first-level directory must be mapped.
- Root-level targets are allowed without a mapping.

Matching logic:

- Mapped file: query by exact title plus exact relation membership.
- Root-level file: query by exact title only.

If a single match exists:

- the remote page is converted to Markdown
- the target file is created or overwritten
- page properties and icon metadata are written to `.ns-cli/pages/...json`

If no match exists:

- the command fails

If multiple matches exist:

- the command fails

`--dry-run` prints intent only.

### `ns delete`

```bash
ns delete [--dry-run] <file.md>
```

Behavior:

- Target path must end in `.md`.
- Target path must be inside `notes_root`.
- If the path is under a subdirectory, that first-level directory must be mapped.
- Root-level targets are allowed without a mapping.

Matching logic:

- Mapped file: query by exact title plus exact relation membership.
- Root-level file: query by exact title only.

If a single match exists:

- the remote page is archived
- the local Markdown file is deleted if present
- the matching `.ns-cli/pages/...json` sidecar is deleted if present

If no match exists:

- the command fails

If multiple matches exist:

- the command fails

`--dry-run` prints intent only.

### `ns download-all`

```bash
ns download-all [--dry-run]
```

Downloads every remote page in the current sync scope.

Scope depends on the current working directory:

- If run from `notes_root`, it queries the full database.
- If run inside a mapped first-level directory, it queries only pages whose mapped relation contains that directory's relation page id.

Target path rules:

- In a mapped scope, files download into that mapped directory.
- In root scope, the CLI tries to infer a mapped directory from each page's relations.
- If a page matches multiple directory mappings, the command fails for that page.
- If no mapping matches, the page downloads to the root of `notes_root`.

### `ns download-sync`

```bash
ns download-sync [--dry-run]
```

Downloads all Markdown files under the current directory recursively by calling `ns download` for each file path found locally.

This command does not discover remote-only pages.

### `ns completion`

```bash
ns completion <zsh|bash>
```

Example:

```bash
eval "$(ns completion zsh)"
```

### `ns version`

```bash
ns version
```

## Sync Rules

### Title Matching

The page title is always the filename stem:

- `notes/project/today.md` -> `today`

No frontmatter title override exists.

### Mapping Rules

- Only the first path segment under `notes_root` is used for relation mapping.
- Unmapped nested files fail.
- Root-level files do not require a mapping.

### Ambiguity

The CLI is intentionally strict:

- more than one matching page is an error
- missing required mapping is an error
- missing config is an error
- target outside `notes_root` is an error

## Metadata Storage

Downloaded page properties and icon metadata are stored in sidecar JSON files under:

```text
.ns-cli/pages/
```

For example:

```text
notes/.ns-cli/pages/project/today.json
```

The current upload flow reads these sidecars and uses them when recreating a page.

Important implementation detail:

- downloaded Markdown files are written as plain Markdown body only
- the CLI currently does not embed `<!-- notion-properties ... -->` metadata blocks into the Markdown file body
- sidecar JSON is the active metadata source when present

## Markdown Support

Supported Markdown-to-Notion conversions include:

- paragraphs
- headings `#`, `##`, `###`
- toggle headings via `[toggle] `
- bulleted lists
- todo items `- [ ]` and `- [x]`
- quotes
- callouts using blockquote alert markers
- fenced code blocks
- dividers `---`
- `[TOC]`
- `[[link_to_page page_id:...]]`
- `[[link_to_page database_id:...]]`

### Toggle Headings

Use `[toggle] ` at the start of a heading text:

```md
### [toggle] Section

  Paragraph inside toggle
  - Nested item
```

Nested content is determined by indentation. The parser uses an indent width of 2 spaces.

### Callouts

These blockquote markers map to Notion callouts:

```md
> [!NOTE] Text
> [!WARNING] Text
> [!ERROR] Text
> [!INFO] Text
> [!SUCCESS] Text
```

### Code Blocks

Fenced code blocks are supported. Unknown languages are normalized to `plain text`.

Language aliases include:

- `zsh` -> `shell`
- `sh` -> `shell`
- `py` -> `python`
- `js` -> `javascript`
- `ts` -> `typescript`
- `yml` -> `yaml`
- `md` -> `markdown`

## Common Workflows

Initialize and upload one file:

```bash
export NOTION_TOKEN="secret_xxx"
ns init --database-id <db_id> --notes-root ./notes
ns link project <relation_page_id> notebook
ns upload ./notes/project/today.md
```

Inspect what a file will do before syncing:

```bash
ns status ./notes/project/today.md
ns upload --dry-run ./notes/project/today.md
ns download --dry-run ./notes/project/today.md
```

Download all pages for one mapped directory:

```bash
cd ./notes/project
ns download-all
```

Download the full database into the notes tree:

```bash
cd ./notes
ns download-all
```

## Known Current Behaviors

- `upload-all` and `upload-sync` currently behave the same.
- `download-sync` works from local file discovery, not remote page discovery.
- Uploading a matched page archives the old page and recreates it instead of patching blocks in place.
- Markdown property blocks are parsed if present, but normal downloads currently store metadata in sidecar JSON instead of writing those blocks back into Markdown.
