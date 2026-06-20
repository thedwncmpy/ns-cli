#!/usr/bin/env bash
# Standard bash safety settings: 
# -e: exit on error
# -u: error on unset variables
# -o pipefail: catch errors in piped commands
set -euo pipefail

# Determine the absolute path to the project root and the CLI binary
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT_DIR/bin/ns"

# Utility: print failure message and exit with non-zero status
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Utility: assert that a string contains a specific substring
assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "expected output to contain '$needle', got: $haystack"
  fi
}

# Utility: assert that the exit code matches the expected value
assert_exit_code() {
  local got="$1"
  local expected="$2"
  if [[ "$got" -ne "$expected" ]]; then
    fail "expected exit code $expected, got $got"
  fi
}

# Ensure the ns CLI binary exists and is executable before running tests
if [[ ! -x "$CLI" ]]; then
  fail "missing executable: $CLI"
fi

# Test Case: Running 'ns' with no arguments should show usage and fail
set +e # Temporarily disable exit-on-error to capture the failure code
out="$($CLI 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "Usage: ns <command>"

# Test Case: Running 'ns help' should show commands and succeed
set +e
out="$($CLI help 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$out" "Commands:"
assert_contains "$out" "upload"
assert_contains "$out" "upload-all"
assert_contains "$out" "upload-sync"
assert_contains "$out" "watch"
assert_contains "$out" "watch-upload"
assert_contains "$out" "download"
assert_contains "$out" "delete"
assert_contains "$out" "download-all"
assert_contains "$out" "download-sync"
assert_contains "$out" "status"

# Test Case: Running an unrecognized command should show an error and fail
set +e
out="$($CLI frob 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$out" "Unknown command: frob"

# Test Case: Smoke tests for command dispatching
# Ensures that 'init', 'link', 'upload', and 'download' are correctly routed 
# to their respective handlers when the --help flag is used.
for cmd in init link status upload upload-all upload-sync watch watch-upload download delete download-all download-sync; do
  set +e
  out="$($CLI "$cmd" --help 2>&1)"
  code=$?
  set -e
  assert_exit_code "$code" 0
  assert_contains "$out" "Usage: ns $cmd"
done

echo "PASS: slice 1 router contract"
