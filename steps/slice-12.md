# Slice 12: Status UX and Shell Autocomplete

Date: 2026-05-27

## Goal
Improve usability for post-MVP workflows by:
1. Adding shell autocomplete support so `ns status <file.md>` supports tab completion for markdown files.
2. Improving `ns status` output readability with clearer formatting and optional colorization.

## Scope
- Add `ns completion zsh` command that prints a zsh completion script.
- Include completion rules for:
  - top-level commands
  - `status|upload|download` file arguments (`*.md` completion)
- Improve `ns status` output formatting:
  - section heading
  - aligned, scan-friendly labels
  - ANSI colors only when stdout is a TTY

## Acceptance Criteria
- `ns completion zsh` exits 0 and prints a valid completion script containing `#compdef ns`.
- Completion script includes `.md` file completion for `status`, `upload`, and `download` args.
- `ns status <file.md>` output includes key/value lines for mapping and query intent in a readable structure.
- All existing tests remain green.
- New contract test validates completion output and status formatting.

## Test Plan
- Run contract suite slices 1,2,3,4,5,6,7,8,10,11 plus new slice 12.
- Verify no regression in command routing/help usage.

## Notes
- Colorization is conditional on TTY to keep CI and scripts machine-friendly.
