#!/usr/bin/env zsh
set -euo pipefail

notion_usage() {
  cat <<'USAGE'
Usage: ns <command> [options]

Commands:
  init       Initialize notion project config
  link       Map a first-level subdirectory to a Notion relation page id
  status     Show resolved sync intent for a markdown file
  completion Print shell completion script
  upload     Upload a markdown file to Notion
  download   Download a markdown file from Notion
  help       Show this help
USAGE

}

# Prints init command usage.
# Example: notion_init_usage
notion_init_usage() {
  echo "Usage: ns init --database-id <id> --notes-root <path> [--force]"
}

# Prints link command usage.
# Example: notion_link_usage
notion_link_usage() {
  echo "Usage: ns link <subdir> <relation_page_id> <relation_property> [--force]"
}

# Prints upload command usage.
# Example: notion_upload_usage
notion_upload_usage() {
  echo "Usage: ns upload [--dry-run] <file.md>"
}

# Prints download command usage.
# Example: notion_download_usage
notion_download_usage() {
  echo "Usage: ns download [--dry-run] <file.md>"
}

# Prints status command usage.
# Example: notion_status_usage
notion_status_usage() {
  echo "Usage: ns status <file.md>"
}

notion_completion_usage() {
  echo "Usage: ns completion zsh"
}

notion_is_tty() {
  [[ -t 1 ]]
}

notion_color() {
  local code="$1"
  if notion_is_tty; then
    printf '\033[%sm' "$code"
  fi
}

# Returns default local secrets file path.
# Example: notion_default_secrets_path
notion_default_secrets_path() {
  echo "$HOME/.config/notion-cli/secrets.zsh"
}

# Resolves parser path, honoring NOTION_PARSER_PATH override.
# Example: parser_path="$(notion_parser_path)"
notion_parser_path() {
  local this_file this_dir
  this_file="${(%):-%x}"
  this_dir="${this_file:A:h}"
  echo "${NOTION_PARSER_PATH:-$this_dir/notion_parser.py}"
}

# Loads NOTION_TOKEN from env first, then from secrets file fallback.
# Example: token="$(notion_load_token)"
notion_load_token() {
  local token="${NOTION_TOKEN-}"
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  token="${token%"${token##*[![:space:]]}"}"

  if [[ -n "${token}" ]]; then
    echo "$token"
    return 0
  fi

  local secrets_path
  secrets_path="$(notion_default_secrets_path)"
  [[ -f "$secrets_path" ]] && source "$secrets_path"

  token="${NOTION_TOKEN-}"
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"

  if [[ -n "${token}" ]]; then
    echo "$token"
    return 0
  fi

  return 1
}

# Same as notion_load_token but emits user-facing error when missing.
# Example: token="$(notion_require_token)" || exit 1
notion_require_token() {
  local res
  if ! res="$(notion_load_token)"; then
    echo "Error: Set NOTION_TOKEN in environment, OR add export NOTION_TOKEN=... to $(notion_default_secrets_path)" >&2
    return 1
  fi

  echo "$res"
}

# Escapes a string for safe insertion into JSON string values.
# Example: escaped="$(json_escape "$raw_value")"
json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  echo "$value"
}
