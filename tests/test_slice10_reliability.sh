#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT_DIR/bin/notion"

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

if [[ ! -x "$CLI" ]]; then
  fail "missing executable: $CLI"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
notes_root="$tmp_dir/notes"
mkdir -p "$notes_root/project/deep/nested"

"$CLI" init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && "$CLI" link project rel_123 relation_prop >/dev/null)

bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/python3" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == "--reverse" ]]; then
  cat >/dev/null
  printf "# nested\nfrom-pagination"
else
  cat >/dev/null
  # 250 blocks to validate chunked append >100 boundaries
  jq -nc '[range(0;250) | {"object":"block","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":("line-" + (tostring))}}]}}]'
fi
PYEOF
chmod +x "$bin_dir/python3"

cat > "$bin_dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf "%s\n" "$args" >> "${SLICE10_CURL_LOG:?}"

state_file="${SLICE10_STATE:?}"
[ -f "$state_file" ] || echo 0 > "$state_file"
attempt="$(cat "$state_file")"

# first POST /pages returns transient error once; retry should recover
if [[ "$args" == *"-X POST"*"/v1/pages"* ]]; then
  if [[ "$attempt" == "0" ]]; then
    echo 1 > "$state_file"
    printf '{"object":"error","code":"service_unavailable","message":"try again"}'
  else
    printf '{"id":"page_new"}'
  fi
elif [[ "$args" == *"-X POST"*"/v1/databases/"*"/query"*"nested-note"* ]]; then
  printf '{"results":[{"id":"page_nested"}],"has_more":false}'
elif [[ "$args" == *"/v1/databases/"*"/query"* ]]; then
  if [[ "$args" == *"create-large"* ]]; then
    printf '{"results":[],"has_more":false}'
  else
    printf '{"results":[{"id":"page_existing"}],"has_more":false}'
  fi
elif [[ "$args" == *"-X GET"*"/v1/blocks/page_existing/children?start_cursor=cursor1"* ]]; then
  printf '{"results":[{"id":"b2"}],"has_more":false}'
elif [[ "$args" == *"-X GET"*"/v1/blocks/page_existing/children"* ]]; then
  printf '{"results":[{"id":"b1"}],"has_more":true,"next_cursor":"cursor1"}'
elif [[ "$args" == *"-X GET"*"/v1/blocks/page_nested/children?start_cursor=cursor1"* ]]; then
  printf '{"results":[{"id":"b4","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"p2"}}]}}],"has_more":false}'
elif [[ "$args" == *"-X GET"*"/v1/blocks/page_nested/children"* ]]; then
  printf '{"results":[{"id":"b3","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"p1"}}]}}],"has_more":true,"next_cursor":"cursor1"}'
elif [[ "$args" == *"-X DELETE"*"/v1/blocks/"* ]]; then
  printf '{"object":"block"}'
elif [[ "$args" == *"-X PATCH"*"/v1/blocks/page_existing/children"* ]]; then
  printf '{"id":"page_existing"}'
elif [[ "$args" == *"-X PATCH"*"/v1/blocks/page_new/children"* ]]; then
  printf '{"id":"page_new"}'
else
  printf '{"results":[],"has_more":false}'
fi
CURL
chmod +x "$bin_dir/curl"

parser_stub="$tmp_dir/parser.py"
printf '# parser stub\n' > "$parser_stub"

export PATH="$bin_dir:$PATH"
export NOTION_TOKEN="test_token"
export NOTION_PARSER_PATH="$parser_stub"
export SLICE10_CURL_LOG="$tmp_dir/curl.log"
export SLICE10_STATE="$tmp_dir/state"

printf "seed\n" > "$notes_root/project/create-large.md"
out="$(cd "$notes_root" && "$CLI" upload "project/create-large.md" 2>&1)"
assert_contains "$out" "Uploaded 'create-large' successfully."
create_post_count="$(grep -c -- "-X POST https://api.notion.com/v1/pages" "$SLICE10_CURL_LOG" || true)"
[[ "$create_post_count" -eq 2 ]] || fail "expected 2 POST /v1/pages calls due to retry, got $create_post_count"

# Existing page upload should fetch paginated children and delete both ids.
printf "seed2\n" > "$notes_root/project/existing.md"
out="$(cd "$notes_root" && "$CLI" upload "project/existing.md" 2>&1)"
assert_contains "$out" "Uploaded 'existing' successfully."
assert_contains "$(cat "$SLICE10_CURL_LOG")" "/v1/blocks/b1"
assert_contains "$(cat "$SLICE10_CURL_LOG")" "/v1/blocks/b2"

# Ensure chunking occurred: for 250 blocks on create path, one POST + two PATCH calls.
patch_count="$(grep -c -- "-X PATCH https://api.notion.com/v1/blocks/page_new/children" "$SLICE10_CURL_LOG" || true)"
[[ "$patch_count" -eq 2 ]] || fail "expected 2 PATCH calls for page_new, got $patch_count"

# Nested download should succeed and create parent directories while using paginated block fetch.
out="$(cd "$notes_root" && "$CLI" download "project/deep/nested/nested-note.md" 2>&1)"
assert_contains "$out" "Downloaded 'nested-note'"
[[ -f "$notes_root/project/deep/nested/nested-note.md" ]] || fail "expected nested download file"
assert_contains "$(cat "$SLICE10_CURL_LOG")" "page_nested/children?start_cursor=cursor1"

echo "PASS: slice 10 reliability hardening contract"
