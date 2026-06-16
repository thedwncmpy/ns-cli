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
mkdir -p "$notes_root"

"$CLI" init --database-id db_tasks --notes-root "$notes_root" --title-property Title >/dev/null
printf -- "- [ ] inbox\n" > "$notes_root/nt:ns-cli.md"

set +e
status_out="$(cd "$notes_root" && "$CLI" status "nt:ns-cli.md" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$status_out" "  Title Prop: Title"
assert_contains "$status_out" "\"property\": \"Title\""
assert_contains "$status_out" "\"equals\": \"nt:ns-cli\""

set +e
upload_out="$(cd "$notes_root" && "$CLI" upload --dry-run "nt:ns-cli.md" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$upload_out" "action: query exact title; update if found else create"

echo "PASS: slice 17 configurable title property"
