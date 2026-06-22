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

notion_current_epoch() {
  date +%s
}

notion_current_timestamp_local() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

notion_file_mtime_epoch() {
  local file_path="$1"
  python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$file_path"
}

notion_file_mtime_token() {
  local file_path="$1"
  python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_mtime_ns}:{s.st_size}")' "$file_path"
}

notion_sync_log_path() {
  local config_path="$1"
  local config_dir="${config_path:A:h}"
  echo "$config_dir/sync.log"
}

notion_append_sync_log_entry() {
  local config_path="$1"
  local notes_root="$2"
  local action="$3"
  local file_path="$4"

  local relative_path timestamp log_path
  relative_path="$(notion_relative_path_under_notes_root "$file_path" "$notes_root" 2>/dev/null || true)"
  if [[ -z "$relative_path" ]]; then
    relative_path="$file_path"
  fi

  timestamp="$(notion_current_timestamp_local)"
  log_path="$(notion_sync_log_path "$config_path")"
  mkdir -p "${log_path%/*}"
  printf '%s\t%s\t%s\n' "$timestamp" "$action" "$relative_path" >> "$log_path"
}

notion_watch_snapshot() {
  local notes_root="$1"
  local enabled_files_raw="$2"
  local rel abs_path mtime_token

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    abs_path="$notes_root/$rel"
    [[ -f "$abs_path" ]] || continue
    mtime_token="$(notion_file_mtime_token "$abs_path")" || continue
    printf '%s\t%s\n' "$rel" "$mtime_token"
  done <<< "$enabled_files_raw"
}

notion_watch_lock_dir() {
  local config_path="$1"
  local relative_path="$2"
  local config_dir lock_key

  config_dir="${config_path:A:h}"
  lock_key="${relative_path//\//__}"
  lock_key="${lock_key//:/_}"
  echo "$config_dir/locks/$lock_key.lock"
}

notion_watch_release_lock() {
  local lock_dir="$1"
  [[ -n "$lock_dir" ]] || return 0
  rm -f "$lock_dir/pid" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
}

notion_watch_lock_owner_alive() {
  local lock_dir="$1"
  local owner_pid=""

  [[ -f "$lock_dir/pid" ]] || return 1
  owner_pid="$(<"$lock_dir/pid")"
  [[ "$owner_pid" == <-> ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null
}

notion_watch_acquire_lock() {
  local lock_dir="$1"
  mkdir -p "${lock_dir%/*}"

  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock_dir/pid"
    return 0
  fi

  if notion_watch_lock_owner_alive "$lock_dir"; then
    return 1
  fi

  notion_watch_release_lock "$lock_dir"
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock_dir/pid"
    return 0
  fi

  return 1
}

notion_watch_process_file_change() {
  local config_path="$1"
  local notes_root="$2"
  local relative_path="$3"

  local now_epoch last_upload_epoch remaining abs_file cooldown_seconds lock_dir
  lock_dir="$(notion_watch_lock_dir "$config_path" "$relative_path")"
  if ! notion_watch_acquire_lock "$lock_dir"; then
    notion_print_warn "Skipping '$relative_path'; sync already in progress."
    return 0
  fi
  trap 'notion_watch_release_lock "$lock_dir"' EXIT INT TERM HUP

  local exit_code=1

  cooldown_seconds="$(notion_config_get_watch_file_cooldown_seconds "$config_path" "$relative_path")"
  now_epoch="$(notion_current_epoch)"
  last_upload_epoch="$(notion_config_get_last_upload_epoch "$config_path" "$relative_path")"
  if [[ -n "$last_upload_epoch" && "$last_upload_epoch" -gt 0 ]]; then
    remaining=$((cooldown_seconds - (now_epoch - last_upload_epoch)))
    if [[ "$remaining" -gt 0 ]]; then
      notion_print_warn "Skipping '$relative_path'; cooldown active for ${remaining}s."
      exit_code=0
      notion_watch_release_lock "$lock_dir"
      trap - EXIT INT TERM HUP
      return "$exit_code"
    fi
  fi

  abs_file="$notes_root/$relative_path"
  notion_print_info "Change detected: $relative_path"
  if notion_cmd_upload "$abs_file"; then
    notion_config_set_last_upload_epoch "$config_path" "$relative_path" "$now_epoch"
    exit_code=0
  fi

  notion_watch_release_lock "$lock_dir"
  trap - EXIT INT TERM HUP
  return "$exit_code"
}

notion_cmd_watch_upload() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_watch_upload_usage
    return 0
  fi

  local file="${1:-}"
  if [[ -z "$file" ]]; then
    notion_print_error "watch-upload requires <file.md>"
    notion_watch_upload_usage
    return 1
  fi

  if [[ "$file" != *.md ]]; then
    notion_print_error "watch-upload requires a <*.md>"
    notion_watch_upload_usage
    return 1
  fi

  local file_dir config_path
  file_dir="${file:A:h}"
  config_path="$(notion_find_and_prepare_config "$file_dir")" || {
    notion_print_error "No project config found. Run 'ns init' first."
    return 1
  }

  local notes_root abs_notes_root abs_file relative_path enabled
  notes_root="$(notion_config_get_notes_root "$config_path")"
  abs_notes_root="${notes_root:A}"
  abs_file="${file:A}"

  if ! notion_ensure_path_inside_notes_root "$abs_file" "$abs_notes_root"; then
    notion_print_error "file must be inside notes_root: $abs_notes_root"
    return 1
  fi

  relative_path="$(notion_relative_path_under_notes_root "$abs_file" "$abs_notes_root")" || {
    notion_print_error "file must be inside notes_root: $abs_notes_root"
    return 1
  }

  enabled="$(notion_config_get_watch_file_enabled "$config_path" "$relative_path")"
  if [[ "$enabled" != "true" ]]; then
    notion_print_info "Watch disabled for '$relative_path'; skipping upload."
    return 0
  fi

  notion_require_token >/dev/null || return 1
  notion_watch_process_file_change "$config_path" "$abs_notes_root" "$relative_path"
}

notion_cmd_watch() {
  local enable=""
  local cooldown_seconds=""
  local file_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --help | -h)
      notion_watch_usage
      return 0
      ;;
    --enable)
      enable="true"
      shift
      ;;
    --disable)
      enable="false"
      shift
      ;;
    --cooldown-seconds)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        notion_print_error "--cooldown-seconds requires a value"
        return 1
      fi
      if [[ ! "${2:-}" =~ ^[0-9]+$ ]]; then
        notion_print_error "--cooldown-seconds must be a non-negative integer"
        return 1
      fi
      cooldown_seconds="$2"
      shift 2
      ;;
    *)
      if [[ -n "$file_arg" ]]; then
        notion_print_error "watch accepts at most one <file.md>"
        notion_watch_usage
        return 1
      fi
      file_arg="$1"
      shift
      ;;
    esac
  done

  if [[ -z "$file_arg" && -n "$enable" ]]; then
    notion_print_error "watch activation requires <file.md>"
    notion_watch_usage
    return 1
  fi

  if [[ -z "$file_arg" && -n "$cooldown_seconds" && -z "$enable" ]]; then
    notion_print_error "watch cooldown updates require <file.md> or use the default config directly"
    notion_watch_usage
    return 1
  fi

  if [[ -n "$file_arg" && "$file_arg" != *.md ]]; then
    notion_print_error "watch requires a <*.md>"
    notion_watch_usage
    return 1
  fi

  if [[ -n "$enable" && "$enable" == "false" && -n "$cooldown_seconds" ]]; then
    notion_print_warn "Disabling watch for the file but preserving the configured cooldown."
  fi

  local config_path
  config_path="$(notion_find_and_prepare_config)" || {
    notion_print_error "No project config found. Run 'ns init' first."
    return 1
  }

  local notes_root abs_notes_root
  notes_root="$(notion_config_get_notes_root "$config_path")"
  abs_notes_root="${notes_root:A}"

  if [[ -n "$file_arg" ]]; then
    local abs_file relative_path current_enabled current_cooldown
    abs_file="${file_arg:A}"
    if ! notion_ensure_path_inside_notes_root "$abs_file" "$abs_notes_root"; then
      notion_print_error "file must be inside notes_root: $abs_notes_root"
      return 1
    fi
    relative_path="$(notion_relative_path_under_notes_root "$abs_file" "$abs_notes_root")" || {
      notion_print_error "file must be inside notes_root: $abs_notes_root"
      return 1
    }

    current_enabled="$(notion_config_get_watch_file_enabled "$config_path" "$relative_path")"
    current_cooldown="$(notion_config_get_watch_file_cooldown_seconds "$config_path" "$relative_path")"

    if [[ -n "$enable" || -n "$cooldown_seconds" ]]; then
      notion_config_set_watch_file_settings \
        "$config_path" \
        "$relative_path" \
        "${enable:-$current_enabled}" \
        "${cooldown_seconds:-$current_cooldown}"

      current_enabled="$(notion_config_get_watch_file_enabled "$config_path" "$relative_path")"
      current_cooldown="$(notion_config_get_watch_file_cooldown_seconds "$config_path" "$relative_path")"
      notion_print_success "Updated watch settings for '$relative_path': enabled=$current_enabled cooldown=${current_cooldown}s"
      return 0
    fi
  else
    if [[ -n "$cooldown_seconds" ]]; then
      notion_config_set_watch_default_cooldown_seconds "$config_path" "$cooldown_seconds"
    fi
  fi

  notion_require_token >/dev/null || return 1

  local enabled_files_raw
  enabled_files_raw="$(notion_config_get_enabled_watch_files "$config_path")"
  if [[ -z "$enabled_files_raw" ]]; then
    notion_print_error "no files have watch enabled. Run 'ns watch <file.md> --enable' first."
    return 1
  fi

  local poll_seconds max_loops loops snapshot_file
  poll_seconds="${NS_WATCH_POLL_SECONDS:-2}"
  max_loops="${NS_WATCH_MAX_LOOPS:-0}"
  loops=0
  snapshot_file="$(mktemp)"
  notion_watch_snapshot "$notes_root" "$enabled_files_raw" >"$snapshot_file"

  local enabled_count
  enabled_count="$(printf '%s\n' "$enabled_files_raw" | awk 'NF {count++} END {print count+0}')"
  notion_print_info "Watching $enabled_count enabled markdown file(s) under $notes_root"

  while true; do
    local current_snapshot changed=0 rel prev_mtime curr_mtime failures=0
    enabled_files_raw="$(notion_config_get_enabled_watch_files "$config_path")"
    current_snapshot="$(notion_watch_snapshot "$notes_root" "$enabled_files_raw")"

    while IFS=$'\t' read -r rel curr_mtime; do
      [[ -n "$rel" ]] || continue
      prev_mtime="$(awk -F $'\t' -v rel="$rel" '$1 == rel { print $2; exit }' "$snapshot_file")"
      if [[ -z "$prev_mtime" || "$curr_mtime" != "$prev_mtime" ]]; then
        changed=1
        notion_watch_process_file_change "$config_path" "$notes_root" "$rel" || failures=$((failures + 1))
      fi
    done <<< "$current_snapshot"

    printf '%s\n' "$current_snapshot" >"$snapshot_file"
    if [[ "$changed" -eq 1 && "$failures" -gt 0 ]]; then
      notion_print_warn "Watch iteration completed with $failures upload failure(s)."
    fi

    loops=$((loops + 1))
    if [[ "$max_loops" -gt 0 && "$loops" -ge "$max_loops" ]]; then
      break
    fi
    sleep "$poll_seconds"
  done

  rm -f "$snapshot_file"
}

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

notion_build_relation_filter_payload() {
  local relation_page_id="$1"
  local relation_property="$2"

  jq -n --arg relation "$relation_page_id" --arg rel_prop "$relation_property" '{
    filter: {
      property: $rel_prop,
      relation: { contains: $relation }
    }
  }'
}

notion_current_scope_mapping_json() {
  local config_path="$1"
  local notes_root="$2"
  local cwd="${PWD:A}"
  local abs_notes_root="${notes_root:A}"
  local relative_to_root=""

  if [[ "$cwd" == "$abs_notes_root" || "$cwd" == "$abs_notes_root/" ]]; then
    jq -nc '{mapping_dir:"", relation_page_id:"", relation_property:""}'
    return 0
  fi

  if [[ "$cwd" == "$abs_notes_root"/* ]]; then
    relative_to_root="${cwd#$abs_notes_root/}"
    local first_segment="${relative_to_root%%/*}"
    local relation_page_id relation_property
    relation_page_id="$(notion_config_get_mapping_relation_page_id "$config_path" "$first_segment")"
    relation_property="$(notion_config_get_mapping_relation_property "$config_path" "$first_segment")"
    if [[ -n "$relation_page_id" ]]; then
      jq -nc --arg mapping_dir "$first_segment" --arg relation_page_id "$relation_page_id" --arg relation_property "$relation_property" \
        '{mapping_dir:$mapping_dir, relation_page_id:$relation_page_id, relation_property:$relation_property}'
      return 0
    fi
  fi

  jq -nc '{mapping_dir:"", relation_page_id:"", relation_property:""}'
}

notion_page_title_from_json() {
  local page_json="$1"
  local title_property="$2"

  printf '%s' "$page_json" | jq -r --arg title_prop "$title_property" '
    .properties[$title_prop].title // []
    | map(.plain_text // .text.content // "")
    | join("")
  '
}

notion_download_page_to_target() {
  local page_json="$1"
  local abs_target="$2"
  local notion_token="$3"
  local config_path="$4"
  local notes_root="$5"
  local title_property="$6"
  local relation_property="${7:-}"

  local page_id properties_json icon_json metadata_json
  page_id="$(printf '%s' "$page_json" | jq -r '.id // empty')"
  if [[ -z "$page_id" ]]; then
    notion_print_error "failed to resolve remote page id."
    return 1
  fi

  properties_json="$(notion_serializable_page_properties "$page_json" "$title_property" "$relation_property")"
  icon_json="$(notion_serializable_page_icon "$page_json")"
  metadata_json="$(notion_build_download_metadata "$properties_json" "$icon_json")"

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

  mkdir -p "${abs_target%/*}"
  local display_name="${${abs_target##*/}%.md}"
  notion_render_markdown_with_properties "$metadata_json" "$md_content" >"$abs_target"
  notion_write_metadata_sidecar "$config_path" "$notes_root" "$abs_target" "$metadata_json" || return 1
  notion_append_sync_log_entry "$config_path" "$notes_root" "download" "$abs_target"
  notion_print_success "Downloaded '$display_name' to $abs_target"
}

notion_page_target_for_download_all() {
  local page_json="$1"
  local config_path="$2"
  local notes_root="$3"
  local title_property="$4"
  local forced_mapping_dir="${5:-}"
  local forced_relation_property="${6:-}"

  local title
  title="$(notion_page_title_from_json "$page_json" "$title_property")"
  if [[ -z "$title" ]]; then
    jq -nc '{object:"error", message:"page missing title"}'
    return 0
  fi

  if [[ -n "$forced_mapping_dir" ]]; then
    jq -nc --arg target "$notes_root/$forced_mapping_dir/$title.md" --arg relation_property "$forced_relation_property" \
      '{target:$target, relation_property:$relation_property}'
    return 0
  fi

  local mapping_match
  mapping_match="$(jq -c --argjson page "$page_json" '
    (.mappings // {})
    | to_entries
    | map(
        . as $entry
        | ($entry.value.relation_page_id // $entry.value // "") as $rel_id
        | ($entry.value.relation_property // "notebook") as $rel_prop
        | select(
            $rel_id != ""
            and (($page.properties[$rel_prop].relation // []) | map(.id) | index($rel_id)) != null
          )
        | {mapping_dir: $entry.key, relation_property: $rel_prop}
      )
  ' "$config_path")"

  local match_count
  match_count="$(printf '%s' "$mapping_match" | jq 'length')"
  if [[ "$match_count" -gt 1 ]]; then
    jq -nc --arg title "$title" '{object:"error", message:("page \"" + $title + "\" matches multiple directory mappings")}'
    return 0
  fi

  if [[ "$match_count" -eq 1 ]]; then
    jq -nc \
      --arg target "$notes_root/$(printf '%s' "$mapping_match" | jq -r '.[0].mapping_dir')/$title.md" \
      --arg relation_property "$(printf '%s' "$mapping_match" | jq -r '.[0].relation_property')" \
      '{target:$target, relation_property:$relation_property}'
    return 0
  fi

  jq -nc --arg target "$notes_root/$title.md" '{target:$target, relation_property:""}'
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

notion_metadata_sidecar_path() {
  local config_path="$1"
  local relative_path="$2"

  local config_dir="${config_path:A:h}"
  local rel_json="${relative_path%.md}.json"
  echo "$config_dir/pages/$rel_json"
}

notion_normalize_metadata_json() {
  local metadata_path="$1"

  if ! jq -e . "$metadata_path" >/dev/null 2>&1; then
    notion_print_error "invalid notion-properties metadata in '$metadata_path'"
    return 1
  fi

  jq -c '
    if has("properties") or has("icon") then
      {
        properties: (.properties // {}),
        icon: (.icon // null)
      }
    else
      {
        properties: .,
        icon: null
      }
    end
  ' "$metadata_path"
}

notion_extract_local_metadata() {
  local source_file="$1"
  local config_path="$2"
  local notes_root="$3"
  local tmp_content="$4"
  local tmp_props="$5"

  notion_split_markdown_properties "$source_file" "$tmp_content" "$tmp_props"

  local relative_path sidecar_path
  relative_path="$(notion_relative_path_under_notes_root "$source_file" "$notes_root")" || return 1
  sidecar_path="$(notion_metadata_sidecar_path "$config_path" "$relative_path")"

  if [[ -f "$sidecar_path" ]]; then
    notion_normalize_metadata_json "$sidecar_path"
    return 0
  fi

  if [[ ! -s "$tmp_props" ]]; then
    jq -nc '{properties:{}, icon:null}'
    return 0
  fi

  notion_normalize_metadata_json "$tmp_props"
}

notion_write_metadata_sidecar() {
  local config_path="$1"
  local notes_root="$2"
  local target_file="$3"
  local metadata_json="$4"

  local relative_path sidecar_path
  relative_path="$(notion_relative_path_under_notes_root "$target_file" "$notes_root")" || return 1
  sidecar_path="$(notion_metadata_sidecar_path "$config_path" "$relative_path")"

  mkdir -p "${sidecar_path%/*}"
  printf '%s\n' "$metadata_json" >"$sidecar_path"
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
  local existing_metadata_json="$1"
  local local_metadata_json="$2"
  local title_property="$3"
  local title="$4"
  local relation_property="${5:-}"
  local relation_page_id="${6:-}"

  jq -nc \
    --argjson existing "$existing_metadata_json" \
    --argjson local_meta "$local_metadata_json" \
    --arg title_prop "$title_property" \
    --arg page_title "$title" \
    --arg rel_prop "$relation_property" \
    --arg rel_id "$relation_page_id" '
    ($existing.properties + $local_meta.properties) as $merged_props
    | ($merged_props + {
        ($title_prop): { title: [{ text: { content: $page_title } }] }
      }) as $with_title
    | {
        properties:
          (if $rel_prop != "" and $rel_id != "" then
            $with_title + { ($rel_prop): { relation: [{ id: $rel_id }] } }
          else
            $with_title
          end),
        icon: ($local_meta.icon // $existing.icon // null)
      }
  '
}

notion_serializable_page_icon() {
  local page_json="$1"

  printf '%s' "$page_json" | jq -c '
    if .icon == null then null
    elif .icon.type == "emoji" then {type: "emoji", emoji: .icon.emoji}
    elif .icon.type == "external" then {type: "external", external: {url: .icon.external.url}}
    elif .icon.type == "file" then {type: "external", external: {url: .icon.file.url}}
    else null
    end
  '
}

notion_build_page_create_payload() {
  local database_id="$1"
  local page_metadata_json="$2"

  jq -n \
    --arg db "$database_id" \
    --argjson meta "$page_metadata_json" \
    '
    {
      parent: { database_id: $db },
      properties: $meta.properties
    }
    + (if $meta.icon == null then {} else {icon: $meta.icon} end)
  '
}

notion_resolve_appended_child_id() {
  local parent_id="$1"
  local notion_token="$2"
  local response="$3"
  local idx="$4"
  local count="$5"
  local child_parent_id children_response total start_index

  child_parent_id="$(printf '%s' "$response" | jq -r --argjson idx "$idx" '.results[$idx].id // empty')"
  if [[ -n "$child_parent_id" ]]; then
    printf '%s\n' "$child_parent_id"
    return 0
  fi

  children_response="$(notion_fetch_all_children_blocks "$parent_id" "$notion_token")" || return 1
  if printf '%s' "$children_response" | jq -e '.object == "error"' >/dev/null; then
    printf '%s\n' "$children_response"
    return 0
  fi

  total="$(printf '%s' "$children_response" | jq '.results | length')"
  start_index=$((total - count))
  if [[ "$start_index" -lt 0 ]]; then
    jq -n --arg message "Notion append response missing child block id and refetch returned too few child blocks." '{object:"error", message:$message}'
    return 0
  fi

  child_parent_id="$(printf '%s' "$children_response" | jq -r --argjson idx "$((start_index + idx))" '.results[$idx].id // empty')"
  if [[ -z "$child_parent_id" ]]; then
    jq -n --arg message "Notion append response missing child block id and refetch could not resolve it." '{object:"error", message:$message}'
    return 0
  fi

  printf '%s\n' "$child_parent_id"
}

notion_append_block_children_tree() {
  local parent_id="$1"
  local notion_token="$2"
  local blocks_json="$3"
  local total start chunk payload response count idx child_blocks child_count child_parent_id

  total="$(printf '%s' "$blocks_json" | jq 'length')"
  start=0
  while [[ "$start" -lt "$total" ]]; do
    chunk="$(printf '%s' "$blocks_json" | jq -c --argjson start "$start" '.[$start:($start + 100)]')"
    payload="$(printf '%s' "$chunk" | jq '{
      children: map(
        . as $block
        | ($block.type) as $type
        | $block
        | .[$type] |= del(.children)
      )
    }')"

    response="$(notion_api_request "PATCH" "https://api.notion.com/v1/blocks/$parent_id/children" "$notion_token" "$payload")" || return 1
    if printf '%s' "$response" | jq -e '.object == "error"' >/dev/null; then
      printf '%s\n' "$response"
      return 0
    fi

    count="$(printf '%s' "$chunk" | jq 'length')"
    idx=0
    while [[ "$idx" -lt "$count" ]]; do
      child_blocks="$(printf '%s' "$chunk" | jq -c --argjson idx "$idx" '.[$idx] as $block | ($block.type) as $type | $block[$type].children // []')"
      child_count="$(printf '%s' "$child_blocks" | jq 'length')"
      if [[ "$child_count" -gt 0 ]]; then
        child_parent_id="$(notion_resolve_appended_child_id "$parent_id" "$notion_token" "$response" "$idx" "$count")" || return 1
        if printf '%s' "$child_parent_id" | jq -e '.object == "error"' >/dev/null 2>&1; then
          printf '%s\n' "$child_parent_id"
          return 0
        fi
        response="$(notion_append_block_children_tree "$child_parent_id" "$notion_token" "$child_blocks")" || return 1
        if printf '%s' "$response" | jq -e '.object == "error"' >/dev/null; then
          printf '%s\n' "$response"
          return 0
        fi
      fi
      idx=$((idx + 1))
    done

    start=$((start + 100))
  done

  jq -n '{object:"list", results: []}'
}

notion_build_download_metadata() {
  local properties_json="$1"
  local icon_json="$2"

  jq -nc --argjson props "$properties_json" --argjson icon "$icon_json" '{
    properties: $props,
    icon: $icon
  }'
}

notion_metadata_has_no_content() {
  local metadata_json="$1"
  [[ "$(printf '%s' "$metadata_json" | jq -c '.properties == {} and .icon == null')" == "true" ]]
}

notion_render_markdown_with_properties_legacy_aware() {
  local metadata_json="$1"
  local markdown_body="$2"

  if notion_metadata_has_no_content "$metadata_json"; then
    printf "%s\n" "$markdown_body"
    return 0
  fi

  if [[ "$(printf '%s' "$metadata_json" | jq -c '.icon == null')" == "true" ]]; then
    printf "%s\n%s\n%s\n\n%s\n" "$NOTION_PROPERTIES_HEADER" "$(printf '%s' "$metadata_json" | jq -c '.properties')" "$NOTION_PROPERTIES_FOOTER" "$markdown_body"
    return 0
  fi

  printf "%s\n%s\n%s\n\n%s\n" "$NOTION_PROPERTIES_HEADER" "$metadata_json" "$NOTION_PROPERTIES_FOOTER" "$markdown_body"
}

notion_render_markdown_with_properties() {
  local metadata_json="$1"
  local markdown_body="$2"

  printf "%s\n" "$markdown_body"
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
  config_path="$(notion_find_and_prepare_config "${abs_file:h}")" || {
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

  local tmp_blocks tmp_content tmp_props local_metadata_json
  tmp_blocks="$(mktemp)"
  tmp_content="$(mktemp)"
  tmp_props="$(mktemp)"
  local_metadata_json="$(notion_extract_local_metadata "$abs_file" "$config_path" "$abs_notes_root" "$tmp_content" "$tmp_props")" || {
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

  local page_id response existing_metadata_json merged_metadata_json
  page_id="$(printf '%s' "$search_response" | jq -r '.results[0].id // empty')"
  if [[ -n "$page_id" ]]; then
    existing_metadata_json="$(jq -nc \
      --argjson props "$(notion_serializable_page_properties "$(printf '%s' "$search_response" | jq -c '.results[0]')" "$title_property" "$relation_property")" \
      --argjson icon "$(notion_serializable_page_icon "$(printf '%s' "$search_response" | jq -c '.results[0]')")" \
      '{properties: $props, icon: $icon}')"
  else
    existing_metadata_json='{"properties":{},"icon":null}'
  fi
  merged_metadata_json="$(notion_merge_upload_properties "$existing_metadata_json" "$local_metadata_json" "$title_property" "$title" "$relation_property" "$relation_page_id")"

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
    local payload blocks_json
    payload="$(notion_build_page_create_payload "$database_id" "$merged_metadata_json")"

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

    if [[ "$total_blocks" -gt 0 ]]; then
      blocks_json="$(jq -c . "$tmp_blocks")"
      response="$(notion_append_block_children_tree "$page_id" "$notion_token" "$blocks_json")" || return 1
      if printf '%s' "$response" | jq -e '.object == "error"' >/dev/null; then
        rm -f "$tmp_blocks" "$tmp_content" "$tmp_props"
        notion_print_error "Notion sync failed: $(printf '%s' "$response" | jq -r '.message')"
        return 1
      fi
    fi
  fi

  rm -f "$tmp_blocks" "$tmp_content" "$tmp_props"

  notion_append_sync_log_entry "$config_path" "$abs_notes_root" "upload" "$abs_file"
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

  local match_count page_json
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

  page_json="$(printf '%s' "$search_response" | jq -c '.results[0]')"
  notion_download_page_to_target "$page_json" "$abs_target" "$notion_token" "$config_path" "$abs_notes_root" "$title_property" "$relation_property"
}

notion_cmd_delete() {
  local dry_run=0
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
  fi
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_delete_usage
    return 0
  fi

  local file="${1:-}"
  if [[ -z "$file" ]]; then
    notion_print_error "delete requires <file.md>"
    notion_delete_usage
    return 1
  fi

  if [[ "$file" != *.md ]]; then
    notion_print_error "delete requires a <*.md>"
    notion_delete_usage
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

  local relation_page_id relation_property
  relation_page_id="$(notion_config_get_mapping_relation_page_id "$config_path" "$first_segment")"
  relation_property="$(notion_config_get_mapping_relation_property "$config_path" "$first_segment")"
  if [[ -z "$relation_page_id" ]] && ! notion_is_root_level_relative_path "$relative_path"; then
    notion_print_error "no mapping found for first-level directory '$first_segment'"
    return 1
  fi

  local sidecar_path
  sidecar_path="$(notion_metadata_sidecar_path "$config_path" "$relative_path")"

  if [[ "$dry_run" -eq 1 ]]; then
    notion_print_info "Dry-run delete intent:"
    if [[ -n "$relation_page_id" ]]; then
      notion_print_sync_intent "query exact title+relation; archive remote page and delete local file" "$abs_file" "$title" "$abs_notes_root" "$first_segment" "$relation_page_id" "$relation_property"
    else
      notion_print_sync_intent "query exact title; archive remote page and delete local file" "$abs_file" "$title" "$abs_notes_root" "$first_segment" "$relation_page_id" "$relation_property"
    fi
    echo "  local_file_exists: $([[ -f "$abs_file" ]] && echo yes || echo no)"
    echo "  sidecar_exists: $([[ -f "$sidecar_path" ]] && echo yes || echo no)"
    return 0
  fi

  if ! notion_require_token >/dev/null; then
    return 1
  fi

  local notion_token
  notion_token="$(notion_require_token)"
  local database_id title_property
  database_id="$(notion_config_get_database_id "$config_path")"
  title_property="$(notion_config_get_title_property "$config_path")"

  if [[ -z "$database_id" ]]; then
    notion_print_error "database_id missing in config. Re-run ns init."
    return 1
  fi

  local query_payload search_response
  query_payload="$(notion_build_query_payload "$title" "$title_property" "$relation_page_id" "$relation_property")"
  search_response="$(notion_query_all "$database_id" "$notion_token" "$query_payload")" || return 1

  if printf '%s' "$search_response" | jq -e '.object == "error"' >/dev/null; then
    notion_print_error "Notion query failed: $(printf '%s' "$search_response" | jq -r '.message')"
    return 1
  fi

  local match_count page_id response
  match_count="$(printf '%s' "$search_response" | jq '.results | length')"
  if [[ "$match_count" -eq 0 ]]; then
    if [[ -n "$relation_page_id" ]]; then
      notion_print_error "no remote page found for '$title' in relation '$first_segment'"
    else
      notion_print_error "no remote page found for '$title'"
    fi
    return 1
  fi

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

  page_id="$(printf '%s' "$search_response" | jq -r '.results[0].id // empty')"
  if [[ -z "$page_id" ]]; then
    notion_print_error "Notion delete failed: query response missing page id."
    return 1
  fi

  response="$(notion_api_request "PATCH" "https://api.notion.com/v1/pages/$page_id" "$notion_token" '{"archived":true}')" || return 1
  if printf '%s' "$response" | jq -e '.object == "error"' >/dev/null; then
    notion_print_error "Notion delete failed: $(printf '%s' "$response" | jq -r '.message')"
    return 1
  fi

  rm -f "$abs_file"
  rm -f "$sidecar_path"

  notion_append_sync_log_entry "$config_path" "$abs_notes_root" "delete" "$abs_file"
  notion_print_success "Deleted '$title' locally and archived the remote page."
  return 0
}

notion_cmd_download_all() {
  local dry_run=0
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
  fi
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_download_sync_usage
    return 0
  fi
  if [[ $# -gt 0 ]]; then
    notion_print_error "download-sync does not accept file arguments"
    notion_download_sync_usage
    return 1
  fi

  local files=()
  local found
  found="$(find . -type f -name '*.md' | LC_ALL=C sort)"
  if [[ -n "$found" ]]; then
    files=("${(@f)found}")
  fi

  if [[ "${#files[@]}" -eq 0 ]]; then
    notion_print_error "no markdown files found under current directory"
    return 1
  fi

  local file rel failures=0
  for file in "${files[@]}"; do
    rel="${file#./}"
    if [[ "$dry_run" -eq 1 ]]; then
      notion_cmd_download --dry-run "$rel" || failures=$((failures + 1))
    else
      notion_cmd_download "$rel" || failures=$((failures + 1))
    fi
  done

  if [[ "$failures" -gt 0 ]]; then
    notion_print_error "download-sync failed for $failures file(s)"
    return 1
  fi

  notion_print_success "Processed ${#files[@]} markdown file(s)."
  return 0
}

notion_cmd_upload_sync() {
  local dry_run=0
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
  fi
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_upload_sync_usage
    return 0
  fi
  if [[ $# -gt 0 ]]; then
    notion_print_error "upload-sync does not accept file arguments"
    notion_upload_sync_usage
    return 1
  fi

  local files=()
  local found
  found="$(find . -type f -name '*.md' | LC_ALL=C sort)"
  if [[ -n "$found" ]]; then
    files=("${(@f)found}")
  fi

  if [[ "${#files[@]}" -eq 0 ]]; then
    notion_print_error "no markdown files found under current directory"
    return 1
  fi

  local file rel failures=0
  for file in "${files[@]}"; do
    rel="${file#./}"
    if [[ "$dry_run" -eq 1 ]]; then
      notion_cmd_upload --dry-run "$rel" || failures=$((failures + 1))
    else
      notion_cmd_upload "$rel" || failures=$((failures + 1))
    fi
  done

  if [[ "$failures" -gt 0 ]]; then
    notion_print_error "upload-sync failed for $failures file(s)"
    return 1
  fi

  notion_print_success "Processed ${#files[@]} markdown file(s)."
  return 0
}

notion_cmd_download_database_scope() {
  local dry_run=0
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
  fi
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    notion_download_all_usage
    return 0
  fi
  if [[ $# -gt 0 ]]; then
    notion_print_error "download-all does not accept file arguments"
    notion_download_all_usage
    return 1
  fi

  local config_path
  config_path="$(notion_find_and_prepare_config)" || {
    notion_print_error "No project config found. Run 'ns init' first."
    return 1
  }

  local notes_root database_id title_property notion_token
  notes_root="$(notion_config_get_notes_root "$config_path")"
  database_id="$(notion_config_get_database_id "$config_path")"
  title_property="$(notion_config_get_title_property "$config_path")"
  notion_token="$(notion_require_token)" || return 1

  if [[ -z "$database_id" ]]; then
    notion_print_error "database_id missing in config. Re-run ns init."
    return 1
  fi

  local scope_json mapping_dir relation_page_id relation_property query_payload
  scope_json="$(notion_current_scope_mapping_json "$config_path" "$notes_root")"
  mapping_dir="$(printf '%s' "$scope_json" | jq -r '.mapping_dir')"
  relation_page_id="$(printf '%s' "$scope_json" | jq -r '.relation_page_id')"
  relation_property="$(printf '%s' "$scope_json" | jq -r '.relation_property')"

  if [[ -n "$relation_page_id" ]]; then
    query_payload="$(notion_build_relation_filter_payload "$relation_page_id" "$relation_property")"
  else
    query_payload='{}'
  fi

  local search_response
  search_response="$(notion_query_all "$database_id" "$notion_token" "$query_payload")" || return 1
  if printf '%s' "$search_response" | jq -e '.object == "error"' >/dev/null; then
    notion_print_error "Notion query failed: $(printf '%s' "$search_response" | jq -r '.message')"
    return 1
  fi

  local pages
  pages="$(printf '%s' "$search_response" | jq -c '.results[]?')"
  if [[ -z "$pages" ]]; then
    notion_print_error "no remote pages found in current sync scope"
    return 1
  fi

  local page page_target_json abs_target target_relation_property title processed=0 failures=0
  while IFS= read -r page; do
    [[ -n "$page" ]] || continue
    page_target_json="$(notion_page_target_for_download_all "$page" "$config_path" "$notes_root" "$title_property" "$mapping_dir" "$relation_property")"
    if printf '%s' "$page_target_json" | jq -e '.object == "error"' >/dev/null 2>&1; then
      notion_print_error "$(printf '%s' "$page_target_json" | jq -r '.message')"
      failures=$((failures + 1))
      continue
    fi

    abs_target="$(printf '%s' "$page_target_json" | jq -r '.target')"
    target_relation_property="$(printf '%s' "$page_target_json" | jq -r '.relation_property')"
    title="$(notion_page_title_from_json "$page" "$title_property")"

    if [[ "$dry_run" -eq 1 ]]; then
      echo "  file: $abs_target"
      echo "  title: $title"
      echo "  action: overwrite local file from remote page"
    else
      notion_download_page_to_target "$page" "$abs_target" "$notion_token" "$config_path" "$notes_root" "$title_property" "$target_relation_property" || failures=$((failures + 1))
    fi
    processed=$((processed + 1))
  done <<< "$pages"

  if [[ "$failures" -gt 0 ]]; then
    notion_print_error "download-all failed for $failures page(s)"
    return 1
  fi

  notion_print_success "Processed $processed page(s)."
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
  upload-sync)
    notion_cmd_upload_sync "$@"
    ;;
  watch)
    notion_cmd_watch "$@"
    ;;
  watch-upload)
    notion_cmd_watch_upload "$@"
    ;;
  download)
    notion_cmd_download "$@"
    ;;
  delete)
    notion_cmd_delete "$@"
    ;;
  download-all)
    notion_cmd_download_database_scope "$@"
    ;;
  download-sync)
    notion_cmd_download_all "$@"
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
      COMPREPLY=( $(compgen -W "help init link status upload upload-sync watch watch-upload download delete download-all download-sync completion version" -- "$cur") )
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
    status|upload|watch-upload|download|delete)
      COMPREPLY=( $(compgen -f -X '!*.md' -- "$cur") )
      ;;
    upload-sync|download-all|download-sync)
      COMPREPLY=( $(compgen -W "--dry-run --help" -- "$cur") )
      ;;
    watch)
      COMPREPLY=( $(compgen -W "--enable --disable --cooldown-seconds --help" -- "$cur") )
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
        'link[Map directory to relation or property]' \
        'status[Show resolved sync intent]' \
        'upload[Upload markdown file]' \
        'upload-sync[Upload all markdown files under current directory]' \
        'watch[Watch enabled markdown files and auto-upload on save]' \
        'watch-upload[Upload one markdown file if watch is enabled for it]' \
        'download[Download markdown file]' \
        'delete[Delete markdown file locally and archive matching Notion page]' \
        'download-all[Download all Notion pages in current sync scope]' \
        'download-sync[Download all markdown files under current directory]' \
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
        status|upload|watch-upload|download|delete)
          _arguments '1:markdown file:_files -g "*.md"'
          ;;
        upload-sync)
          _arguments '--dry-run[Show upload intent for each markdown file]' '--help[Show help]'
          ;;
        watch)
          _arguments '1:markdown file:_files -g "*.md"' '--enable[Enable auto upload on save for the specified file]' '--disable[Disable auto upload on save for the specified file]' '--cooldown-seconds[Cooldown between uploads of the same file]:seconds:' '--help[Show help]'
          ;;
        download-all|download-sync)
          _arguments '--dry-run[Show download intent for each item in scope]' '--help[Show help]'
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
