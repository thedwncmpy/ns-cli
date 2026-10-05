#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$ROOT_DIR/lib/notion_parser.py"

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

cat > "$tmp_file" <<'EOF'
# thursday

- [x] a task with a long description
  that wraps at two spaces
    and then wraps at four spaces

# friday

- [x] friday task

# saturday

- [x] saturday task

# sunday

- [x] sunday task
EOF

parsed="$(python3 "$PARSER" "$tmp_file")"
headings="$(printf '%s' "$parsed" | jq -c '[.[] | select(.type == "heading_1") | .heading_1.rich_text[0].text.content]')"
[[ "$headings" == '["thursday","friday","saturday","sunday"]' ]] || {
  echo "FAIL: parser stopped before the end of the week: $headings" >&2
  exit 1
}

printf '%s' "$parsed" | jq -e '
  .[1].to_do.children[0].paragraph.rich_text
  | map(.text.content) | join("")
  | contains("and then wraps at four spaces")
' >/dev/null

echo "PASS: parser handles wrapped weekly tasks"
