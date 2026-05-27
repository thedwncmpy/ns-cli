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
mkdir -p "$notes_root/project"

"$CLI" init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && "$CLI" link project rel_123 notebook >/dev/null)
printf 'hello\n' > "$notes_root/project/p3.md"

set +e
out="$(cd "$notes_root" && "$CLI" status "project/p3.md" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Status"
assert_contains "$out" "Mapping Dir: project"
assert_contains "$out" "Relation Page: rel_123"
assert_contains "$out" "Relation Prop: notebook"
assert_contains "$out" "Query Filter:"

set +e
out="$(cd "$notes_root" && NOTION_TOKEN='' "$CLI" --help 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0

set +e
out="$(cd "$notes_root" && NOTION_TOKEN='' "$CLI" upload --dry-run "project/p3.md" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Dry-run upload intent:"
assert_contains "$out" "action: query exact title+relation; update if found else create"

set +e
out="$(cd "$notes_root" && NOTION_TOKEN='' "$CLI" download --dry-run "project/p3.md" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Dry-run download intent:"
assert_contains "$out" "action: query exact title+relation; overwrite local file if single match"

echo "PASS: slice 11 post-mvp status + dry-run"
