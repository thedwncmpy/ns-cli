#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$ROOT_DIR/lib/notion_parser.py"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "expected output to contain '$needle', got: $haystack"
  fi
}

assert_eq() {
  local got="$1"
  local expected="$2"
  if [[ "$got" != "$expected" ]]; then
    fail "expected: $expected"$'\n'"got: $got"
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ ! -f "$PARSER" ]]; then
  fail "missing parser: $PARSER"
fi

input_md="$tmp_dir/toggle.md"
cat > "$input_md" <<'EOF'
[TOC]

## [toggle] Collapsible H2
  Child under h2

### [toggle] Collapsible Section
	Paragraph inside toggle
  
  - Nested item

### Plain Section

#[toggle] invalid
EOF

json_out="$(python3 "$PARSER" "$input_md")"
assert_contains "$json_out" '"type": "table_of_contents"'
assert_contains "$json_out" '"type": "divider"'
assert_contains "$json_out" '"type": "heading_2"'
assert_contains "$json_out" '"is_toggleable": true'
assert_contains "$json_out" '"content": "Collapsible H2"'
assert_contains "$json_out" '"content": "Child under h2"'
assert_contains "$json_out" '"type": "heading_3"'
assert_contains "$json_out" '"is_toggleable": true'
assert_contains "$json_out" '"content": "Collapsible Section"'
assert_contains "$json_out" '"children": [{"object": "block", "type": "paragraph"'
assert_contains "$json_out" '"content": "Paragraph inside toggle"'
assert_contains "$json_out" '"type": "bulleted_list_item"'
assert_contains "$json_out" '"content": "Nested item"'
assert_contains "$json_out" '"is_toggleable": false'
assert_contains "$json_out" '"content": "Plain Section"'

reverse_in="$tmp_dir/blocks.json"
cat > "$reverse_in" <<'EOF'
[
  {
    "object": "block",
    "type": "table_of_contents",
    "table_of_contents": {}
  },
  {
    "object": "block",
    "type": "heading_1",
    "heading_1": {
      "rich_text": [
        {
          "plain_text": "Top Toggle",
          "annotations": {}
        }
      ],
      "is_toggleable": true,
      "children": [
        {
          "object": "block",
          "type": "paragraph",
          "paragraph": {
            "rich_text": [
              {
                "plain_text": "Paragraph inside h1 toggle",
                "annotations": {}
              }
            ]
          }
        }
      ]
    }
  },
  {
    "object": "block",
    "type": "heading_2",
    "heading_2": {
      "rich_text": [
        {
          "plain_text": "Mid Toggle",
          "annotations": {}
        }
      ],
      "is_toggleable": true,
      "children": [
        {
          "object": "block",
          "type": "paragraph",
          "paragraph": {
            "rich_text": [
              {
                "plain_text": "Paragraph inside h2 toggle",
                "annotations": {}
              }
            ]
          }
        }
      ]
    }
  },
  {
    "object": "block",
    "type": "heading_3",
    "heading_3": {
      "rich_text": [
        {
          "plain_text": "Collapsible Section",
          "annotations": {}
        }
      ],
      "is_toggleable": true,
      "children": [
        {
          "object": "block",
          "type": "paragraph",
          "paragraph": {
            "rich_text": [
              {
                "plain_text": "Paragraph inside toggle",
                "annotations": {}
              }
            ]
          }
        },
        {
          "object": "block",
          "type": "bulleted_list_item",
          "bulleted_list_item": {
            "rich_text": [
              {
                "plain_text": "Nested item",
                "annotations": {}
              }
            ]
          }
        }
      ]
    }
  },
  {
    "object": "block",
    "type": "heading_3",
    "heading_3": {
      "rich_text": [
        {
          "plain_text": "Plain Section",
          "annotations": {}
        }
      ],
      "is_toggleable": false
    }
  }
]
EOF

md_out="$(python3 "$PARSER" --reverse < "$reverse_in")"
expected_md=$'[TOC]\n\n---\n\n# [toggle] Top Toggle\n\n  Paragraph inside h1 toggle\n\n## [toggle] Mid Toggle\n\n  Paragraph inside h2 toggle\n\n### [toggle] Collapsible Section\n\n  Paragraph inside toggle\n\n  - Nested item\n\n### Plain Section'
assert_eq "$md_out" "$expected_md"

tab_input_md="$tmp_dir/toggle-tabs.md"
cat > "$tab_input_md" <<'EOF'
### [toggle] Collapsible Section
	Paragraph inside toggle
  
  - Nested item

### [toggle] Tab Section
	Paragraph with tab indent
	- Nested tab item
EOF

tab_json_out="$(python3 "$PARSER" "$tab_input_md")"
assert_contains "$tab_json_out" '"is_toggleable": true'
assert_contains "$tab_json_out" '"content": "Paragraph with tab indent"'
assert_contains "$tab_json_out" '"content": "Nested tab item"'

echo "PASS: slice 14 toggleable heading parser"
