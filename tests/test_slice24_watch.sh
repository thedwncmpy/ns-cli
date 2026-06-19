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
(cd "$notes_root" && "$CLI" link project rel_123 relation_prop >/dev/null)

config_path="$notes_root/.ns-cli/config.json"
[[ "$(jq -r '.watch.auto_upload_on_save' "$config_path")" == "false" ]] || fail "expected auto upload disabled by default"
[[ "$(jq -r '.watch.cooldown_seconds' "$config_path")" == "60" ]] || fail "expected default cooldown of 60"

printf 'alpha\n' > "$notes_root/project/watch-note.md"

bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"

cat > "$bin_dir/python3" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == *"notion_parser.py" ]]; then
  printf '[{"object":"block","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"body"}}]}}]'
else
  exec /usr/bin/python3 "$@"
fi
PYEOF
chmod +x "$bin_dir/python3"

cat > "$bin_dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf "%s\n" "$args" >> "${SLICE24_CURL_LOG:?}"

if [[ "$args" == *"-X POST"*"/v1/databases/"*"/query"* ]]; then
  printf '{"results":[],"has_more":false}'
elif [[ "$args" == *"-X POST"*"/v1/pages"* ]]; then
  printf '{"id":"page_new"}'
elif [[ "$args" == *"-X PATCH"*"/v1/blocks/"*"/children"* ]]; then
  printf '{"results":[{"id":"block_1"}]}'
else
  printf '{"results":[],"has_more":false}'
fi
CURL
chmod +x "$bin_dir/curl"

export PATH="$bin_dir:$PATH"
export NOTION_TOKEN="test_token"
export SLICE24_CURL_LOG="$tmp_dir/curl.log"

set +e
watch_out="$(
  cd "$notes_root"
  NS_WATCH_POLL_SECONDS=1 NS_WATCH_MAX_LOOPS=6 "$CLI" watch --enable --cooldown-seconds 60 >"$tmp_dir/watch.log" 2>&1 &
  watch_pid=$!
  sleep 1.2
  printf 'beta\n' >> "$notes_root/project/watch-note.md"
  sleep 2.2
  printf 'gamma\n' >> "$notes_root/project/watch-note.md"
  wait "$watch_pid"
  cat "$tmp_dir/watch.log"
)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$watch_out" "Updated watch settings: enabled=true cooldown=60s"
assert_contains "$watch_out" "Change detected: project/watch-note.md"
assert_contains "$watch_out" "Uploaded 'watch-note' successfully."
assert_contains "$watch_out" "Skipping 'project/watch-note.md'; cooldown active"

query_count="$(grep -c -- "/v1/databases/db_test/query" "$SLICE24_CURL_LOG" || true)"
[[ "$query_count" -eq 1 ]] || fail "expected 1 database query due to cooldown, got $query_count"

[[ "$(jq -r '.watch.auto_upload_on_save' "$config_path")" == "true" ]] || fail "expected auto upload enabled in config"
[[ "$(jq -r '.sync_state.uploads["project/watch-note.md"].last_uploaded_at // 0' "$config_path")" -gt 0 ]] || fail "expected last upload time recorded"

set +e
disable_out="$(cd "$notes_root" && "$CLI" watch --disable 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$disable_out" "Updated watch settings: enabled=false cooldown=60s"

echo "PASS: slice 24 watch cooldown"
