#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT_DIR/bin/ns"

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

assert_file_eq() {
  local file="$1"
  local expected="$2"
  local got
  got="$(cat "$file")"
  if [[ "$got" != "$expected" ]]; then
    fail "unexpected file content in $file"$'\n'"expected: $expected"$'\n'"got: $got"
  fi
}

if [[ ! -x "$CLI" ]]; then
  fail "missing executable: $CLI"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
notes_root="$tmp_dir/notes"
mkdir -p "$notes_root/project"

"$CLI" init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && "$CLI" link project rel_123 relation_prop >/dev/null)

bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf "%s\n" "$args" >> "${SLICE15_CURL_LOG:?}"

if [[ "$args" == *"-X POST"*"/v1/databases/"*"/query"* ]]; then
  printf '{"results":[{"id":"page_toggle"}],"has_more":false}'
elif [[ "$args" == *"-X GET"*"/v1/blocks/page_toggle/children"* ]]; then
  printf '{"results":[{"id":"toggle_1","type":"heading_3","has_children":true,"heading_3":{"rich_text":[{"plain_text":"Collapsible Section","annotations":{}}],"is_toggleable":true}},{"id":"plain_1","type":"paragraph","has_children":false,"paragraph":{"rich_text":[{"plain_text":"After toggle","annotations":{}}]}}],"has_more":false}'
elif [[ "$args" == *"-X GET"*"/v1/blocks/toggle_1/children"* ]]; then
  printf '{"results":[{"id":"child_1","type":"paragraph","has_children":false,"paragraph":{"rich_text":[{"plain_text":"Paragraph inside toggle","annotations":{}}]}},{"id":"child_2","type":"bulleted_list_item","has_children":false,"bulleted_list_item":{"rich_text":[{"plain_text":"Nested item","annotations":{}}]}}],"has_more":false}'
else
  printf '{"results":[],"has_more":false}'
fi
CURL
chmod +x "$bin_dir/curl"

export PATH="$bin_dir:$PATH"
export NOTION_TOKEN="test_token"
export SLICE15_CURL_LOG="$tmp_dir/curl.log"

out="$(cd "$notes_root" && "$CLI" download "project/toggle-note.md" 2>&1)"
assert_contains "$out" "Downloaded 'toggle-note'"
assert_contains "$(cat "$SLICE15_CURL_LOG")" "/v1/blocks/toggle_1/children"

expected_md=$'### [toggle] Collapsible Section\n\n  Paragraph inside toggle\n\n  - Nested item\n\nAfter toggle'
assert_file_eq "$notes_root/project/toggle-note.md" "$expected_md"

echo "PASS: slice 15 toggle roundtrip contract"
