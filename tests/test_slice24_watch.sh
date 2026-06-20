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
[[ "$(jq -r '.watch.default_cooldown_seconds' "$config_path")" == "60" ]] || fail "expected default cooldown of 60"
[[ "$(jq -r '.watch.files // {} | length' "$config_path")" == "0" ]] || fail "expected no watched files by default"

printf 'alpha\n' > "$notes_root/project/watch-note.md"
printf 'beta\n' > "$notes_root/project/ignored.md"

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
no_files_out="$(cd "$notes_root" && "$CLI" watch 2>&1)"
code=$?
set -e
assert_exit_code "$code" 1
assert_contains "$no_files_out" "no files have watch enabled"

set +e
enable_out="$(cd "$notes_root" && "$CLI" watch "project/watch-note.md" --enable --cooldown-seconds 60 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$enable_out" "Updated watch settings for 'project/watch-note.md': enabled=true cooldown=60s"

[[ "$(jq -r '.watch.files["project/watch-note.md"].enabled' "$config_path")" == "true" ]] || fail "expected watched file enabled"
[[ "$(jq -r '.watch.files["project/watch-note.md"].cooldown_seconds' "$config_path")" == "60" ]] || fail "expected watched file cooldown"

set +e
watch_upload_disabled_out="$(cd "$notes_root" && "$CLI" watch-upload "project/ignored.md" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$watch_upload_disabled_out" "Watch disabled for 'project/ignored.md'; skipping upload."

set +e
watch_out="$(
  cd "$notes_root"
  NS_WATCH_POLL_SECONDS=1 NS_WATCH_MAX_LOOPS=6 "$CLI" watch >"$tmp_dir/watch.log" 2>&1 &
  watch_pid=$!
  sleep 1.2
  printf 'change1\n' >> "$notes_root/project/watch-note.md"
  printf 'ignore1\n' >> "$notes_root/project/ignored.md"
  sleep 2.2
  printf 'change2\n' >> "$notes_root/project/watch-note.md"
  printf 'ignore2\n' >> "$notes_root/project/ignored.md"
  wait "$watch_pid"
  cat "$tmp_dir/watch.log"
)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$watch_out" "Watching 1 enabled markdown file(s)"
assert_contains "$watch_out" "Change detected: project/watch-note.md"
assert_contains "$watch_out" "Uploaded 'watch-note' successfully."
assert_contains "$watch_out" "Skipping 'project/watch-note.md'; cooldown active"

query_count="$(grep -c -- "/v1/databases/db_test/query" "$SLICE24_CURL_LOG" || true)"
[[ "$query_count" -eq 1 ]] || fail "expected 1 database query due to cooldown, got $query_count"
if grep -q '"equals":"ignored"' "$SLICE24_CURL_LOG"; then
  fail "did not expect ignored.md to be uploaded"
fi

[[ "$(jq -r '.watch.files["project/watch-note.md"].last_uploaded_at // 0' "$config_path")" -gt 0 ]] || fail "expected last upload time recorded"

sync_log="$notes_root/.ns-cli/sync.log"
[[ -f "$sync_log" ]] || fail "expected sync log to be created"
sync_log_out="$(cat "$sync_log")"
assert_contains "$sync_log_out" $'\tupload\tproject/watch-note.md'
if ! grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$sync_log"; then
  fail "expected sync log entries to start with an ISO-8601 timestamp"
fi

printf 'gamma\n' > "$notes_root/project/fast-save.md"
set +e
fast_enable_out="$(cd "$notes_root" && "$CLI" watch "project/fast-save.md" --enable --cooldown-seconds 0 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$fast_enable_out" "Updated watch settings for 'project/fast-save.md': enabled=true cooldown=0s"

set +e
fast_watch_out="$(
  cd "$notes_root"
  NS_WATCH_POLL_SECONDS=1 NS_WATCH_MAX_LOOPS=3 "$CLI" watch >"$tmp_dir/fast-watch.log" 2>&1 &
  watch_pid=$!
  sleep 0.2
  printf 'delta\n' >> "$notes_root/project/fast-save.md"
  wait "$watch_pid"
  cat "$tmp_dir/fast-watch.log"
)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$fast_watch_out" "Change detected: project/fast-save.md"
assert_contains "$fast_watch_out" "Uploaded 'fast-save' successfully."

set +e
watch_upload_out="$(cd "$notes_root" && "$CLI" watch-upload "project/fast-save.md" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$watch_upload_out" "Change detected: project/fast-save.md"
assert_contains "$watch_upload_out" "Uploaded 'fast-save' successfully."

set +e
watch_upload_external_cwd_out="$(cd "$tmp_dir" && "$CLI" watch-upload "$notes_root/project/fast-save.md" 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$watch_upload_external_cwd_out" "Change detected: project/fast-save.md"
assert_contains "$watch_upload_external_cwd_out" "Uploaded 'fast-save' successfully."

set +e
disable_out="$(cd "$notes_root" && "$CLI" watch "project/watch-note.md" --disable 2>&1)"
code=$?
set -e
assert_exit_code "$code" 0
assert_contains "$disable_out" "Updated watch settings for 'project/watch-note.md': enabled=false cooldown=60s"

[[ "$(jq -r '.watch.files["project/watch-note.md"].enabled' "$config_path")" == "false" ]] || fail "expected watched file disabled"

echo "PASS: slice 24 per-file watch cooldown"
