#!/usr/bin/env zsh
set -euo pipefail

this_file="${(%):-%x}"
this_dir="${this_file:A:h}"
source "$this_dir/common.zsh"
source "$this_dir/notion_api.zsh"
source "$this_dir/config.zsh"
source "$this_dir/relation_resolver.zsh"
source "$this_dir/migrations.zsh"

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

  notion_init_config "$database_id" "$notes_root" "$force"
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
  config_path="$(notion_find_and_prepare_config)" || {
    echo "Error: No project config found. Run 'ns init' first."
    return 1
  }

  local notes_root
  notes_root="$(notion_config_get_notes_root "$config_path")"

  if [[ ! -d "$notes_root/$subdir" ]]; then
    echo "Error: directory does not exist: $notes_root/$subdir"
    return 1
  fi

  local existing_mapping
  existing_mapping="$(notion_config_get_mapping_relation_page_id "$config_path" "$subdir")"

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
  local dry_run=0
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
  fi
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
  config_path="$(notion_find_and_prepare_config)" || {
    echo "Error: No project config found. Run 'ns init' first."
    return 1
  }

  # 4) Ensure file is inside notes_root.
  local notes_root
  notes_root="$(notion_config_get_notes_root "$config_path")"
  local abs_notes_root="${notes_root:A}"
  if ! notion_ensure_path_inside_notes_root "$abs_file" "$abs_notes_root"; then
    echo "Error: file must be inside notes_root: $abs_notes_root"
    return 1
  fi

  # 5) Resolve first-level segment and require mapping.
  local relative_path first_segment
  relative_path="$(notion_relative_path_under_notes_root "$abs_file" "$abs_notes_root")" || {
    echo "Error: file must be inside notes_root: $abs_notes_root"
    return 1
  }
  first_segment="${relative_path%%/*}"

  local relation_page_id relation_property
  relation_page_id="$(notion_config_get_mapping_relation_page_id "$config_path" "$first_segment")"
  relation_property="$(notion_config_get_mapping_relation_property "$config_path" "$first_segment")"
  if [[ -z "$relation_page_id" ]]; then
    echo "Error: no mapping found for first-level directory '$first_segment'"
    return 1
  fi

  local title
  title="$(basename "$abs_file" .md)"
  if [[ "$dry_run" -eq 1 ]]; then
    echo "Dry-run upload intent:"
    echo "  file: $abs_file"
    echo "  title: $title"
    echo "  notes_root: $abs_notes_root"
    echo "  mapping_dir: $first_segment"
    echo "  relation_page_id: $relation_page_id"
    echo "  relation_property: $relation_property"
    echo "  action: query exact title+relation; update if found else create"
    return 0
  fi

  # 6) Require token via notion_require_token.
  if ! notion_require_token; then
    return 1
  fi

  local notion_token
  notion_token="$(notion_require_token)"

  local database_id
  database_id="$(notion_config_get_database_id "$config_path")"

  if [[ -z "$database_id" ]]; then
    echo "Error: database_id missing in config. Re-run ns init."
    return 1
  fi

  # 7) Parse markdown with notion_parser.py and perform Notion API query/update/create.
  local parser_path
  parser_path="$(notion_parser_path)"
  if [[ ! -f "$parser_path" ]]; then
    echo "Error: notion parser not found at $parser_path"
    echo "Set NOTION_PARSER_PATH or ensure lib/notion_parser.py is installed."
    return 1
  fi

  local tmp_blocks
  tmp_blocks="$(mktemp)"
  if ! python3 "$parser_path" "$abs_file" > "$tmp_blocks"; then
    rm -f "$tmp_blocks"
    echo "Error: failed to parse markdown with $parser_path"
    return 1
  fi
  if ! jq -e . "$tmp_blocks" >/dev/null 2>&1; then
    rm -f "$tmp_blocks"
    echo "Error: parser produced invalid JSON for '$abs_file'"
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

  search_response="$(notion_query_all "$database_id" "$notion_token" "$filter")" || return 1

  if printf '%s' "$search_response" | jq -e '.object == "error"' >/dev/null; then
    echo "Error: Notion query failed: $(printf '%s' "$search_response" | jq -r '.message')"
    return 1
  fi

  # 8) Hard fail ambiguous exact matches (title + relation).
  local match_count
  match_count="$(printf '%s' "$search_response" | jq '.results | length')"
  if [[ "$match_count" -gt 1 ]]; then
    echo "Error: ambiguous match for title '$title' in relation '$first_segment' ($match_count pages)."
    echo "Refine remote data so only one exact title+relation page exists."
    return 1
  fi

  local total_blocks
  total_blocks="$(jq 'length' "$tmp_blocks")"

  local page_id response
  page_id="$(printf '%s' "$search_response" | jq -r '.results[0].id // empty')"

  if [[ -n "$page_id" ]]; then
    local existing_blocks block_id payload
    existing_blocks="$(notion_fetch_all_children_ids "$page_id" "$notion_token")" || return 1

    for block_id in ${(f)existing_blocks}; do
      notion_api_request "DELETE" "https://api.notion.com/v1/blocks/$block_id" "$notion_token" >/dev/null || return 1
    done

    local start chunk_payload
    start=0
    while [[ "$start" -lt "$total_blocks" ]]; do
      chunk_payload="$(jq -n \
        --argjson start "$start" \
        --slurpfile child_blocks "$tmp_blocks" \
        '{children: ($child_blocks[0][$start:($start+100)])}')"
      response="$(notion_api_request "PATCH" "https://api.notion.com/v1/blocks/$page_id/children" "$notion_token" "$chunk_payload")" || return 1
      if printf '%s' "$response" | jq -e '.object == "error"' >/dev/null; then
        rm -f "$tmp_blocks"
        echo "Error: Notion sync failed: $(printf '%s' "$response" | jq -r '.message')"
        return 1
      fi
      start=$((start + 100))
    done
  else
    local payload first_chunk_count start chunk_payload
    if [[ "$total_blocks" -gt 100 ]]; then
      first_chunk_count=100
    else
      first_chunk_count="$total_blocks"
    fi
    payload="$(jq -n \
      --arg db "$database_id" \
      --arg rel "$relation_page_id" \
      --arg rel_prop "$relation_property" \
      --arg page_title "$title" \
      --argjson first_chunk_count "$first_chunk_count" \
      --slurpfile child_blocks "$tmp_blocks" \
      '{
        parent: { database_id: $db },
        properties: {
          Name: { title: [{ text: { content: $page_title } }] },
          ($rel_prop): { relation: [{ id: $rel }] }
        },
        children: ($child_blocks[0][0:$first_chunk_count])
      }')"

    response="$(notion_api_request "POST" "https://api.notion.com/v1/pages" "$notion_token" "$payload")" || return 1

    if printf '%s' "$response" | jq -e '.object == "error"' >/dev/null; then
      rm -f "$tmp_blocks"
      echo "Error: Notion sync failed: $(printf '%s' "$response" | jq -r '.message')"
      return 1
    fi

    page_id="$(printf '%s' "$response" | jq -r '.id // empty')"
    if [[ -z "$page_id" ]]; then
      rm -f "$tmp_blocks"
      echo "Error: Notion sync failed: create response missing page id."
      return 1
    fi

    start=100
    while [[ "$start" -lt "$total_blocks" ]]; do
      chunk_payload="$(jq -n \
        --argjson start "$start" \
        --slurpfile child_blocks "$tmp_blocks" \
        '{children: ($child_blocks[0][$start:($start+100)])}')"
      response="$(notion_api_request "PATCH" "https://api.notion.com/v1/blocks/$page_id/children" "$notion_token" "$chunk_payload")" || return 1
      if printf '%s' "$response" | jq -e '.object == "error"' >/dev/null; then
        rm -f "$tmp_blocks"
        echo "Error: Notion sync failed: $(printf '%s' "$response" | jq -r '.message')"
        return 1
      fi
      start=$((start + 100))
    done
  fi

  rm -f "$tmp_blocks"

  echo "Uploaded '$title' successfully."
  return 0
}

notion_cmd_download() {
  # INFO: download <filename>
  local dry_run=0
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
  fi
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
  config_path="$(notion_find_and_prepare_config)" || {
    echo "Error: No project config found. Run 'ns init' first."
    return 1
  }

  # echo "$config_path"
  local notes_root
  notes_root="$(notion_config_get_notes_root "$config_path")"
  local abs_notes_root="${notes_root:A}"
  if ! notion_ensure_path_inside_notes_root "$abs_target" "$abs_notes_root"; then
    echo "Error: file must be inside notes_root: $abs_notes_root"
    return 1
  fi

  local relative_path
  relative_path="$(notion_relative_path_under_notes_root "$abs_target" "$abs_notes_root")" || {
    echo "Error: file must be inside notes_root: $abs_notes_root"
    return 1
  }
  local first_seg="${relative_path%%/*}"

  local relation_page_id relation_property
  relation_page_id="$(notion_config_get_mapping_relation_page_id "$config_path" "$first_seg")"
  relation_property="$(notion_config_get_mapping_relation_property "$config_path" "$first_seg")"

  if [[ -z "$relation_page_id" ]]; then
    echo "Error: no mapping found for first-level directory '$first_seg'"
    return 1
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    echo "Dry-run download intent:"
    echo "  file: $abs_target"
    echo "  title: $abs_target_name"
    echo "  notes_root: $abs_notes_root"
    echo "  mapping_dir: $first_seg"
    echo "  relation_page_id: $relation_page_id"
    echo "  relation_property: $relation_property"
    echo "  action: query exact title+relation; overwrite local file if single match"
    return 0
  fi

  local notion_token
  notion_token="$(notion_require_token)" || return 1

  local database_id
  database_id="$(notion_config_get_database_id "$config_path")"

  if [[ -z "$database_id" ]]; then
    echo "Error: database_id missing in config. Re-run ns init."
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

  search_response="$(notion_query_all "$database_id" "$notion_token" "$query_payload")" || return 1

  if printf '%s' "$search_response" | jq -e '.object == "error"' >/dev/null; then
    echo "Error: Notion query failed: $(printf '%s' "$search_response" | jq -r '.message')"
    return 1
  fi

  local match_count page_id
  match_count="$(printf '%s' "$search_response" | jq '.results | length')"

  if [[ "$match_count" -eq 0 ]]; then
    echo "Error: no remote page found for '$abs_target_name' in relation '$first_seg'"
    return 1
  fi

  if [[ "$match_count" -gt 1 ]]; then
    echo "Error: ambiguous match for title '$abs_target_name' in relation '$first_seg' ($match_count pages)."
    echo "Refine remote data so only one exact title+relation page exists."
    return 1
  fi

  page_id="$(printf '%s' "$search_response" | jq -r '.results[0].id // empty')"
  if [[ -z "$page_id" ]]; then
    echo "Error: failed to resolve remote page id."
    return 1
  fi

  local blocks_response
  blocks_response="$(notion_fetch_all_children_blocks "$page_id" "$notion_token")" || return 1

  if printf '%s' "$blocks_response" | jq -e '.object == "error"' >/dev/null; then
    echo "Error: Notion block fetch failed: $(printf '%s' "$blocks_response" | jq -r '.message')"
    return 1
  fi

  local parser_path md_content
  parser_path="$(notion_parser_path)"

  if [[ ! -f "$parser_path" ]]; then
    echo "Error: notion parser not found at $parser_path"
    echo "Set NOTION_PARSER_PATH or ensure lib/notion_parser.py is installed."
    return 1
  fi

  if ! md_content="$(printf '%s' "$blocks_response" | jq '.results' | python3 "$parser_path" --reverse)"; then
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
  status)
    notion_cmd_status "$@"
    ;;
  completion)
    notion_cmd_completion "$@"
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

notion_cmd_status() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_status_usage
    return 0
  fi

  local file="${1:-}"
  if [[ -z "$file" ]]; then
    echo "Error: status requires <file.md>"
    notion_status_usage
    return 1
  fi
  if [[ "$file" != *.md ]]; then
    echo "Error: status requires a <*.md>"
    notion_status_usage
    return 1
  fi

  local abs_file="${file:a}"
  local title="${abs_file:t:r}"
  local config_path
  config_path="$(notion_find_and_prepare_config)" || {
    echo "Error: No project config found. Run 'ns init' first."
    return 1
  }

  local notes_root abs_notes_root
  notes_root="$(notion_config_get_notes_root "$config_path")"
  abs_notes_root="${notes_root:A}"
  if ! notion_ensure_path_inside_notes_root "$abs_file" "$abs_notes_root"; then
    echo "Error: file must be inside notes_root: $abs_notes_root"
    return 1
  fi

  local relative_path first_segment
  relative_path="$(notion_relative_path_under_notes_root "$abs_file" "$abs_notes_root")" || {
    echo "Error: file must be inside notes_root: $abs_notes_root"
    return 1
  }
  first_segment="${relative_path%%/*}"

  local database_id relation_page_id relation_property
  database_id="$(notion_config_get_database_id "$config_path")"
  relation_page_id="$(notion_config_get_mapping_relation_page_id "$config_path" "$first_segment")"
  relation_property="$(notion_config_get_mapping_relation_property "$config_path" "$first_segment")"
  if [[ -z "$relation_page_id" ]]; then
    echo "Error: no mapping found for first-level directory '$first_segment'"
    return 1
  fi

  local query_payload
  query_payload="$(jq -n --arg title "$title" --arg relation "$relation_page_id" --arg rel_prop "$relation_property" '{
    filter: {
      and: [
        { property: "Name", title: { equals: $title } },
        { property: $rel_prop, relation: { contains: $relation } }
      ]
    }
  }')"

  local c_head c_key c_val c_reset
  c_head="$(notion_color '1;36')"
  c_key="$(notion_color '1;33')"
  c_val="$(notion_color '0;37')"
  c_reset="$(notion_color '0')"

  echo "${c_head}Status${c_reset}"
  echo "${c_key}  File${c_reset}: ${c_val}$abs_file${c_reset}"
  echo "${c_key}  Title${c_reset}: ${c_val}$title${c_reset}"
  echo "${c_key}  Config${c_reset}: ${c_val}$config_path${c_reset}"
  echo "${c_key}  Database${c_reset}: ${c_val}$database_id${c_reset}"
  echo "${c_key}  Notes Root${c_reset}: ${c_val}$abs_notes_root${c_reset}"
  echo "${c_key}  Relative Path${c_reset}: ${c_val}$relative_path${c_reset}"
  echo "${c_key}  Mapping Dir${c_reset}: ${c_val}$first_segment${c_reset}"
  echo "${c_key}  Relation Page${c_reset}: ${c_val}$relation_page_id${c_reset}"
  echo "${c_key}  Relation Prop${c_reset}: ${c_val}$relation_property${c_reset}"
  echo "${c_key}  Upload Intent${c_reset}: ${c_val}query exact title+relation; update if found else create${c_reset}"
  echo "${c_key}  Download Intent${c_reset}: ${c_val}query exact title+relation; overwrite local file if single match${c_reset}"
  echo "${c_key}  Query Filter${c_reset}: ${c_val}$query_payload${c_reset}"
}

notion_cmd_completion() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_completion_usage
    return 0
  fi
  if [[ "${1:-}" != "zsh" ]]; then
    echo "Error: completion requires shell target (supported: zsh)"
    notion_completion_usage
    return 1
  fi

  cat <<'EOF'
#compdef ns

_ns() {
  local context state line
  typeset -A opt_args

  _arguments -C \
    '1:command:->cmds' \
    '*::arg:->args'

  case $state in
    cmds)
      _values 'ns commands' \
        'help[Show help]' \
        'init[Initialize config]' \
        'link[Map directory to relation]' \
        'status[Show resolved sync intent]' \
        'upload[Upload markdown file]' \
        'download[Download markdown file]' \
        'completion[Print completion script]'
      ;;
    args)
      case $line[1] in
        init)
          _arguments '--database-id[Notion database id]:database id:' '--notes-root[Notes root path]:notes root:_files -/' '--force[Overwrite existing config]'
          ;;
        link)
          _arguments '1:subdir:_files -/' '2:relation page id:' '3:relation property:' '--force[Overwrite existing mapping]'
          ;;
        status|upload|download)
          _arguments '1:markdown file:_files -g "*.md"'
          ;;
        completion)
          _values 'shell' zsh
          ;;
      esac
      ;;
  esac
}

compdef _ns ns
EOF
}
