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
mkdir -p "$notes_root/project"

# Bootstrap config + mapping for test preconditions.
$CLI init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && $CLI link project rel_123 notebook >/dev/null)

# Help should work
set +e
out="$($CLI download --help 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Usage: notion download"

# Missing file path should fail
set +e
out="$( (cd "$notes_root" && $CLI download) 2>&1 )"
code=$?
set -e
if [[ "$out" == *"not implemented"* ]]; then
  fail "slice-6 skeleton not wired: download still returns generic not implemented"
fi
assert_exit_code "$code" 1
assert_contains "$out" "<file.md>"

# Non-md extension should fail
printf 'x\n' > "$notes_root/project/bad.txt"
set +e
out="$( (cd "$notes_root" && $CLI download "$notes_root/project/bad.txt") 2>&1 )"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" ".md"

# Outside notes_root should fail
mkdir -p "$tmp_dir/outside"
printf 'x\n' > "$tmp_dir/outside/remote.md"
set +e
out="$( (cd "$notes_root" && $CLI download "$tmp_dir/outside/remote.md") 2>&1 )"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "inside"
assert_contains "$out" "notes_root"

# Unmapped first-level directory should fail
mkdir -p "$notes_root/unmapped"
set +e
out="$( (cd "$notes_root" && $CLI download "$notes_root/unmapped/file.md") 2>&1 )"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "mapping"

# Missing token should hard fail before network work
isolated_home="$tmp_dir/home"
mkdir -p "$isolated_home"
set +e
out="$({ HOME="$isolated_home" NOTION_TOKEN='' zsh -c "cd \"$notes_root\" && \"$CLI\" download \"$notes_root/project/remote.md\""; } 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "NOTION_TOKEN"

# NOTE: Implementation-phase checks (expected after slice 6 implementation)
# - If local file does not exist and one remote exact match exists, create it.
# - If local file exists and one remote exact match exists, overwrite it.
# - If no remote exact match exists, fail non-zero.
# - If multiple remote exact matches exist, fail non-zero with ambiguity guidance.

echo "PASS: slice 6 download guardrails"
