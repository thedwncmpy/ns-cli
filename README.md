# ns-cli

`notion-cli` is a lightweight command-line tool for strict sync between local Markdown files and a Notion database.

The CLI keeps sync behavior deterministic:
- Exact filename-stem to Notion title matching
- First-level directory to relation mapping
- Strict failures on ambiguity and mismatch
- Single command surface: `ns`

## Install

From your Homebrew tap:

```bash
brew tap thedwncmpy/homebrew-notion-cli
brew install thedwncmpy/homebrew-notion-cli/notion
```

If your tap repo is still typo-named, use `howebrew-notion-cli` instead.

## Requirements

- `zsh`
- `python3`
- `jq`
- `curl`
- A Notion integration token with access to the target database

## What It Does

- Stores project config in `.notion-cli/config.json`
- Stores per-page Notion properties and icons in `.notion-cli/pages/**/*.json`
- Reads secrets from `NOTION_TOKEN` or `~/.config/notion-cli/secrets.zsh`
- Uploads local Markdown to Notion
- Downloads Notion pages into local Markdown files
- Deletes local Markdown files and archives matching Notion pages
- Supports both mapped subdirectories and root-level notes

## Markdown Notes

Supported Markdown components:

| Markdown | Notion block | Notes |
| --- | --- | --- |
| Plain text | `paragraph` | Default fallback for non-special lines |
| `# Title` | `heading_1` | Headings supported through level 3 |
| `## Title` | `heading_2` | |
| `### Title` | `heading_3` | |
| `# [toggle] Section` | `heading_1` | Sets `is_toggleable: true` |
| `## [toggle] Section` | `heading_2` | Sets `is_toggleable: true` |
| `### [toggle] Section` | `heading_3` | Sets `is_toggleable: true` |
| Indented content under a toggle | nested children | Use a two-space indent to preserve toggle children on download |
| `- Item` or `* Item` | `bulleted_list_item` | Supports nested children by indentation |
| `- [ ] Task` | `to_do` | Unchecked to-do |
| `- [x] Task` | `to_do` | Checked to-do |
| `> Quote` | `quote` | Consecutive quoted lines are grouped into one block |
| `> [!NOTE] Text` | `callout` | Also supports `INFO`, `WARNING`, `ERROR`, and `SUCCESS` |
| Fenced code block | `code` | Unknown languages normalize to `plain text` |
| `---` | `divider` | Horizontal divider |
| `[TOC]` | `table_of_contents` | Round-trips as a TOC placeholder |
| `[[link_to_page page_id:...]]` | `link_to_page` | Also supports `database_id` |

Inline rich text is also preserved for supported blocks:
- `**bold**`
- `*italic*`
- `***bold italic***`

```md
### [toggle] Section

  Paragraph inside toggle

  - Nested item
```

## Command Overview

```bash
ns init --database-id <id> --notes-root <path> [--title-property <name>] [--force]
ns link <subdir> <relation_page_id> <relation_property> [--force]
ns status [<file.md>]
ns upload [--dry-run] <file.md>
ns upload-all [--dry-run]
ns upload-sync [--dry-run]
ns watch [<file.md>] [--enable|--disable] [--cooldown-seconds <n>]
ns watch-upload <file.md>
ns download [--dry-run] <file.md>
ns delete [--dry-run] <file.md>
ns download-all [--dry-run]
ns download-sync [--dry-run]
ns completion <zsh|bash>
ns version
```

## Quick Start

1. Export your Notion token:

```bash
export NOTION_TOKEN="secret_xxx"
```

Or store it in `~/.config/notion-cli/secrets.zsh`:

```bash
export NOTION_TOKEN="secret_xxx"
```

Environment variables take precedence over the secrets file.

2. Initialize a project:

```bash
ns init --database-id <notion_db_id> --notes-root ./notes
```

If your Notion database title column is not named `Name`, set it explicitly during init:

```bash
ns init --database-id <notion_db_id> --notes-root ./notes --title-property Title
```

3. Map a first-level folder to a relation page id and relation property:

```bash
ns link project rel_123 notebook
```

4. Upload a note:

```bash
ns upload ./notes/project/today.md
```

5. Upload every Markdown file in the current scope:

```bash
cd ./notes/project
ns upload-all
```

Or enable watch mode for one note with a one-minute cooldown:

```bash
ns watch ./notes/project/today.md --enable --cooldown-seconds 60
ns watch
ns watch-upload ./notes/project/today.md
```

Neovim save hook example:

```lua
vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "*.md",
  callback = function(args)
    vim.fn.jobstart({ "ns", "watch-upload", args.file }, {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        for _, line in ipairs(data or {}) do
          if line ~= "" then
            vim.schedule(function()
              vim.api.nvim_echo({ { line, "None" } }, false, {})
            end)
          end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data or {}) do
          if line ~= "" then
            vim.schedule(function()
              vim.api.nvim_echo({ { line, "WarningMsg" } }, false, {})
            end)
          end
        end
      end,
    })
  end,
})
```

This keeps `watch-upload` attached so status lines and warnings show in Neovim instead of being discarded by a detached job.

Example end-to-end setup for `./notes/todo/task1.md`:

1. Enable watch for the file:

```bash
ns watch ./notes/todo/task1.md --enable --cooldown-seconds 60
```

2. Add the `BufWritePost` autocommand shown above to your Neovim config.

3. Open `./notes/todo/task1.md` in Neovim and save it.

4. On the first save, Neovim should show status lines from `ns watch-upload`, for example:

```text
Change detected: todo/task1.md
Uploaded 'task1' successfully.
```

5. If you save again before the cooldown expires, Neovim should show a cooldown warning instead of uploading again.

6. If two saves overlap closely enough to start two `watch-upload` runs for the same file, only one upload proceeds. The other exits with:

```text
Skipping 'todo/task1.md'; sync already in progress.
```

This lock is per file, not per directory, so `todo/task2.md` can still upload while `todo/task1.md` is in progress.

6. Inspect resolved sync behavior for one note:

```bash
ns status ./notes/project/today.md
```

Run `ns status` with no file argument to print the project config JSON.

7. Download a note:

```bash
ns download ./notes/project/today.md
```

8. Delete a note locally and archive the matching Notion page:

```bash
ns delete ./notes/project/today.md
```

9. Download every page in the current scope:

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

Legacy mapping values are still supported for compatibility:

```json
"mappings": {
  "project": "rel_123"
}
```

In legacy mode, relation property defaults to `notebook`.

## Guardrails

- `upload`, `download`, and `delete` require `.md`
- Target paths must be inside configured `notes_root`
- Mapping must exist for the first-level directory when the file is not at the root of `notes_root`
- Root-level files are allowed without a mapping
- Mapped files use exact title plus mapped relation queries
- Root-level files use exact title-only queries
- Ambiguous matches fail hard

## Current Behavior Notes

- `upload-all` and `upload-sync` currently behave the same: both upload Markdown files under the current directory recursively.
- `watch <file.md> --enable` opt-ins one file at a time.
- `watch` and `watch-upload` only act on files explicitly enabled in config.
- `watch-upload <file.md>` is a one-shot upload intended for editor save hooks and uses the same cooldown rules as `watch`.
- Watch state is per file: each enabled file stores its own cooldown and `last_uploaded_at`.
- Concurrent saves of the same file are deduplicated with a per-file lock under `.notion-cli/locks/`; one upload runs and overlapping attempts exit with `sync already in progress`.
- Successful upload, download, and delete operations append timestamped entries to `.ns-cli/sync.log`.
- `download-sync` works from local file discovery and does not discover remote-only pages.
- When `upload` finds a single matching page, it archives that page and creates a new one instead of patching blocks in place.
- Downloaded Markdown is body-only; page properties and icon metadata are stored in `.notion-cli/pages/...json` sidecars.
- `download-all` run from `notes_root` can place unmatched pages at the root when no directory mapping applies, and fails per page if multiple mappings fit.

## Shell Completion

Load completion in your shell startup:

```bash
eval "$(ns completion zsh)"
```
