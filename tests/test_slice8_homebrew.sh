#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMULA="$ROOT_DIR/Formula/ns.rb"
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

[[ -f "$FORMULA" ]] || fail "missing formula: $FORMULA"
[[ -x "$CLI" ]] || fail "missing executable: $CLI"

formula_text="$(cat "$FORMULA")"
assert_contains "$formula_text" "class Ns < Formula"
if [[ "$formula_text" != *"bin.install \"bin/ns\""* && "$formula_text" != *"bin.install rewritten => \"ns\""* ]]; then
  fail "expected formula to install ns binary (bin.install \"bin/ns\" or rewritten launcher)"
fi
assert_contains "$formula_text" "def caveats"
assert_contains "$formula_text" "eval \"\$(ns completion zsh)\""
assert_contains "$formula_text" "eval \"\$(ns completion bash)\""
assert_contains "$formula_text" "depends_on \"jq\""
assert_contains "$formula_text" "depends_on \"fswatch\""
assert_contains "$formula_text" "depends_on \"python@3.12\""
assert_contains "$formula_text" "inreplace libexec/\"lib/common.zsh\", \"__NS_VERSION__\", version.to_s"
if [[ ! "$formula_text" =~ sha256[[:space:]]\"[0-9a-f]{64}\" ]]; then
  fail "expected formula to contain tarball sha256 like: sha256 \"<64-hex>\""
fi

set +e
out="$(ruby -c "$FORMULA" 2>&1)"
code=$?
set -e
[[ "$code" -eq 0 ]] || fail "formula ruby syntax invalid: $out"

set +e
help_out="$($CLI help 2>&1)"
help_code=$?
set -e
[[ "$help_code" -eq 0 ]] || fail "ns help failed"
assert_contains "$help_out" "Usage: ns <command>"

echo "PASS: slice 8 homebrew packaging contract"
