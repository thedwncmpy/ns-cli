#!/usr/bin/env zsh
set -euo pipefail

this_file="${(%):-%x}"
this_dir="${this_file:A:h}"
source "$this_dir/common.zsh"
source "$this_dir/notion_api.zsh"
source "$this_dir/config.zsh"
source "$this_dir/relation_resolver.zsh"
source "$this_dir/migrations.zsh"

NOTION_PROPERTIES_HEADER="<!-- notion-properties"
NOTION_PROPERTIES_FOOTER="-->"

notion_cmd_init() {
  local database_id=""
  local notes_root=""
  local title_property="Name"
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --help | -h)
      notion_init_usage
      return 0
      ;;
    --database-id)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        notion_print_error "--database-id requires a value"
        return 1
      fi
      database_id="$2"
      shift 2
      ;;
    --notes-root)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        notion_print_error "--notes-root requires a value"
        return 1
      fi
      notes_root="$2"
      shift 2
      ;;
    --title-property)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        notion_print_error "--title-property requires a value"
        return 1
      fi
      title_property="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    *)
      notion_print_error "unknown argument for init: $1"
      notion_init_usage
      return 1
      ;;
    esac
  done

  if [[ -z "$database_id" ]]; then
    notion_print_error "--database-id is required"
    notion_init_usage
    return 1
  fi

  if [[ -z "$notes_root" ]]; then
    notion_print_error "--notes-root is required"
    notion_init_usage
    return 1
  fi

  notion_init_config "$database_id" "$notes_root" "$force" "$title_property"
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
      notion_print_error "unknown argument for link: $1"
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
        notion_print_error "too many arguments for link"
        notion_link_usage
        return 1
      fi
      shift
      ;;
    esac
  done

  if [[ -z "$subdir" || -z "$relation_page_id" || -z "$relation_property" ]]; then
    notion_print_error "<subdir> <relation_page_id> <relation_property> are required"
    notion_link_usage
    return 1
  fi

  local config_path
  config_path="$(notion_find_and_prepare_config)" || {
    notion_print_error "No project config found. Run 'ns init' first."
    return 1
  }

  local notes_root
  notes_root="$(notion_config_get_notes_root "$config_path")"

  if [[ ! -d "$notes_root/$subdir" ]]; then
    notion_print_error "directory does not exist: $notes_root/$subdir"
    return 1
  fi

  local existing_mapping
  existing_mapping="$(notion_config_get_mapping_relation_page_id "$config_path" "$subdir")"

  if [[ -n "$existing_mapping" && $force -ne 1 ]]; then
    notion_print_error "'$subdir' is already mapped to '$existing_mapping' (use --force to overwrite)"
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

  notion_print_success "Linked '$subdir' to '$relation_page_id' using property '$relation_property' in $config_path"
}

notion_build_query_payload() {
  local title="$1"
  local title_property="$2"
  local relation_page_id="${3:-}"
  local relation_property="${4:-}"

  if [[ -n "$relation_page_id" ]]; then
    jq -n --arg title "$title" --arg title_prop "$title_property" --arg relation "$relation_page_id" --arg rel_prop "$relation_property" '{
      filter: {
        and: [
          { property: $title_prop, title: { equals: $title } },
          { property: $rel_prop, relation: { contains: $relation } }
        ]
      }
    }'
  else
    jq -n --arg title "$title" --arg title_prop "$title_property" '{
      filter: {
        property: $title_prop,
        title: { equals: $title }
      }
    }'
  fi
}

notion_print_sync_intent() {
  local action="$1"
  local file_path="$2"
  local title="$3"
  local notes_root="$4"
  local mapping_dir="$5"
  local relation_page_id="${6:-}"
  local relation_property="${7:-}"

  echo "  file: $file_path"
  echo "  title: $title"
  echo "  notes_root: $notes_root"
  echo "  mapping_dir: $mapping_dir"
  if [[ -n "$relation_page_id" ]]; then
    echo "  relation_page_id: $relation_page_id"
    echo "  relation_property: $relation_property"
    echo "  action: $action"
  else
    echo "  relation_page_id: <none>"
    echo "  relation_property: <none>"
    echo "  action: $action"
  fi
}

notion_split_markdown_properties() {
  local source_file="$1"
  local content_out="$2"
  local props_out="$3"

  : > "$props_out"

  if [[ ! -s "$source_file" ]]; then
    : > "$content_out"
    return 0
  fi

  local first_line=""
  IFS= read -r first_line < "$source_file" || true
  if [[ "$first_line" != "$NOTION_PROPERTIES_HEADER" ]]; then
    cp "$source_file" "$content_out"
    return 0
  fi

  awk -v content_out="$content_out" -v props_out="$props_out" -v footer="$NOTION_PROPERTIES_FOOTER" '
    BEGIN { in_meta = 0; content_started = 0 }
    NR == 1 { in_meta = 1; next }
    in_meta {
      if ($0 == footer) {
        in_meta = 0
        next
      }
      print >> props_out
      next
    }
    !content_started && $0 == "" { next }
    {
      content_started = 1
      print >> content_out
    }
  ' "$source_file"

  if [[ ! -s "$content_out" ]]; then
    : > "$content_out"
  fi
}

notion_extract_frontmatter_properties() {
  local source_file="$1"
  local tmp_content="$2"
  local tmp_props="$3"

  notion_split_markdown_properties "$source_file" "$tmp_content" "$tmp_props"
  if [[ ! -s "$tmp_props" ]]; then
    echo '{}'
    return 0
  fi

  if ! jq -e . "$tmp_props" >/dev/null 2>&1; then
    notion_print_error "invalid notion-properties metadata in '$source_file'"
    return 1
  fi

  jq -c . "$tmp_props"
}

notion_render_markdown_with_properties() {
  local properties_json="$1"
  local markdown_body="$2"

  if [[ "$properties_json" == "{}" ]]; then
    printf "%s\n" "$markdown_body"
    return 0
  fi

  printf "%s\n%s\n%s\n\n%s\n" "$NOTION_PROPERTIES_HEADER" "$properties_json" "$NOTION_PROPERTIES_FOOTER" "$markdown_body"
}

notion_serializable_page_properties() {
  local page_json="$1"
  local title_property="$2"
  local relation_property="${3:-}"

  printf '%s' "$page_json" | jq -c --arg title_prop "$title_property" --arg relation_prop "$relation_property" '
    def payload:
      if .type == "checkbox" then {checkbox: .checkbox}
      elif .type == "number" then {number: .number}
      elif .type == "url" then {url: .url}
      elif .type == "email" then {email: .email}
      elif .type == "phone_number" then {phone_number: .phone_number}
      elif .type == "date" then {date: .date}
      elif .type == "select" then {select: (if .select == null then null else {name: .select.name} end)}
      elif .type == "status" then {status: (if .status == null then null else {name: .status.name} end)}
      elif .type == "multi_select" then {multi_select: (.multi_select | map({name: .name}))}
      elif .type == "relation" then {relation: (.relation | map({id: .id}))}
      elif .type == "people" then {people: (.people | map({id: .id}))}
      elif .type == "rich_text" then {rich_text: .rich_text}
      else empty
      end;
    (.properties // {})
    | to_entries
    | map(select(.key != $title_prop and (.key != $relation_prop or $relation_prop == "")))
    | map(select(
        .value.type != "created_time" and
        .value.type != "created_by" and
        .value.type != "last_edited_time" and
        .value.type != "last_edited_by" and
        .value.type != "formula" and
        .value.type != "rollup" and
        .value.type != "unique_id" and
        .value.type != "verification" and
        .value.type != "button"
      ))
    | map({key: .key, value: (.value | payload)})
    | map(select(.value != null))
    | from_entries
  '
}

notion_merge_upload_properties() {
  local existing_props_json="$1"
  local local_props_json="$2"
  local title_property="$3"
  local title="$4"
  local relation_property="${5:-}"
  local relation_page_id="${6:-}"

  jq -nc \
    --argjson existing "$existing_props_json" \
    --argjson local_props "$local_props_json" \
    --arg title_prop "$title_property" \
    --arg page_title "$title" \
    --arg rel_prop "$relation_property" \
    --arg rel_id "$relation_page_id" '
    ($existing + $local_props) as $merged
    | ($merged + {
        ($title_prop): { title: [{ text: { content: $page_title } }] }
      }) as $with_title
    | if $rel_prop != "" and $rel_id != "" then
        $with_title + { ($rel_prop): { relation: [{ id: $rel_id }] } }
      else
        $with_title
      end
  '
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
    notion_print_error "upload requires <file.md>"
    notion_upload_usage
    return 1
  fi

  # 2) Validate file exists and has .md extension.
  local abs_file="${file:A}"
  if [[ ! -f "$abs_file" ]]; then
    notion_print_error "file not found: $file"
    return 1
  fi

  if [[ "$abs_file" != *.md ]]; then
    notion_print_error "upload only supports .md files"
    return 1
  fi

  # 3) Locate config via find_config; read notes_root + mappings.
  local config_path
  config_path="$(notion_find_and_prepare_config)" || {
    notion_print_error "No project config found. Run 'ns init' first."
    return 1
  }

  # 4) Ensure file is inside notes_root.
  local notes_root
  notes_root="$(notion_config_get_notes_root "$config_path")"
  local abs_notes_root="${notes_root:A}"
  if ! notion_ensure_path_inside_notes_root "$abs_file" "$abs_notes_root"; then
    notion_print_error "file must be inside notes_root: $abs_notes_root"
    return 1
  fi

  # 5) Resolve first-level segment and require mapping.
  local relative_path first_segment
  relative_path="$(notion_relative_path_under_notes_root "$abs_file" "$abs_notes_root")" || {
    notion_print_error "file must be inside notes_root: $abs_notes_root"
    return 1
  }
  first_segment="${relative_path%%/*}"

  local relation_page_id relation_property
  relation_page_id="$(notion_config_get_mapping_relation_page_id "$config_path" "$first_segment")"
  relation_property="$(notion_config_get_mapping_relation_property "$config_path" "$first_segment")"
  if [[ -z "$relation_page_id" ]] && ! notion_is_root_level_relative_path "$relative_path"; then
    notion_print_error "no mapping found for first-level directory '$first_segment'"
    return 1
  fi

  local title
  title="$(basename "$abs_file" .md)"
  if [[ "$dry_run" -eq 1 ]]; then
    notion_print_info "Dry-run upload intent:"
    if [[ -n "$relation_page_id" ]]; then
      notion_print_sync_intent "query exact title+relation; update if found else create" "$abs_file" "$title" "$abs_notes_root" "$first_segment" "$relation_page_id" "$relation_property"
    else
      notion_print_sync_intent "query exact title; update if found else create" "$abs_file" "$title" "$abs_notes_root" "$first_segment" "$relation_page_id" "$relation_property"
    fi
    return 0
  fi

  # 6) Require token without leaking it to stdout.
  if ! notion_require_token >/dev/null; then
    return 1
  fi

  local notion_token
  notion_token="$(notion_require_token)"

  local database_id
  database_id="$(notion_config_get_database_id "$config_path")"
  local title_property
  title_property="$(notion_config_get_title_property "$config_path")"

  if [[ -z "$database_id" ]]; then
    notion_print_error "database_id missing in config. Re-run ns init."
    return 1
  fi

  # 7) Parse markdown with notion_parser.py and perform Notion API query/update/create.
  local parser_path
  parser_path="$(notion_parser_path)"
  if [[ ! -f "$parser_path" ]]; then
    notion_print_error "notion parser not found at $parser_path"
    notion_print_error "Set NOTION_PARSER_PATH or ensure lib/notion_parser.py is installed."
    return 1
  fi

  local tmp_blocks tmp_content tmp_props local_props_json
  tmp_blocks="$(mktemp)"
  tmp_content="$(mktemp)"
  tmp_props="$(mktemp)"
  local_props_json="$(notion_extract_frontmatter_properties "$abs_file" "$tmp_content" "$tmp_props")" || {
    rm -f "$tmp_blocks" "$tmp_content" "$tmp_props"
    return 1
  }
  if ! python3 "$parser_path" "$tmp_content" > "$tmp_blocks"; then
    rm -f "$tmp_blocks" "$tmp_content" "$tmp_props"
    notion_print_error "failed to parse markdown with $parser_path"
    return 1
  fi
  if ! jq -e . "$tmp_blocks" >/dev/null 2>&1; then
    rm -f "$tmp_blocks" "$tmp_content" "$tmp_props"
    notion_print_error "parser produced invalid JSON for '$abs_file'"
    return 1
  fi

  local filter search_response
  filter="$(notion_build_query_payload "$title" "$title_property" "$relation_page_id" "$relation_property")"

  search_response="$(notion_query_all "$database_id" "$notion_token" "$filter")" || return 1

  if printf '%s' "$search_response" | jq -e '.object == "error"' >/dev/null; then
    notion_print_error "Notion query failed: $(printf '%s' "$search_response" | jq -r '.message')"
    return 1
  fi

  # 8) Hard fail ambiguous exact matches (title + relation).
  local match_count
  match_count="$(printf '%s' "$search_response" | jq '.results | length')"
  if [[ "$match_count" -gt 1 ]]; then
    if [[ -n "$relation_page_id" ]]; then
      notion_print_error "ambiguous match for title '$title' in relation '$first_segment' ($match_count pages)."
      notion_print_warn "Refine remote data so only one exact title+relation page exists."
    else
      notion_print_error "ambiguous match for title '$title' ($match_count pages)."
      notion_print_warn "Refine remote data so only one exact title page exists."
    fi
    return 1
  fi

  local total_blocks
  total_blocks="$(jq 'length' "$tmp_blocks")"

  local page_id response existing_props_json merged_props_json
  page_id="$(printf '%s' "$search_response" | jq -r '.results[0].id // empty')"
  if [[ -n "$page_id" ]]; then
    existing_props_json="$(notion_serializable_page_properties "$(printf '%s' "$search_response" | jq -c '.results[0]')" "$title_property" "$relation_property")"
  else
    existing_props_json='{}'
  fi
  merged_props_json="$(notion_merge_upload_properties "$existing_props_json" "$local_props_json" "$title_property" "$title" "$relation_property" "$relation_page_id")"

  if [[ -n "$page_id" ]]; then
    response="$(notion_api_request "PATCH" "https://api.notion.com/v1/pages/$page_id" "$notion_token" '{"archived":true}')" || return 1
    if printf '%s' "$response" | jq -e '.object == "error"' >/dev/null; then
      rm -f "$tmp_blocks" "$tmp_content" "$tmp_props"
      notion_print_error "Notion sync failed: $(printf '%s' "$response" | jq -r '.message')"
      return 1
    fi
    page_id=""
  fi

  if [[ -z "$page_id" ]]; then
    local payload first_chunk_count start chunk_payload
    if [[ "$total_blocks" -gt 100 ]]; then
      first_chunk_count=100
    else
      first_chunk_count="$total_blocks"
    fi
    if [[ -n "$relation_page_id" ]]; then
      payload="$(jq -n \
        --arg db "$database_id" \
        --argjson first_chunk_count "$first_chunk_count" \
        --argjson props "$merged_props_json" \
        --slurpfile child_blocks "$tmp_blocks" \
        '{
          parent: { database_id: $db },
          properties: $props,
          children: ($child_blocks[0][0:$first_chunk_count])
        }')"
    else
      payload="$(jq -n \
        --arg db "$database_id" \
        --argjson first_chunk_count "$first_chunk_count" \
        --argjson props "$merged_props_json" \
        --slurpfile child_blocks "$tmp_blocks" \
        '{
          parent: { database_id: $db },
          properties: $props,
          children: ($child_blocks[0][0:$first_chunk_count])
        }')"
    fi

    response="$(notion_api_request "POST" "https://api.notion.com/v1/pages" "$notion_token" "$payload")" || return 1

    if printf '%s' "$response" | jq -e '.object == "error"' >/dev/null; then
      rm -f "$tmp_blocks" "$tmp_content" "$tmp_props"
      notion_print_error "Notion sync failed: $(printf '%s' "$response" | jq -r '.message')"
      return 1
    fi

    page_id="$(printf '%s' "$response" | jq -r '.id // empty')"
    if [[ -z "$page_id" ]]; then
      rm -f "$tmp_blocks" "$tmp_content" "$tmp_props"
      notion_print_error "Notion sync failed: create response missing page id."
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
        rm -f "$tmp_blocks" "$tmp_content" "$tmp_props"
        notion_print_error "Notion sync failed: $(printf '%s' "$response" | jq -r '.message')"
        return 1
      fi
      start=$((start + 100))
    done
  fi

  rm -f "$tmp_blocks" "$tmp_content" "$tmp_props"

  notion_print_success "Uploaded '$title' successfully."
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
    notion_print_error "download requires <file.md>"
    notion_download_usage
    return 1
  fi

  if [[ "$target" != *.md ]]; then
    notion_print_error "download requires a <*.md>"
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
    notion_print_error "No project config found. Run 'ns init' first."
    return 1
  }

  # echo "$config_path"
  local notes_root
  notes_root="$(notion_config_get_notes_root "$config_path")"
  local abs_notes_root="${notes_root:A}"
  if ! notion_ensure_path_inside_notes_root "$abs_target" "$abs_notes_root"; then
    notion_print_error "file must be inside notes_root: $abs_notes_root"
    return 1
  fi

  local relative_path
  relative_path="$(notion_relative_path_under_notes_root "$abs_target" "$abs_notes_root")" || {
    notion_print_error "file must be inside notes_root: $abs_notes_root"
    return 1
  }
  local first_seg="${relative_path%%/*}"

  local relation_page_id relation_property
  relation_page_id="$(notion_config_get_mapping_relation_page_id "$config_path" "$first_seg")"
  relation_property="$(notion_config_get_mapping_relation_property "$config_path" "$first_seg")"

  if [[ -z "$relation_page_id" ]] && ! notion_is_root_level_relative_path "$relative_path"; then
    notion_print_error "no mapping found for first-level directory '$first_seg'"
    return 1
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    notion_print_info "Dry-run download intent:"
    if [[ -n "$relation_page_id" ]]; then
      notion_print_sync_intent "query exact title+relation; overwrite local file if single match" "$abs_target" "$abs_target_name" "$abs_notes_root" "$first_seg" "$relation_page_id" "$relation_property"
    else
      notion_print_sync_intent "query exact title; overwrite local file if single match" "$abs_target" "$abs_target_name" "$abs_notes_root" "$first_seg" "$relation_page_id" "$relation_property"
    fi
    return 0
  fi

  local notion_token
  notion_token="$(notion_require_token)" || return 1

  local database_id
  database_id="$(notion_config_get_database_id "$config_path")"
  local title_property
  title_property="$(notion_config_get_title_property "$config_path")"

  if [[ -z "$database_id" ]]; then
    notion_print_error "database_id missing in config. Re-run ns init."
    return 1
  fi

  local query_payload search_response
  query_payload="$(notion_build_query_payload "$abs_target_name" "$title_property" "$relation_page_id" "$relation_property")"

  search_response="$(notion_query_all "$database_id" "$notion_token" "$query_payload")" || return 1

  if printf '%s' "$search_response" | jq -e '.object == "error"' >/dev/null; then
    notion_print_error "Notion query failed: $(printf '%s' "$search_response" | jq -r '.message')"
    return 1
  fi

  local match_count page_id page_json properties_json
  match_count="$(printf '%s' "$search_response" | jq '.results | length')"

  if [[ "$match_count" -eq 0 ]]; then
    if [[ -n "$relation_page_id" ]]; then
      notion_print_error "no remote page found for '$abs_target_name' in relation '$first_seg'"
    else
      notion_print_error "no remote page found for '$abs_target_name'"
    fi
    return 1
  fi

  if [[ "$match_count" -gt 1 ]]; then
    if [[ -n "$relation_page_id" ]]; then
      notion_print_error "ambiguous match for title '$abs_target_name' in relation '$first_seg' ($match_count pages)."
      notion_print_warn "Refine remote data so only one exact title+relation page exists."
    else
      notion_print_error "ambiguous match for title '$abs_target_name' ($match_count pages)."
      notion_print_warn "Refine remote data so only one exact title page exists."
    fi
    return 1
  fi

  page_id="$(printf '%s' "$search_response" | jq -r '.results[0].id // empty')"
  if [[ -z "$page_id" ]]; then
    notion_print_error "failed to resolve remote page id."
    return 1
  fi
  page_json="$(printf '%s' "$search_response" | jq -c '.results[0]')"
  properties_json="$(notion_serializable_page_properties "$page_json" "$title_property" "$relation_property")"

  local blocks_response
  blocks_response="$(notion_fetch_block_tree "$page_id" "$notion_token")" || return 1

  if printf '%s' "$blocks_response" | jq -e '.object == "error"' >/dev/null; then
    notion_print_error "Notion block fetch failed: $(printf '%s' "$blocks_response" | jq -r '.message')"
    return 1
  fi

  local parser_path md_content
  parser_path="$(notion_parser_path)"

  if [[ ! -f "$parser_path" ]]; then
    notion_print_error "notion parser not found at $parser_path"
    notion_print_error "Set NOTION_PARSER_PATH or ensure lib/notion_parser.py is installed."
    return 1
  fi

  if ! md_content="$(printf '%s' "$blocks_response" | jq '.results' | python3 "$parser_path" --reverse)"; then
    notion_print_error "failed to convert notion blocks to markdown with $parser_path"
    return 1
  fi

  mkdir -p "$abs_target_path"
  notion_render_markdown_with_properties "$properties_json" "$md_content" >"$abs_target"
  notion_print_success "Downloaded '$abs_target_name' to $abs_target"
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
  version | -v | --version)
    notion_cmd_version "$@"
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
    notion_print_error "Unknown command: $cmd"
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
    local config_path
    config_path="$(notion_find_and_prepare_config)" || {
      notion_print_error "No project config found. Run 'ns init' first."
      return 1
    }
    cat "$config_path"
    return 0
  fi
  if [[ "$file" != *.md ]]; then
    notion_print_error "status requires a <*.md>"
    notion_status_usage
    return 1
  fi

  local abs_file="${file:a}"
  local title="${abs_file:t:r}"
  local config_path
  config_path="$(notion_find_and_prepare_config)" || {
    notion_print_error "No project config found. Run 'ns init' first."
    return 1
  }

  local notes_root abs_notes_root
  notes_root="$(notion_config_get_notes_root "$config_path")"
  abs_notes_root="${notes_root:A}"
  if ! notion_ensure_path_inside_notes_root "$abs_file" "$abs_notes_root"; then
    notion_print_error "file must be inside notes_root: $abs_notes_root"
    return 1
  fi

  local relative_path first_segment
  relative_path="$(notion_relative_path_under_notes_root "$abs_file" "$abs_notes_root")" || {
    notion_print_error "file must be inside notes_root: $abs_notes_root"
    return 1
  }
  first_segment="${relative_path%%/*}"

  local database_id title_property relation_page_id relation_property
  database_id="$(notion_config_get_database_id "$config_path")"
  title_property="$(notion_config_get_title_property "$config_path")"
  relation_page_id="$(notion_config_get_mapping_relation_page_id "$config_path" "$first_segment")"
  relation_property="$(notion_config_get_mapping_relation_property "$config_path" "$first_segment")"
  if [[ -z "$relation_page_id" ]] && ! notion_is_root_level_relative_path "$relative_path"; then
    notion_print_error "no mapping found for first-level directory '$first_segment'"
    return 1
  fi

  local query_payload
  query_payload="$(notion_build_query_payload "$title" "$title_property" "$relation_page_id" "$relation_property")"

  local c_head="" c_key="" c_val="" c_reset=""
  if notion_is_tty; then
    c_head=$'\033[1;36m'
    c_key=$'\033[1;33m'
    c_val=$'\033[0;37m'
    c_reset=$'\033[0m'
  fi

  echo "${c_head}Status${c_reset}"
  echo "${c_key}  File${c_reset}: ${c_val}$abs_file${c_reset}"
  echo "${c_key}  Title${c_reset}: ${c_val}$title${c_reset}"
  echo "${c_key}  Config${c_reset}: ${c_val}$config_path${c_reset}"
  echo "${c_key}  Database${c_reset}: ${c_val}$database_id${c_reset}"
  echo "${c_key}  Title Prop${c_reset}: ${c_val}$title_property${c_reset}"
  echo "${c_key}  Notes Root${c_reset}: ${c_val}$abs_notes_root${c_reset}"
  echo "${c_key}  Relative Path${c_reset}: ${c_val}$relative_path${c_reset}"
  echo "${c_key}  Mapping Dir${c_reset}: ${c_val}$first_segment${c_reset}"
  echo "${c_key}  Relation Page${c_reset}: ${c_val}${relation_page_id:-<none>}${c_reset}"
  echo "${c_key}  Relation Prop${c_reset}: ${c_val}${relation_property:-<none>}${c_reset}"
  if [[ -n "$relation_page_id" ]]; then
    echo "${c_key}  Upload Intent${c_reset}: ${c_val}query exact title+relation; update if found else create${c_reset}"
    echo "${c_key}  Download Intent${c_reset}: ${c_val}query exact title+relation; overwrite local file if single match${c_reset}"
  else
    echo "${c_key}  Upload Intent${c_reset}: ${c_val}query exact title; update if found else create${c_reset}"
    echo "${c_key}  Download Intent${c_reset}: ${c_val}query exact title; overwrite local file if single match${c_reset}"
  fi
  echo "${c_key}  Query Filter${c_reset}: ${c_val}$query_payload${c_reset}"
}

notion_cmd_completion() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_completion_usage
    return 0
  fi
  if [[ "${1:-}" != "zsh" && "${1:-}" != "bash" ]]; then
    notion_print_error "completion requires shell target (supported: zsh, bash)"
    notion_completion_usage
    return 1
  fi

  if [[ "${1:-}" == "bash" ]]; then
    cat <<'EOF'
_ns() {
  local cur prev cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cmd="${COMP_WORDS[1]}"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "help init link status upload download completion version" -- "$cur") )
    return 0
  fi

  case "$cmd" in
    init)
      COMPREPLY=( $(compgen -W "--database-id --notes-root --title-property --force --help" -- "$cur") )
      ;;
    link)
      if [[ $COMP_CWORD -eq 2 ]]; then
        COMPREPLY=( $(compgen -d -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "--force --help" -- "$cur") )
      fi
      ;;
    status|upload|download)
      COMPREPLY=( $(compgen -f -X '!*.md' -- "$cur") )
      ;;
    completion)
      COMPREPLY=( $(compgen -W "zsh bash" -- "$cur") )
      ;;
  esac
}

complete -F _ns ns
EOF
    return 0
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
        'completion[Print completion script]' \
        'version[Show ns version]'
      ;;
    args)
      case $line[1] in
        init)
          _arguments '--database-id[Notion database id]:database id:' '--notes-root[Notes root path]:notes root:_files -/' '--title-property[Notion title property name]:title property:' '--force[Overwrite existing config]'
          ;;
        link)
          _arguments '1:subdir:_files -/' '2:relation page id:' '3:relation property:' '--force[Overwrite existing mapping]'
          ;;
        status|upload|download)
          _arguments '1:markdown file:_files -g "*.md"'
          ;;
        completion)
          _values 'shell' zsh bash
          ;;
      esac
      ;;
  esac
}

compdef _ns ns
EOF
}

notion_cmd_version() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_version_usage
    return 0
  fi
  if [[ $# -gt 0 ]]; then
    notion_print_error "version does not accept arguments"
    notion_version_usage
    return 1
  fi
  echo "ns ${NOTION_CLI_VERSION}"
}

if [[ "${ZSH_EVAL_CONTEXT:-}" == "toplevel" ]]; then
  notion_main "$@"
fi
