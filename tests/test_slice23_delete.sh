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

if [[ ! -x "$CLI" ]]; then
  fail "missing executable: $CLI"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
notes_root="$tmp_dir/notes"
mkdir -p "$notes_root/project" "$tmp_dir/bin"

"$CLI" init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && "$CLI" link project rel_123 notebook >/dev/null)

printf 'body\n' > "$notes_root/project/delete-me.md"
mkdir -p "$notes_root/.notion-cli/pages/project"
printf '%s\n' '{"properties":{"Done":{"checkbox":true}},"icon":null}' > "$notes_root/.notion-cli/pages/project/delete-me.json"

cat > "$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf "%s\n" "$args" >> "${SLICE23_CURL_LOG:?}"

if [[ "$args" == *"-X POST"*"/v1/databases/"*"/query"* ]]; then
  printf '{"results":[{"id":"page_delete_me"}],"has_more":false}'
elif [[ "$args" == *"-X PATCH"*"/v1/pages/page_delete_me"* ]]; then
  printf '{"id":"page_delete_me","archived":true}'
else
  printf '{"results":[],"has_more":false}'
fi
EOF
chmod +x "$tmp_dir/bin/curl"

export PATH="$tmp_dir/bin:$PATH"
export NOTION_TOKEN="test_token"
export SLICE23_CURL_LOG="$tmp_dir/curl.log"

set +e
out="$("$CLI" delete --help 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Usage: ns delete"

dry_run_out="$(cd "$notes_root" && "$CLI" delete --dry-run "project/delete-me.md" 2>&1)"
assert_contains "$dry_run_out" "Dry-run delete intent:"
assert_contains "$dry_run_out" "archive remote page and delete local file"
[[ -f "$notes_root/project/delete-me.md" ]] || fail "dry-run should not delete markdown file"
[[ -f "$notes_root/.notion-cli/pages/project/delete-me.json" ]] || fail "dry-run should not delete sidecar"

out="$(cd "$notes_root" && "$CLI" delete "project/delete-me.md" 2>&1)"
assert_contains "$out" "Deleted 'delete-me' locally and archived the remote page."
[[ ! -f "$notes_root/project/delete-me.md" ]] || fail "expected markdown file to be deleted"
[[ ! -f "$notes_root/.notion-cli/pages/project/delete-me.json" ]] || fail "expected sidecar to be deleted"
assert_contains "$(cat "$SLICE23_CURL_LOG")" "-X PATCH https://api.notion.com/v1/pages/page_delete_me"

echo "PASS: slice 23 delete contract"
