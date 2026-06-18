# notion-cli

`notion-cli` is a lightweight command-line tool for strict two-way sync between local markdown files and a Notion database.

The MVP keeps sync behavior deterministic:
- Exact filename-stem to Notion title matching
- First-level directory to relation mapping
- Strict failures on ambiguity/mismatch
- Single command surface: `ns`

## Install

From your Homebrew tap:

```bash
brew tap thedwncmpy/homebrew-notion-cli
brew install thedwncmpy/homebrew-notion-cli/notion
```

If your tap repo is still typo-named, use `howebrew-notion-cli` instead.

## What It Does

- Stores project config in `.notion-cli/config.json`
- Keeps secrets separate via `NOTION_TOKEN` (env) or `~/.config/notion-cli/secrets.zsh`
- Uploads local markdown to matching Notion pages
- Downloads Notion pages into local markdown files (create or overwrite)

## Markdown Notes

- `### [toggle] Section` maps to a Notion toggleable heading 3 (`heading_3.is_toggleable = true`)
- Indent blocks under that heading by two spaces to store them as toggle children and preserve them on download

```md
### [toggle] Section

  Paragraph inside toggle

  - Nested item
```

## Command Overview

```bash
ns init --database-id <id> --notes-root <path> [--title-property <name>] [--force]
ns link <subdir> <relation_page_id> <relation_property> [--force]
ns upload <file.md>
ns upload-all [--dry-run]
ns upload-sync [--dry-run]
ns download <file.md>
ns download-all [--dry-run]
ns download-sync [--dry-run]
ns completion zsh
```

## Quick Start

1. Export your Notion token:

```bash
export NOTION_TOKEN="secret_xxx"
```

2. Initialize a project:

```bash
ns init --database-id <notion_db_id> --notes-root ./notes
```

If your Notion database title column is not named `Name`, set it explicitly during init:

```bash
ns init --database-id <notion_db_id> --notes-root ./notes --title-property Title
```

3. Map a first-level folder to a relation page id + relation property:

```bash
ns link project rel_123 notebook
```

4. Upload a note:

```bash
ns upload ./notes/project/today.md
```

5. Upload every markdown file in the current scope:

```bash
cd ./notes/project
ns upload-all
```

6. Download a note (creates or overwrites local file):

```bash
ns download ./notes/project/today.md
```

7. Download every page in the current scope:

```bash
cd ./notes/project
ns download-all
```

Run `download-all` from `notes_root` to materialize the full database. Run it from a linked directory to only download pages whose configured relation contains that linked page id.

## Config Shape

Example `.notion-cli/config.json`:

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
  }
}
```

Legacy mapping values are still supported for compatibility:

```json
"mappings": {
  "project": "rel_123"
}
```

In legacy mode, relation property defaults to `notebook`.

## Guardrails

- `upload`/`download` require `.md`
- Target file must be inside configured `notes_root`
- Mapping must exist for the first-level directory
- Exact title + mapped relation query only
- Ambiguous matches fail hard



## Shell Completion

For zsh, load completion in your shell startup:

```bash
eval "$(ns completion zsh)"
```
