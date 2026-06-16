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
    fail "unexpected file content in $file; expected '$expected', got '$got'"
  fi
}

with_props() {
  local props="$1"
  local body="$2"
  printf '<!-- notion-properties\n%s\n-->\n\n%s' "$props" "$body"
}

assert_file_props_and_body() {
  local file="$1"
  local expected_props="$2"
  local expected_body="$3"
  local props body
  props="$(awk 'BEGIN{in_meta=0} NR==1 && $0=="<!-- notion-properties" {in_meta=1; next} in_meta && $0=="-->" {exit} in_meta {print}' "$file" | jq -S -c .)"
  body="$(awk 'BEGIN{in_meta=0; after=0} NR==1 && $0=="<!-- notion-properties" {in_meta=1; next} in_meta && $0=="-->" {in_meta=0; after=1; next} after && $0=="" {next} !in_meta {print}' "$file")"
  [[ "$props" == "$(printf '%s' "$expected_props" | jq -S -c .)" ]] || fail "unexpected properties in $file; expected $expected_props, got $props"
  [[ "$body" == "$expected_body" ]] || fail "unexpected body in $file; expected '$expected_body', got '$body'"
}

if [[ ! -x "$CLI" ]]; then
  fail "missing executable: $CLI"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
notes_root="$tmp_dir/notes"
mkdir -p "$notes_root/project"

$CLI init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && $CLI link project rel_123 relation_prop >/dev/null)

# Fake parser and API harness for deterministic contract tests.
bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/python3" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == "--reverse" ]]; then
  [[ -t 0 ]] || cat >/dev/null
  printf "# title\\nroundtrip-body"
else
  [[ -t 0 ]] || cat >/dev/null
  printf '[{"object":"block","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"roundtrip-body"}}]}}]'
fi
PYEOF
chmod +x "$bin_dir/python3"

cat > "$bin_dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf "%s\n" "$args" >> "${SLICE7_CURL_LOG:?}"

if [[ "$args" == *"/v1/databases/"*"/query"* ]]; then
  if [[ "$args" == *"note-roundtrip"* || "$args" == *"new-note"* ]]; then
    printf '{"results":[{"id":"page_1","properties":{"Name":{"id":"title","type":"title","title":[{"plain_text":"note-roundtrip"}]},"Status":{"id":"st","type":"select","select":{"name":"Active","color":"blue"}},"Done":{"id":"dn","type":"checkbox","checkbox":true},"relation_prop":{"id":"rel","type":"relation","relation":[{"id":"rel_123"}]}}}]}'
  else
    printf '{"results":[]}'
  fi
elif [[ "$args" == *"-X GET"*"/v1/blocks/page_1/children"* ]]; then
  printf '{"results":[{"id":"b1","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"roundtrip-body"}}]}}]}'
elif [[ "$args" == *"-X PATCH"*"/v1/blocks/page_1/children"* ]]; then
  printf '{"id":"page_1"}'
elif [[ "$args" == *"-X POST"*"/v1/pages"* ]]; then
  printf '{"id":"page_1"}'
else
  printf '{"results":[]}'
fi
CURL
chmod +x "$bin_dir/curl"

parser_stub="$tmp_dir/parser.py"
printf '# parser stub path marker\n' > "$parser_stub"

export PATH="$bin_dir:$PATH"
export NOTION_TOKEN="test_token"
export NOTION_PARSER_PATH="$parser_stub"
export SLICE7_CURL_LOG="$tmp_dir/curl.log"

assert_contains "$(cat "$notes_root/.notion-cli/config.json")" "\"relation_property\": \"relation_prop\""

note_rel="project/note-roundtrip.md"
note_path="$notes_root/$note_rel"
printf "seed\n" > "$note_path"

out="$(cd "$notes_root" && "$CLI" upload "$note_rel" 2>&1)"
assert_contains "$out" "Uploaded 'note-roundtrip' successfully."
assert_contains "$(cat "$SLICE7_CURL_LOG")" "\"property\": \"relation_prop\""

# Overwrite existing local file from remote.
printf "local-stale\n" > "$note_path"
out="$(cd "$notes_root" && "$CLI" download "$note_rel" 2>&1)"
assert_contains "$out" "Downloaded 'note-roundtrip'"
assert_file_props_and_body "$note_path" '{"Done":{"checkbox":true},"Status":{"select":{"name":"Active"}}}' $'# title\nroundtrip-body'
assert_contains "$(cat "$SLICE7_CURL_LOG")" "\"property\": \"relation_prop\""

# Create missing local file when remote exists.
missing_path="$notes_root/project/new-note.md"
out="$(cd "$notes_root" && "$CLI" download "project/new-note.md" 2>&1)"
assert_contains "$out" "Downloaded 'new-note'"
assert_file_props_and_body "$missing_path" '{"Done":{"checkbox":true},"Status":{"select":{"name":"Active"}}}' $'# title\nroundtrip-body'

# Create-path upload should honor mapped relation_property in page create payload.
create_note_path="$notes_root/project/create-path.md"
printf '%s' "$(with_props '{"Done":{"checkbox":true},"Status":{"select":{"name":"Active"}}}' "new-content")" > "$create_note_path"
out="$(cd "$notes_root" && "$CLI" upload "project/create-path.md" 2>&1)"
assert_contains "$out" "Uploaded 'create-path' successfully."
assert_contains "$(cat "$SLICE7_CURL_LOG")" "\"relation_prop\": {"
assert_contains "$(cat "$SLICE7_CURL_LOG")" "\"id\": \"rel_123\""
assert_contains "$(cat "$SLICE7_CURL_LOG")" "\"Status\": {"
assert_contains "$(cat "$SLICE7_CURL_LOG")" "\"name\": \"Active\""
assert_contains "$(cat "$SLICE7_CURL_LOG")" "\"Done\": {"
assert_contains "$(cat "$SLICE7_CURL_LOG")" "\"checkbox\": true"

echo "PASS: slice 7 roundtrip + contract harness"
