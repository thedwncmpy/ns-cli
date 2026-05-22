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
  echo "Usage: notion link <subdir> <relation_page_id> <relation_property> [--force]"
}

notion_upload_usage() {
  echo "Usage: notion upload <file.md>"
}

notion_download_usage() {
  echo "Usage: notion download <file.md>"
}

notion_default_secrets_path() {
  echo "$HOME/.config/notion-cli/secrets.zsh"
}

notion_parser_path() {
  local this_file this_dir
  this_file="${(%):-%N}"
  this_dir="${this_file:A:h}"
  echo "${NOTION_PARSER_PATH:-$this_dir/notion_parser.py}"
}

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

notion_require_token() {
  local res
  if ! res="$(notion_load_token)"; then
    echo "Error: Set NOTION_TOKEN in environment, OR add export NOTION_TOKEN=... to $(notion_default_secrets_path)" >&2
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
    --help | -h)
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

  cat >"$cfg_path" <<JSON
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
  local relation_property=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --help | -h)
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
      elif [[ -z "$relation_property" ]]; then
        relation_property="$1"
      else
        echo "Error: too many arguments for link"
        notion_link_usage
        return 1
      fi
      shift
      ;;
    esac
  done

  if [[ -z "$subdir" || -z "$relation_page_id" || -z "$relation_property" ]]; then
    echo "Error: <subdir> <relation_page_id> <relation_property> are required"
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
  existing_mapping="$(jq -r ".mappings.\"$subdir\".relation_page_id // .mappings.\"$subdir\" // empty" "$config_path")"

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
  jq --arg subdir "$subdir" --arg relation "$relation_page_id" --arg property "$relation_property" \
    '.mappings[$subdir] = { relation_page_id: $relation, relation_property: $property }' "$config_path" >"$tmp_cfg"
  mv "$tmp_cfg" "$config_path"

  echo "Linked '$subdir' to '$relation_page_id' using property '$relation_property' in $config_path"
}

notion_cmd_upload() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_upload_usage
    return 0
  fi

  # NOTE: Slice 5 upload flow:

  # 1) Validate required <file.md> argument.
  local file="${1:-}"
  if [[ -z "$file" ]]; then
    echo "Error: upload requires <file.md>"
    notion_upload_usage
    return 1
  fi

  # 2) Validate file exists and has .md extension.
  local abs_file="${file:A}"
  if [[ ! -f "$abs_file" ]]; then
    echo "Error: file not found: $file"
    return 1
  fi

  if [[ "$abs_file" != *.md ]]; then
    echo "Error: upload only supports .md files"
    return 1
  fi

  # 3) Locate config via find_config; read notes_root + mappings.
  local config_path
  config_path="$(find_config)" || {
    echo "Error: No project config found. Run 'notion init' first."
    return 1
  }

  # 4) Ensure file is inside notes_root.
  local notes_root
  notes_root="$(jq -r '.notes_root' "$config_path")"
  local abs_notes_root="${notes_root:A}"
  if [[ "$abs_file" != "$abs_notes_root/"* ]]; then
    echo "Error: file must be inside notes_root: $abs_notes_root"
    return 1
  fi

  # 5) Resolve first-level segment and require mapping.
  local relative_path first_segment
  relative_path="${abs_file#$abs_notes_root/}"
  first_segment="${relative_path%%/*}"

  local relation_page_id relation_property
  relation_page_id="$(jq -r --arg seg "$first_segment" '.mappings[$seg].relation_page_id // .mappings[$seg] // empty' "$config_path")"
  relation_property="$(jq -r --arg seg "$first_segment" '.mappings[$seg].relation_property // "notebook"' "$config_path")"
  if [[ -z "$relation_page_id" ]]; then
    echo "Error: no mapping found for first-level directory '$first_segment'"
    return 1
  fi

  # 6) Require token via notion_require_token.
  if ! notion_require_token; then
    return 1
  fi

  local notion_token
  notion_token="$(notion_require_token)"

  local database_id
  database_id="$(jq -r '.database_id // empty' "$config_path")"

  if [[ -z "$database_id" ]]; then
    echo "Error: database_id missing in config. Re-run notion init."
    return 1
  fi

  local title
  title="$(basename "$abs_file" .md)"

  # 7) Parse markdown with notion_parser.py and perform Notion API query/update/create.
  local parser_path
  parser_path="$(notion_parser_path)"
  if [[ ! -f "$parser_path" ]]; then
    echo "Error: notion parser not found at $parser_path"
    echo "Set NOTION_PARSER_PATH or ensure lib/notion_parser.py is installed."
    return 1
  fi

  local blocks
  if ! blocks="$(python3 "$parser_path" "$abs_file")"; then
    echo "Error: failed to parse markdown with $parser_path"
    return 1
  fi

  local filter search_response
  filter="$(jq -n --arg title "$title" --arg relation "$relation_page_id" --arg rel_prop "$relation_property" '{
    filter: {
      and: [
        { property: "Name", title: { equals: $title } },
        { property: $rel_prop, relation: { contains: $relation } }
      ]
    }
  }')"

  search_response="$(curl -sS -X POST "https://api.notion.com/v1/databases/$database_id/query" \
    -H "Authorization: Bearer $notion_token" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    --data "$filter")"

  if echo "$search_response" | jq -e '.object == "error"' >/dev/null; then
    echo "Error: Notion query failed: $(echo "$search_response" | jq -r '.message')"
    return 1
  fi

  # 8) Hard fail ambiguous exact matches (title + relation).
  local match_count
  match_count="$(echo "$search_response" | jq '.results | length')"
  if [[ "$match_count" -gt 1 ]]; then
    echo "Error: ambiguous match for title '$title' in relation '$first_segment' ($match_count pages)."
    echo "Refine remote data so only one exact title+relation page exists."
    return 1
  fi

  local page_id response
  page_id="$(echo "$search_response" | jq -r '.results[0].id // empty')"

  if [[ -n "$page_id" ]]; then
    local existing_blocks block_id payload
    existing_blocks="$(curl -sS -X GET "https://api.notion.com/v1/blocks/$page_id/children" \
      -H "Authorization: Bearer $notion_token" \
      -H "Notion-Version: 2022-06-28" | jq -r '.results[].id')"

    for block_id in ${(f)existing_blocks}; do
      curl -sS -X DELETE "https://api.notion.com/v1/blocks/$block_id" \
        -H "Authorization: Bearer $notion_token" \
        -H "Notion-Version: 2022-06-28" >/dev/null
    done

    payload="$(jq -n --argjson child_blocks "$blocks" '{children: $child_blocks}')"
    response="$(curl -sS -X PATCH "https://api.notion.com/v1/blocks/$page_id/children" \
      -H "Authorization: Bearer $notion_token" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      --data "$payload")"
  else
    local payload
    payload="$(jq -n \
      --arg db "$database_id" \
      --arg rel "$relation_page_id" \
      --arg page_title "$title" \
      --argjson child_blocks "$blocks" \
      '{
        parent: { database_id: $db },
        properties: {
          Name: { title: [{ text: { content: $page_title } }] },
          notebook: { relation: [{ id: $rel }] }
        },
        children: $child_blocks
      }')"

    response="$(curl -sS -X POST "https://api.notion.com/v1/pages" \
      -H "Authorization: Bearer $notion_token" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      --data "$payload")"
  fi

  if echo "$response" | jq -e '.object == "error"' >/dev/null; then
    echo "Error: Notion sync failed: $(echo "$response" | jq -r '.message')"
    return 1
  fi

  echo "Uploaded '$title' successfully."
  return 0
}

notion_cmd_download() {
  # INFO: download <filename>
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_download_usage
    return 0
  fi

  local target="${1:-}"

  if [[ -z "$target" ]]; then
    echo "Error: download requires <file.md>"
    notion_download_usage
    return 1
  fi

  if [[ "$target" != *.md ]]; then
    echo "Error: download requires a <*.md>"
    notion_download_usage
    return 1
  fi

  local abs_target="${target:a}"
  local abs_target_path="${abs_target%/*}"
  local abs_target_base="${abs_target##*/}"
  local abs_target_name="${abs_target_base%.*}"

  # echo "abs_target: $abs_target"
  # echo "abs_target_path: $abs_target_path"
  # echo "abs_target_base: $abs_target_base"
  # echo "abs_target_name: $abs_target_name"

  local config_path
  config_path="$(find_config)" || {
    echo "Error: No project config found. Run 'notion init' first."
    return 1
  }

  # echo "$config_path"
  local notes_root
  notes_root="$(jq -r ".notes_root" "$config_path")"
  local abs_notes_root="${notes_root:A}"
  local canonical_notes_root canonical_target_path canonical_target
  canonical_notes_root="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$abs_notes_root")"
  canonical_target_path="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$abs_target_path")"
  canonical_target="$canonical_target_path/$abs_target_base"

  # echo "abs root $abs_notes_root"
  # echo "file $abs_target"

  if [[ "$abs_target" != "$abs_notes_root/"* && "$canonical_target" != "$canonical_notes_root/"* ]]; then
    echo "Error: file must be inside notes_root: $canonical_notes_root"
    return 1
  fi

  local relative_path
  if [[ "$abs_target" == "$abs_notes_root/"* ]]; then
    relative_path="${abs_target#$abs_notes_root/}"
  else
    relative_path="${canonical_target#$canonical_notes_root/}"
  fi
  local first_seg="${relative_path%%/*}"

  local relation_page_id relation_property
  relation_page_id="$(jq -r --arg seg "$first_seg" '.mappings[$seg].relation_page_id // .mappings[$seg] // empty' "$config_path")"
  relation_property="$(jq -r --arg seg "$first_seg" '.mappings[$seg].relation_property // "notebook"' "$config_path")"

  if [[ -z "$relation_page_id" ]]; then
    echo "Error: no mapping found for first-level directory '$first_seg'"
    return 1
  fi

  local notion_token
  notion_token="$(notion_require_token)" || return 1

  local database_id
  database_id="$(jq -r '.database_id // empty' "$config_path")"

  if [[ -z "$database_id" ]]; then
    echo "Error: database_id missing in config. Re-run notion init."
    return 1
  fi

  local query_payload search_response
  query_payload="$(jq -n --arg title "$abs_target_name" --arg relation "$relation_page_id" --arg rel_prop "$relation_property" '{
    filter: {
      and: [
        { property: "Name", title: { equals: $title } },
        { property: $rel_prop, relation: { contains: $relation } }
      ]
    }
  }')"

  search_response="$(curl -sS -X POST "https://api.notion.com/v1/databases/$database_id/query" \
    -H "Authorization: Bearer $notion_token" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    --data "$query_payload")"

  if echo "$search_response" | jq -e '.object == "error"' >/dev/null; then
    echo "Error: Notion query failed: $(echo "$search_response" | jq -r '.message')"
    return 1
  fi

  local match_count page_id
  match_count="$(echo "$search_response" | jq '.results | length')"

  if [[ "$match_count" -eq 0 ]]; then
    echo "Error: no remote page found for '$abs_target_name' in relation '$first_seg'"
    return 1
  fi

  if [[ "$match_count" -gt 1 ]]; then
    echo "Error: ambiguous match for title '$abs_target_name' in relation '$first_seg' ($match_count pages)."
    echo "Refine remote data so only one exact title+relation page exists."
    return 1
  fi

  page_id="$(echo "$search_response" | jq -r '.results[0].id // empty')"
  if [[ -z "$page_id" ]]; then
    echo "Error: failed to resolve remote page id."
    return 1
  fi

  local blocks_response
  blocks_response="$(curl -sS -X GET "https://api.notion.com/v1/blocks/$page_id/children" \
    -H "Authorization: Bearer $notion_token" \
    -H "Notion-Version: 2022-06-28")"

  if echo "$blocks_response" | jq -e '.object == "error"' >/dev/null; then
    echo "Error: Notion block fetch failed: $(echo "$blocks_response" | jq -r '.message')"
    return 1
  fi

  local parser_path md_content
  parser_path="$(notion_parser_path)"

  if [[ ! -f "$parser_path" ]]; then
    echo "Error: notion parser not found at $parser_path"
    echo "Set NOTION_PARSER_PATH or ensure lib/notion_parser.py is installed."
    return 1
  fi

  if ! md_content="$(echo "$blocks_response" | jq '.results' | python3 "$parser_path" --reverse)"; then
    echo "Error: failed to convert notion blocks to markdown with $parser_path"
    return 1
  fi

  mkdir -p "$abs_target_path"
  printf "%s\n" "$md_content" >"$abs_target"
  echo "Downloaded '$abs_target_name' to $abs_target"
  return 0
}

notion_main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    notion_usage
    return 1
  fi
  shift || true

  case "$cmd" in
  help | -h | --help)
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
