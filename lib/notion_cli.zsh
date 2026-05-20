#!/usr/bin/env zsh
set -euo pipefail

notion_usage() {
  cat <<'USAGE'
Usage: notion <command> [options]

Commands:
  init       Initialize notion project config
  link       Map a first-level subdirectory to a Notion relation page id
  upload     Upload a markdown file to Notion
  download   Download a markdown file from Notion
  help       Show this help
USAGE
}

notion_init_usage() {
  echo "Usage: notion init --database-id <id> --notes-root <path> [--force]"
}

notion_link_usage() {
  echo "Usage: notion link <subdir> <relation_page_id> [--force]"
}

notion_upload_usage() {
  echo "Usage: notion upload <file.md>"
}

notion_download_usage() {
  echo "Usage: notion download <file.md>"
}

# NOTE: Slice 4 skeleton
# - Secrets source precedence: NOTION_TOKEN env var > secrets file
# - Secrets file default: ~/.config/notion-cli/secrets.zsh
# - Do not persist secrets into project config JSON

notion_default_secrets_path() {
  echo "$HOME/.config/notion-cli/secrets.zsh"
}

notion_load_token() {
  local token="${NOTION_TOKEN-}"
  token="${token#"${token%%[![:space:]]*}"}"
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

notion_require_token() {
  local res
  if ! res="$(notion_load_token)"; then
    echo "Error: Set NOTION_TOKEN in environment, OR add export NOTION_TOKEN=... to $(notion_default_secrets_path)"
    return 1
  fi 

  echo "$res"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  echo "$value"
}

notion_cmd_init() {
  local database_id=""
  local notes_root=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        notion_init_usage
        return 0
        ;;
      --database-id)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          echo "Error: --database-id requires a value"
          return 1
        fi
        database_id="$2"
        shift 2
        ;;
      --notes-root)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          echo "Error: --notes-root requires a value"
          return 1
        fi
        notes_root="$2"
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      *)
        echo "Error: unknown argument for init: $1"
        notion_init_usage
        return 1
        ;;
    esac
  done

  if [[ -z "$database_id" ]]; then
    echo "Error: --database-id is required"
    notion_init_usage
    return 1
  fi

  if [[ -z "$notes_root" ]]; then
    echo "Error: --notes-root is required"
    notion_init_usage
    return 1
  fi

  local abs_notes_root="${notes_root:A}"
  local cfg_dir="$abs_notes_root/.notion-cli"
  local cfg_path="$cfg_dir/config.json"

  if [[ -f "$cfg_path" && $force -ne 1 ]]; then
    echo "Error: config already exists at $cfg_path (use --force to overwrite)"
    return 1
  fi

  mkdir -p "$cfg_dir"

  local db_escaped root_escaped
  db_escaped="$(json_escape "$database_id")"
  root_escaped="$(json_escape "$abs_notes_root")"

  cat > "$cfg_path" <<JSON
{
  "version": 1,
  "database_id": "$db_escaped",
  "notes_root": "$root_escaped",
  "mappings": {}
}
JSON

  echo "Initialized config at $cfg_path"
}

find_config() {
  local current_dir="${PWD:A}"
  while [[ "$current_dir" != "/" ]]; do
    if [[ -f "$current_dir/.notion-cli/config.json" ]]; then
      echo "$current_dir/.notion-cli/config.json"
      return 0
    fi
    current_dir="$(dirname "$current_dir")"
  done
  return 1
}

notion_cmd_link() {
  local subdir=""
  local relation_page_id=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        notion_link_usage
        return 0
        ;;
      --force)
        force=1
        shift
        ;;
      -*)
        echo "Error: unknown argument for link: $1"
        notion_link_usage
        return 1
        ;;
      *)
        if [[ -z "$subdir" ]]; then
          subdir="$1"
        elif [[ -z "$relation_page_id" ]]; then
          relation_page_id="$1"
        else
          echo "Error: too many arguments for link"
          notion_link_usage
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$subdir" || -z "$relation_page_id" ]]; then
    echo "Error: <subdir> and <relation_page_id> are required"
    notion_link_usage
    return 1
  fi

  local config_path
  config_path="$(find_config)" || {
    echo "Error: No project config found. Run 'notion init' first."
    return 1
  }

  local notes_root
  notes_root="$(jq -r '.notes_root' "$config_path")"

  if [[ ! -d "$notes_root/$subdir" ]]; then
    echo "Error: directory does not exist: $notes_root/$subdir"
    return 1
  fi

  local existing_mapping
  existing_mapping="$(jq -r ".mappings.\"$subdir\" // empty" "$config_path")"

  if [[ -n "$existing_mapping" && $force -ne 1 ]]; then
    echo "Error: '$subdir' is already mapped to '$existing_mapping' (use --force to overwrite)"
    return 1
  fi

  local subdir_escaped relation_escaped
  subdir_escaped="$(json_escape "$subdir")"
  relation_escaped="$(json_escape "$relation_page_id")"

  # Use a temporary file to update the config
  local tmp_cfg
  tmp_cfg="$(mktemp)"
  jq --arg subdir "$subdir" --arg relation "$relation_page_id" \
     '.mappings[$subdir] = $relation' "$config_path" > "$tmp_cfg"
  mv "$tmp_cfg" "$config_path"

  echo "Linked '$subdir' to '$relation_page_id' in $config_path"
}

notion_cmd_upload() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_upload_usage
    return 0
  fi

  echo "Error: 'notion upload' is not implemented yet in this slice."
  echo "Run: notion upload --help"
  return 1
}

notion_cmd_download() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_download_usage
    return 0
  fi

  echo "Error: 'notion download' is not implemented yet in this slice."
  echo "Run: notion download --help"
  return 1
}

notion_main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    notion_usage
    return 1
  fi
  shift || true

  case "$cmd" in
    help|-h|--help)
      notion_usage
      ;;
    init)
      notion_cmd_init "$@"
      ;;
    link)
      notion_cmd_link "$@"
      ;;
    upload)
      notion_cmd_upload "$@"
      ;;
    download)
      notion_cmd_download "$@"
      ;;
    *)
      echo "Unknown command: $cmd"
      echo
      notion_usage
      return 1
      ;;
  esac
}
