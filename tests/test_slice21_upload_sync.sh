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

assert_exit_code() {
  local got="$1"
  local expected="$2"
  if [[ "$got" -ne "$expected" ]]; then
    fail "expected exit code $expected, got $got"
  fi
}

[[ -x "$CLI" ]] || fail "missing executable: $CLI"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
notes_root="$tmp_dir/notes"
mkdir -p "$notes_root/project/deep" "$notes_root/project/other"

"$CLI" init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && "$CLI" link project rel_123 relation_prop >/dev/null)

printf 'alpha\n' > "$notes_root/project/deep/alpha.md"
printf 'beta\n' > "$notes_root/project/deep/beta.md"
printf 'gamma\n' > "$notes_root/project/other/gamma.md"
printf 'skip\n' > "$notes_root/project/deep/skip.txt"

bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/python3" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == *"notion_parser.py" ]]; then
  printf '[{"object":"block","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"body"}}]}}]'
else
  exec /usr/bin/python3 "$@"
fi
PYEOF
chmod +x "$bin_dir/python3"

cat > "$bin_dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf "%s\n" "$args" >> "${SLICE21_CURL_LOG:?}"

if [[ "$args" == *"-X POST"*"/v1/databases/"*"/query"*'"equals":"alpha"'* ]]; then
  printf '{"results":[],"has_more":false}'
elif [[ "$args" == *"-X POST"*"/v1/databases/"*"/query"*'"equals":"beta"'* ]]; then
  printf '{"results":[],"has_more":false}'
elif [[ "$args" == *"-X POST"*"/v1/pages"* ]]; then
  printf '{"id":"page_new"}'
elif [[ "$args" == *"-X PATCH"*"/v1/blocks/"*"/children"* ]]; then
  printf '{"results":[{"id":"block_1"}]}'
else
  printf '{"results":[],"has_more":false}'
fi
CURL
chmod +x "$bin_dir/curl"

export PATH="$bin_dir:$PATH"
export NOTION_TOKEN="test_token"
export SLICE21_CURL_LOG="$tmp_dir/curl.log"

set +e
help_out="$("$CLI" upload-sync --help 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$help_out" "Usage: ns upload-sync"

set +e
out="$(cd "$notes_root/project/deep" && "$CLI" upload-sync 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Uploaded 'alpha' successfully."
assert_contains "$out" "Uploaded 'beta' successfully."
assert_contains "$out" "Processed 2 markdown file(s)."

query_count="$(grep -c -- "/v1/databases/db_test/query" "$SLICE21_CURL_LOG" || true)"
[[ "$query_count" -eq 2 ]] || fail "expected 2 database queries, got $query_count"

if grep -q '"equals":"gamma"' "$SLICE21_CURL_LOG"; then
  fail "upload-sync should not upload sibling directory markdown files"
fi

empty_dir="$tmp_dir/empty"
mkdir -p "$empty_dir"
set +e
empty_out="$(cd "$empty_dir" && "$CLI" upload-sync 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$empty_out" "no markdown files found"

echo "PASS: slice 21 upload-sync"
