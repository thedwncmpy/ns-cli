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
mkdir -p "$notes_root/project" "$notes_root/archive" "$tmp_dir/bin"

"$CLI" init --database-id db_test --notes-root "$notes_root" >/dev/null
(cd "$notes_root" && "$CLI" link project rel_project notebook >/dev/null)
(cd "$notes_root" && "$CLI" link archive rel_archive notebook >/dev/null)

printf 'body\n' > "$notes_root/project/rename-me.md"
mkdir -p "$notes_root/.ns-cli/pages/project"
printf '%s\n' '{"properties":{"Done":{"checkbox":true}},"icon":null}' > "$notes_root/.ns-cli/pages/project/rename-me.json"

config_path="$notes_root/.ns-cli/config.json"
tmp_cfg="$(mktemp)"
jq '.watch.files["project/rename-me.md"] = {"enabled": true, "cooldown_seconds": 30, "last_uploaded_at": 123}' "$config_path" >"$tmp_cfg"
mv "$tmp_cfg" "$config_path"

cat > "$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf "%s\n" "$args" >> "${SLICE25_CURL_LOG:?}"

if [[ "$args" == *"-X POST"*"/v1/databases/"*"/query"* ]]; then
  printf '{"results":[{"id":"page_rename","icon":null,"properties":{"Name":{"title":[{"plain_text":"rename-me"}]},"notebook":{"type":"relation","relation":[{"id":"rel_project"}]}}}],"has_more":false}'
elif [[ "$args" == *"-X PATCH"*"/v1/pages/page_rename"* ]]; then
  printf '{"id":"page_rename"}'
else
  printf '{"results":[],"has_more":false}'
fi
EOF
chmod +x "$tmp_dir/bin/curl"

export PATH="$tmp_dir/bin:$PATH"
export NOTION_TOKEN="test_token"
export SLICE25_CURL_LOG="$tmp_dir/curl.log"

set +e
help_out="$("$CLI" rename --help 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$help_out" "Usage: ns rename"

dry_run_out="$(cd "$notes_root" && "$CLI" rename --dry-run "project/rename-me.md" "archive/renamed-note.md" 2>&1)"
assert_contains "$dry_run_out" "Dry-run rename intent:"
assert_contains "$dry_run_out" "old_title: rename-me"
assert_contains "$dry_run_out" "new_title: renamed-note"
assert_contains "$dry_run_out" "patch remote page title/relation"
[[ -f "$notes_root/project/rename-me.md" ]] || fail "dry-run should not move markdown file"
[[ -f "$notes_root/.ns-cli/pages/project/rename-me.json" ]] || fail "dry-run should not move sidecar"

out="$(cd "$notes_root" && "$CLI" rename "project/rename-me.md" "archive/renamed-note.md" 2>&1)"
assert_contains "$out" "Renamed 'rename-me' to 'renamed-note' locally and remotely."
[[ ! -f "$notes_root/project/rename-me.md" ]] || fail "expected old markdown file removed"
[[ -f "$notes_root/archive/renamed-note.md" ]] || fail "expected new markdown file created"
[[ ! -f "$notes_root/.ns-cli/pages/project/rename-me.json" ]] || fail "expected old sidecar removed"
[[ -f "$notes_root/.ns-cli/pages/archive/renamed-note.json" ]] || fail "expected new sidecar created"
[[ "$(jq -r '.watch.files["archive/renamed-note.md"].enabled' "$config_path")" == "true" ]] || fail "expected watch state moved to new path"
[[ "$(jq -r '.watch.files["archive/renamed-note.md"].cooldown_seconds' "$config_path")" == "30" ]] || fail "expected watch cooldown preserved"
[[ "$(jq -r '.watch.files["archive/renamed-note.md"].last_uploaded_at' "$config_path")" == "123" ]] || fail "expected watch timestamp preserved"
[[ "$(jq -r '.watch.files["project/rename-me.md"] // empty' "$config_path")" == "" ]] || fail "expected old watch state removed"
assert_contains "$(cat "$SLICE25_CURL_LOG")" "-X PATCH https://api.notion.com/v1/pages/page_rename"
assert_contains "$(cat "$SLICE25_CURL_LOG")" '"content": "renamed-note"'
assert_contains "$(cat "$SLICE25_CURL_LOG")" '"id": "rel_archive"'

sync_log="$notes_root/.ns-cli/sync.log"
[[ -f "$sync_log" ]] || fail "expected sync log"
assert_contains "$(cat "$sync_log")" $'\trename\tarchive/renamed-note.md'

echo "PASS: slice 25 rename contract"
