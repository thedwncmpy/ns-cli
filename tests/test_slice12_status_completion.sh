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

set +e
completion_out="$($CLI completion zsh 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$completion_out" "#compdef ns"
assert_contains "$completion_out" "status|upload|download"
assert_contains "$completion_out" "_files -g \"*.md\""
assert_contains "$completion_out" "--title-property"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
notes_root="$tmp_dir/notes"
mkdir -p "$notes_root/project"

"$CLI" init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && "$CLI" link project rel_123 notebook >/dev/null)
printf 'hello\n' > "$notes_root/project/pretty.md"

set +e
status_out="$(cd "$notes_root" && "$CLI" status "project/pretty.md" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$status_out" "Status"
assert_contains "$status_out" "  File:"
assert_contains "$status_out" "  Mapping Dir: project"
assert_contains "$status_out" "  Title Prop: Name"
assert_contains "$status_out" "  Relation Page: rel_123"
assert_contains "$status_out" "  Query Filter:"

echo "PASS: slice 12 status formatting + zsh completion"
