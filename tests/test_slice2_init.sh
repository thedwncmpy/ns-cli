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

canonical_path() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

if [[ ! -x "$CLI" ]]; then
  fail "missing executable: $CLI"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
notes_root="$tmp_dir/notes"
mkdir -p "$notes_root"
abs_notes_root="$(canonical_path "$notes_root")"

# Missing database-id should fail
set +e
out="$($CLI init --notes-root "$notes_root" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "--database-id is required"

# Missing notes-root should fail
set +e
out="$($CLI init --database-id db_123 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "--notes-root is required"

# Initial creation should succeed
set +e
out="$($CLI init --database-id db_123 --notes-root "$notes_root" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Initialized config"

config_path="$notes_root/.notion-cli/config.json"
[[ -f "$config_path" ]] || fail "expected config file at $config_path"

actual_db="$(jq -r '.database_id' "$config_path")"
[[ "$actual_db" == "db_123" ]] || fail "expected database_id db_123, got: $actual_db"

actual_root="$(jq -r '.notes_root' "$config_path")"
actual_root_canon="$(canonical_path "$actual_root")"
[[ "$actual_root_canon" == "$abs_notes_root" ]] || fail "expected notes_root $abs_notes_root, got: $actual_root_canon"
actual_title_prop="$(jq -r '.title_property' "$config_path")"
[[ "$actual_title_prop" == "Name" ]] || fail "expected default title_property Name, got: $actual_title_prop"

# Second run without force should fail and preserve file
before_contents="$(cat "$config_path")"
set +e
out="$($CLI init --database-id db_456 --notes-root "$notes_root" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "already exists"
after_contents="$(cat "$config_path")"
[[ "$before_contents" == "$after_contents" ]] || fail "config changed without --force"

# Run with force should overwrite
set +e
out="$($CLI init --database-id db_456 --notes-root "$notes_root" --force 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Initialized config"

actual_db="$(jq -r '.database_id' "$config_path")"
[[ "$actual_db" == "db_456" ]] || fail "expected overwritten database_id db_456, got: $actual_db"

# Explicit title property should be stored
set +e
out="$($CLI init --database-id db_789 --notes-root "$notes_root" --title-property Title --force 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Initialized config"

actual_title_prop="$(jq -r '.title_property' "$config_path")"
[[ "$actual_title_prop" == "Title" ]] || fail "expected explicit title_property Title, got: $actual_title_prop"

# Help should work
set +e
out="$($CLI init --help 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Usage: ns init"

echo "PASS: slice 2 init lifecycle"
