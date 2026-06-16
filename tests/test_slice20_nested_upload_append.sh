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

[[ -x "$CLI" ]] || fail "missing executable: $CLI"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
notes_root="$tmp_dir/notes"
mkdir -p "$notes_root/project"

"$CLI" init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && "$CLI" link project rel_123 relation_prop >/dev/null)

cat > "$notes_root/project/nested.md" <<'EOF'
### [toggle] task: feature implementation (1)

  - [ ] build out the following features:

    - [ ] spotlight

    - [ ] tabs

      - [ ] implement full page browser
EOF

bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf "%s\n" "$args" >> "${SLICE20_CURL_LOG:?}"

if [[ "$args" == *"-X POST"*"/v1/databases/"*"/query"* ]]; then
  printf '{"results":[],"has_more":false}'
elif [[ "$args" == *"-X POST"*"/v1/pages"* ]]; then
  printf '{"id":"page_new"}'
elif [[ "$args" == *"-X PATCH"*"/v1/blocks/page_new/children"* ]]; then
  printf '{"results":[{"id":"heading_block"}],"has_more":false}'
elif [[ "$args" == *"-X PATCH"*"/v1/blocks/heading_block/children"* ]]; then
  printf '{"results":[{"id":"parent_todo"}],"has_more":false}'
elif [[ "$args" == *"-X PATCH"*"/v1/blocks/parent_todo/children"* ]]; then
  printf '{"results":[{"id":"spotlight_todo"},{"id":"tabs_todo"}],"has_more":false}'
elif [[ "$args" == *"-X PATCH"*"/v1/blocks/tabs_todo/children"* ]]; then
  printf '{"results":[{"id":"browser_todo"}],"has_more":false}'
else
  printf '{"results":[],"has_more":false}'
fi
CURL
chmod +x "$bin_dir/curl"

export PATH="$bin_dir:$PATH"
export NOTION_TOKEN="test_token"
export SLICE20_CURL_LOG="$tmp_dir/curl.log"

out="$(cd "$notes_root" && "$CLI" upload "project/nested.md" 2>&1)"
assert_contains "$out" "Uploaded 'nested' successfully."

log_content="$(cat "$SLICE20_CURL_LOG")"
assert_contains "$log_content" "/v1/blocks/page_new/children"
assert_contains "$log_content" "/v1/blocks/heading_block/children"
assert_contains "$log_content" "/v1/blocks/parent_todo/children"
assert_contains "$log_content" "/v1/blocks/tabs_todo/children"
assert_contains "$log_content" "\"content\": \"implement full page browser\""

echo "PASS: slice 20 nested upload append"
