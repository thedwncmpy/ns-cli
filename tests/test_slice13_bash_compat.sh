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
bash_completion_out="$(bash -lc "\"$CLI\" completion bash" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$bash_completion_out" "complete -F _ns ns"
assert_contains "$bash_completion_out" "status|upload|download"
assert_contains "$bash_completion_out" "upload-all"
assert_contains "$bash_completion_out" "download-all"

set +e
help_out="$(bash -lc "\"$CLI\" help" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$help_out" "Usage: ns <command> [options]"

echo "PASS: slice 13 bash compatibility"
