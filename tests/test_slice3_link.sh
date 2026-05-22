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
mkdir -p "$notes_root"

# 1. Setup: Init project
"$CLI" init --database-id db_123 --notes-root "$notes_root" > /dev/null

# 2. Test: Link without arguments should fail
cd "$notes_root"
set +e
out="$($CLI link 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "Usage: notion link"

# 3. Test: Link non-existent directory should fail
set +e
out="$($CLI link missing_dir page_123 notebook 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "directory does not exist"

# 4. Test: Link valid directory should succeed
mkdir "projects"
set +e
out="$($CLI link projects page_projects notebook 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Linked 'projects' to 'page_projects' using property 'notebook'"

config_path=".notion-cli/config.json"
actual_mapping="$(jq -r '.mappings.projects.relation_page_id' "$config_path")"
[[ "$actual_mapping" == "page_projects" ]] || fail "expected mapping page_projects, got: $actual_mapping"
actual_property="$(jq -r '.mappings.projects.relation_property' "$config_path")"
[[ "$actual_property" == "notebook" ]] || fail "expected mapping property notebook, got: $actual_property"

# 5. Test: Link already mapped directory without --force should fail
set +e
out="$($CLI link projects page_new notebook 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "already mapped"
actual_mapping="$(jq -r '.mappings.projects.relation_page_id' "$config_path")"
[[ "$actual_mapping" == "page_projects" ]] || fail "mapping changed without --force"

# 6. Test: Link already mapped directory with --force should succeed
set +e
out="$($CLI link projects page_new tasks --force 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Linked 'projects' to 'page_new' using property 'tasks'"
actual_mapping="$(jq -r '.mappings.projects.relation_page_id' "$config_path")"
[[ "$actual_mapping" == "page_new" ]] || fail "mapping did not change with --force"
actual_property="$(jq -r '.mappings.projects.relation_property' "$config_path")"
[[ "$actual_property" == "tasks" ]] || fail "mapping property did not change with --force"

# 7. Test: Link when NOT in a project directory should fail
mkdir -p "$tmp_dir/other"
cd "$tmp_dir/other"
set +e
out="$($CLI link sub page_sub notebook 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "No project config found"

echo "PASS: slice 3 link workflow"
