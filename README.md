# ns-cli

`ns-cli` is a lightweight command-line tool for strict sync between local Markdown files and a Notion database.

The CLI keeps sync behavior deterministic:
- Exact filename-stem to Notion title matching
- First-level directory to relation mapping
- Strict failures on ambiguity and mismatch
- Single command surface: `ns`

## Install

<details>
<summary>Homebrew</summary>

Install from the public tap `thedwncmpy/homebrew-ns`:

```bash
brew tap thedwncmpy/homebrew-ns
brew install ns
```

You can also install directly from the tapped formula in one command:

```bash
brew install thedwncmpy/homebrew-ns/ns
```

Or install from the source repo checkout:

```bash
git clone https://github.com/thedwncmpy/ns-cli.git
cd ns-cli
brew install ./Formula/ns.rb
```
</details>

<details>
<summary>Requirements</summary>

- `zsh`
- `python3`
- `jq`
- `curl`
- A Notion integration token with access to the target database
</details>

## What It Does

<details open>
<summary>Overview</summary>

- Stores project config in `.ns-cli/config.json`
- Stores per-page Notion properties and icons in `.ns-cli/pages/**/*.json`
- Reads secrets from `NOTION_TOKEN` or `~/.config/ns-cli/secrets.zsh`
- Uploads local Markdown to Notion
- Downloads Notion pages into local Markdown files
- Deletes local Markdown files and archives matching Notion pages
- Supports both mapped subdirectories and root-level notes
</details>

## Getting Started

<details open>
<summary>1. Set up a root todo directory at ~/todo</summary>

Start with a notes root at `~/todo`:

```bash
mkdir -p ~/todo
printf '%s\n' '# Today' '' '- [ ] Buy milk' '- [ ] Ship README updates' > ~/todo/today.md
```

`ns` needs a Notion integration token with access to your target database. Export it in your shell:

```bash
export NOTION_TOKEN="secret_xxx"
```

Or store it in `~/.config/notion-cli/secrets.zsh`:

```bash
export NOTION_TOKEN="secret_xxx"
```

Environment variables take precedence over the secrets file.

Initialize the project:

```bash
ns init --database-id <notion_db_id> --notes-root ~/todo
```

If your Notion database title property is not `Name`, set it explicitly:

```bash
ns init --database-id <notion_db_id> --notes-root ~/todo --title-property Title
```

Check how `ns` resolves the file before uploading:

```bash
ns status ~/todo/today.md
```

Upload the note:

```bash
ns upload ~/todo/today.md
```

Upload everything under the current scope:

```bash
cd ~/todo
ns upload-sync
```

Download the same note back from Notion:

```bash
ns download ~/todo/today.md
```
</details>

<details>
<summary>2. Set up auto-upload from Neovim</summary>

Enable watch for the file you want to auto-upload:

```bash
ns watch ~/todo/today.md --enable --cooldown-seconds 60
```

You can inspect watch-enabled files by running the watcher:

```bash
ns watch
```

For editor-driven uploads, `watch-upload` is the one-shot command:

```bash
ns watch-upload ~/todo/today.md
```

Add this autocommand to your Neovim config:

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

On save, Neovim will surface the real `ns watch-upload` output, for example:

```text
Change detected: today.md
Uploaded 'today' successfully.
```

If you save again before cooldown expires, `ns` will skip the upload. Other integrations coming soon.
</details>

<details>
<summary>3. Add a subdirectory config with ns link</summary>

Root-level files in `~/todo` do not need a mapping. Use `ns link` when you want a first-level subdirectory to map to a Notion relation.

```bash
mkdir -p ~/todo/work
printf '%s\n' '# Sprint Tasks' '' '- [ ] Review PRs' '- [ ] Ship release notes' > ~/todo/work/sprint.md
```

Link the `work` subdirectory to a relation page and property in your database:

```bash
cd ~/todo
ns link work <relation_page_id> <relation_property>
```

Now inspect the resolved sync behavior:

```bash
ns status ~/todo/work/sprint.md
```

Upload the linked note:

```bash
ns upload ~/todo/work/sprint.md
```

That gives users a simple mental model:

- `~/todo/today.md` is a root-level note and syncs without a directory mapping
- `~/todo/work/sprint.md` uses the `work` mapping created by `ns link`

If you want to inspect the generated project config directly:

```bash
cat ~/todo/.notion-cli/config.json
```

Example shape after `ns init` and `ns link`:

```json
{
  "version": 1,
  "database_id": "<notion_db_id>",
  "notes_root": "/Users/you/todo",
  "title_property": "Name",
  "mappings": {
    "work": {
      "relation_page_id": "<relation_page_id>",
      "relation_property": "<relation_property>"
    }
  }
}
```
</details>

<details>
<summary>4. Create a simple note with links and toggles</summary>

Create a note that uses toggle headings and Notion page links:

```bash
cat > ~/todo/work/roadmap.md <<'EOF'
# [toggle] Weekly Plan

  Wrap up the current tasks.

  - [ ] Finish the CLI docs
  - [ ] Review todo sync flow

## References

[[link_to_page page_id:12345678-1234-1234-1234-123456789abc]]
EOF
```

Inspect the sync target:

```bash
ns status ~/todo/work/roadmap.md
```

Upload it:

```bash
ns upload ~/todo/work/roadmap.md
```

This is the markdown shape `ns` already understands for:

- Toggleable headings like `# [toggle] Weekly Plan`
- Nested content under toggles with two-space indentation
- Link blocks like `[[link_to_page page_id:...]]`
</details>

## Command Overview

<details>
<summary>CLI commands</summary>

```bash
ns init --database-id <id> --notes-root <path> [--title-property <name>] [--force]
ns link <subdir> <relation_page_id> <relation_property> [--force]
ns status [<file.md>]
ns upload [--dry-run] <file.md>
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
</details>

## Markdown Notes

<details>
<summary>Supported markdown blocks</summary>

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
</details>

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

- `watch <file.md> --enable` opt-ins one file at a time.
- `watch` and `watch-upload` only act on files explicitly enabled in config.
- `watch-upload <file.md>` is a one-shot upload intended for editor save hooks and uses the same cooldown rules as `watch`.
- Watch state is per file: each enabled file stores its own cooldown and `last_uploaded_at`.
- Concurrent saves of the same file are deduplicated with a per-file lock under `.notion-cli/locks/`; one upload runs and overlapping attempts exit with `sync already in progress`.
- Successful upload, download, and delete operations append timestamped entries to `.ns-cli/sync.log` using local time with timezone offset.
- `download-sync` works from local file discovery and does not discover remote-only pages.
- When `upload` finds a single matching page, it archives that page and creates a new one instead of patching blocks in place.
- Downloaded Markdown is body-only; page properties and icon metadata are stored in `.notion-cli/pages/...json` sidecars.
- `download-all` is scope-aware:
- Run from `notes_root`, it queries the full database scope. Pages that match one mapping are written into that mapped subdirectory, unmatched pages are written at the root of `notes_root`, and pages matching multiple mappings fail for that page.
- Run from a linked subdirectory under `notes_root`, it queries only the pages related to that subdirectory's mapping and writes them into that subdirectory.

## Shell Completion

Load completion in your shell startup:

```bash
eval "$(ns completion zsh)"
```
