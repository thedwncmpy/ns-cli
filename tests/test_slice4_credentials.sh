#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/lib/notion_cli.zsh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local got="$1"
  local expected="$2"
  if [[ "$got" != "$expected" ]]; then
    fail "expected '$expected', got '$got'"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "expected output to contain '$needle', got: $haystack"
  fi
}

run_zsh() {
  zsh -c "source '$LIB'; $1"
}

tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home"' EXIT

# 1) env var precedence over secrets file
out="$({
  HOME="$tmp_home" NOTION_TOKEN="env-token" run_zsh 'mkdir -p ~/.config/notion-cli; echo "export NOTION_TOKEN=file-token" > ~/.config/notion-cli/secrets.zsh; notion_load_token'
} 2>&1)" || true
if [[ "$out" == *"not implemented"* ]]; then
  fail "slice-4 skeleton still unimplemented for env precedence test"
fi
assert_eq "$out" "env-token"

# 2) secrets file fallback when env missing
out="$({
  HOME="$tmp_home" run_zsh 'unset NOTION_TOKEN; mkdir -p ~/.config/notion-cli; echo "export NOTION_TOKEN=file-token" > ~/.config/notion-cli/secrets.zsh; notion_load_token'
} 2>&1)" || true
if [[ "$out" == *"not implemented"* ]]; then
  fail "slice-4 skeleton still unimplemented for file fallback test"
fi
assert_eq "$out" "file-token"

# 3) hard fail + actionable message when token missing
set +e
out="$({ HOME="$tmp_home" run_zsh 'unset NOTION_TOKEN; rm -f ~/.config/notion-cli/secrets.zsh; notion_require_token'; } 2>&1)"
code=$?
set -e
if [[ "$out" == *"not implemented"* ]]; then
  fail "slice-4 skeleton still unimplemented for missing-token error test"
fi
[[ "$code" -ne 0 ]] || fail "expected non-zero when token is missing"
assert_contains "$out" "NOTION_TOKEN"
assert_contains "$out" "secrets.zsh"

echo "PASS: slice 4 credential loading"
