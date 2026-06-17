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
mkdir -p "$notes_root/project/deep"

"$CLI" init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && "$CLI" link project rel_123 relation_prop >/dev/null)

printf 'stale\n' > "$notes_root/project/alpha.md"
printf 'stale\n' > "$notes_root/project/deep/beta.md"
printf 'ignore\n' > "$notes_root/project/deep/ignore.txt"

bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/python3" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == "--reverse" ]]; then
  blocks="$(cat)"
  if [[ "$blocks" == *"alpha-body"* ]]; then
    printf "alpha-body"
  elif [[ "$blocks" == *"beta-body"* ]]; then
    printf "beta-body"
  else
    printf "unknown-body"
  fi
else
  printf '[]'
fi
PYEOF
chmod +x "$bin_dir/python3"

cat > "$bin_dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf "%s\n" "$args" >> "${SLICE18_CURL_LOG:?}"

if [[ "$args" == *"-X POST"*"/v1/databases/"*"/query"*'"equals": "alpha"'* ]]; then
  printf '{"results":[{"id":"page_alpha","properties":{"Name":{"id":"title","type":"title","title":[{"plain_text":"alpha"}]},"relation_prop":{"id":"rel","type":"relation","relation":[{"id":"rel_123"}]}}}],"has_more":false}'
elif [[ "$args" == *"-X POST"*"/v1/databases/"*"/query"*'"equals": "beta"'* ]]; then
  printf '{"results":[{"id":"page_beta","properties":{"Name":{"id":"title","type":"title","title":[{"plain_text":"beta"}]},"relation_prop":{"id":"rel","type":"relation","relation":[{"id":"rel_123"}]}}}],"has_more":false}'
elif [[ "$args" == *"-X GET"*"/v1/blocks/page_alpha/children"* ]]; then
  printf '{"results":[{"id":"a1","type":"paragraph","paragraph":{"rich_text":[{"plain_text":"alpha-body","annotations":{}}]}}],"has_more":false}'
elif [[ "$args" == *"-X GET"*"/v1/blocks/page_beta/children"* ]]; then
  printf '{"results":[{"id":"b1","type":"paragraph","paragraph":{"rich_text":[{"plain_text":"beta-body","annotations":{}}]}}],"has_more":false}'
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
export SLICE18_CURL_LOG="$tmp_dir/curl.log"

set +e
help_out="$("$CLI" download-sync --help 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$help_out" "Usage: ns download-sync"

set +e
out="$(cd "$notes_root" && "$CLI" download-sync 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Downloaded 'alpha'"
assert_contains "$out" "Downloaded 'beta'"
assert_contains "$out" "Processed 2 markdown file(s)."

[[ "$(cat "$notes_root/project/alpha.md")" == "alpha-body" ]] || fail "expected alpha.md to be refreshed"
[[ "$(cat "$notes_root/project/deep/beta.md")" == "beta-body" ]] || fail "expected beta.md to be refreshed"

query_count="$(grep -c -- "/v1/databases/db_test/query" "$SLICE18_CURL_LOG" || true)"
[[ "$query_count" -eq 2 ]] || fail "expected 2 database queries, got $query_count"

empty_dir="$tmp_dir/empty"
mkdir -p "$empty_dir"
set +e
empty_out="$(cd "$empty_dir" && "$CLI" download-sync 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$empty_out" "no markdown files found"

echo "PASS: slice 18 download-all"
