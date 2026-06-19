#!/usr/bin/env zsh
set -euo pipefail
NOTION_CLI_VERSION="${NOTION_CLI_VERSION:-__NS_VERSION__}"
NS_CONFIG_DIR_NAME="${NS_CONFIG_DIR_NAME:-.ns-cli}"
NS_SECRETS_DIR_NAME="${NS_SECRETS_DIR_NAME:-ns-cli}"

notion_usage() {
  notion_print_usage "Usage: ns <command> [options]"
  notion_print_usage ""
  notion_print_usage "Commands:"
  notion_print_usage "  init       Initialize notion project config"
  notion_print_usage "  link       Map a first-level subdirectory to a Notion relation page id"
  notion_print_usage "  status     Show resolved sync intent for a markdown file"
  notion_print_usage "  completion Print shell completion script"
  notion_print_usage "  version    Show ns version"
  notion_print_usage "  upload     Upload a markdown file to Notion"
  notion_print_usage "  upload-all Upload all markdown files in the current sync scope"
  notion_print_usage "  upload-sync Upload all markdown files under current directory"
  notion_print_usage "  watch      Watch notes_root and auto-upload changed markdown files"
  notion_print_usage "  download   Download a markdown file from Notion"
  notion_print_usage "  delete     Delete a markdown file locally and archive the matching Notion page"
  notion_print_usage "  download-all Download all Notion pages in the current sync scope"
  notion_print_usage "  download-sync Download all markdown files under current directory"
  notion_print_usage "  help       Show this help"
}

notion_version_usage() {
  notion_print_usage "Usage: ns version"
}

# Prints init command usage.
# Example: notion_init_usage
notion_init_usage() {
  notion_print_usage "Usage: ns init --database-id <id> --notes-root <path> [--title-property <name>] [--force]"
}

# Prints link command usage.
# Example: notion_link_usage
notion_link_usage() {
  notion_print_usage "Usage: ns link <subdir> <relation_page_id> <relation_property> [--force]"
}

# Prints upload command usage.
# Example: notion_upload_usage
notion_upload_usage() {
  notion_print_usage "Usage: ns upload [--dry-run] <file.md>"
}

notion_upload_all_usage() {
  notion_print_usage "Usage: ns upload-all [--dry-run]"
}

notion_upload_sync_usage() {
  notion_print_usage "Usage: ns upload-sync [--dry-run]"
}

notion_watch_usage() {
  notion_print_usage "Usage: ns watch [<file.md>] [--enable|--disable] [--cooldown-seconds <n>]"
}

# Prints download command usage.
# Example: notion_download_usage
notion_download_usage() {
  notion_print_usage "Usage: ns download [--dry-run] <file.md>"
}

notion_delete_usage() {
  notion_print_usage "Usage: ns delete [--dry-run] <file.md>"
}

notion_download_all_usage() {
  notion_print_usage "Usage: ns download-all [--dry-run]"
}

notion_download_sync_usage() {
  notion_print_usage "Usage: ns download-sync [--dry-run]"
}

# Prints status command usage.
# Example: notion_status_usage
notion_status_usage() {
  notion_print_usage "Usage: ns status <file.md>"
}

notion_completion_usage() {
  notion_print_usage "Usage: ns completion <zsh|bash>"
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

notion_print() {
  local color="$1"
  local label="$2"
  shift 2
  local msg="$*"
  local reset=""
  if notion_is_tty; then
    reset=$'\033[0m'
  fi
  if [[ -n "$label" ]]; then
    printf "%s%s%s %s\n" "$color" "$label" "$reset" "$msg"
  else
    printf "%s%s%s\n" "$color" "$msg" "$reset"
  fi
}

notion_print_error() { notion_print $'\033[1;31m' "Error:" "$*" >&2; }
notion_print_warn() { notion_print $'\033[1;33m' "Warning:" "$*"; }
notion_print_info() { notion_print $'\033[1;36m' "" "$*"; }
notion_print_success() { notion_print $'\033[1;32m' "" "$*"; }
notion_print_usage() { notion_print $'\033[1;35m' "" "$*"; }

# Returns default local secrets file path.
# Example: notion_default_secrets_path
notion_default_secrets_path() {
  echo "$HOME/.config/$NS_SECRETS_DIR_NAME/secrets.zsh"
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
    notion_print_error "Set NOTION_TOKEN in environment, OR add export NOTION_TOKEN=... to $(notion_default_secrets_path)"
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
