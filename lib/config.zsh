#!/usr/bin/env zsh
set -euo pipefail

# Writes a fresh v1 config JSON file.
# Example: notion_write_config "$cfg_path" "db_123" "/abs/notes"
notion_write_config() {
  local cfg_path="$1"
  local database_id="$2"
  local abs_notes_root="$3"
  local title_property="${4:-Name}"

  local db_escaped root_escaped title_escaped
  db_escaped="$(json_escape "$database_id")"
  root_escaped="$(json_escape "$abs_notes_root")"
  title_escaped="$(json_escape "$title_property")"

  cat >"$cfg_path" <<JSON
{
  "version": 1,
  "database_id": "$db_escaped",
  "notes_root": "$root_escaped",
  "title_property": "$title_escaped",
  "mappings": {},
  "watch": {
    "default_cooldown_seconds": 60,
    "files": {}
  }
}
JSON
}

# Initializes project config directory and writes config (with --force semantics).
# Example: notion_init_config "db_123" "./notes" 0
notion_init_config() {
  local database_id="$1"
  local notes_root="$2"
  local force="$3"
  local title_property="${4:-Name}"

  local abs_notes_root="${notes_root:A}"
  local cfg_dir="$abs_notes_root/$NS_CONFIG_DIR_NAME"
  local cfg_path="$cfg_dir/config.json"

  if [[ -f "$cfg_path" && "$force" -ne 1 ]]; then
    notion_print_error "config already exists at $cfg_path (use --force to overwrite)"
    return 1
  fi

  mkdir -p "$cfg_dir"
  notion_write_config "$cfg_path" "$database_id" "$abs_notes_root" "$title_property"

  notion_print_success "Initialized config at $cfg_path"
}

# Finds $NS_CONFIG_DIR_NAME/config.json by walking up from current directory.
# Example: config_path="$(find_config)"
find_config() {
  local current_dir="${PWD:A}"
  while [[ "$current_dir" != "/" ]]; do
    if [[ -f "$current_dir/$NS_CONFIG_DIR_NAME/config.json" ]]; then
      echo "$current_dir/$NS_CONFIG_DIR_NAME/config.json"
      return 0
    fi
    current_dir="$(dirname "$current_dir")"
  done
  return 1
}

# Finds $NS_CONFIG_DIR_NAME/config.json by walking up from a starting directory.
# Example: config_path="$(find_config_from_dir "/abs/path")"
find_config_from_dir() {
  local start_dir="$1"
  local current_dir="${start_dir:A}"
  while [[ "$current_dir" != "/" ]]; do
    if [[ -f "$current_dir/$NS_CONFIG_DIR_NAME/config.json" ]]; then
      echo "$current_dir/$NS_CONFIG_DIR_NAME/config.json"
      return 0
    fi
    current_dir="$(dirname "$current_dir")"
  done
  return 1
}

# Reads notes_root from config.
# Example: notes_root="$(notion_config_get_notes_root "$config_path")"
notion_config_get_notes_root() {
  local config_path="$1"
  jq -r '.notes_root' "$config_path"
}

# Reads database_id from config.
# Example: database_id="$(notion_config_get_database_id "$config_path")"
notion_config_get_database_id() {
  local config_path="$1"
  jq -r '.database_id // empty' "$config_path"
}

# Reads title_property from config (defaults to Name).
# Example: title_prop="$(notion_config_get_title_property "$config_path")"
notion_config_get_title_property() {
  local config_path="$1"
  jq -r '.title_property // "Name"' "$config_path"
}

# Reads relation_page_id mapping for a first-level segment.
# Example: rel_id="$(notion_config_get_mapping_relation_page_id "$config_path" "project")"
notion_config_get_mapping_relation_page_id() {
  local config_path="$1"
  local segment="$2"
  jq -r --arg seg "$segment" '.mappings[$seg].relation_page_id // .mappings[$seg] // empty' "$config_path"
}

# Reads relation_property mapping for a first-level segment (defaults to notebook).
# Example: rel_prop="$(notion_config_get_mapping_relation_property "$config_path" "project")"
notion_config_get_mapping_relation_property() {
  local config_path="$1"
  local segment="$2"
  jq -r --arg seg "$segment" '.mappings[$seg].relation_property // "notebook"' "$config_path"
}

notion_config_get_watch_default_cooldown_seconds() {
  local config_path="$1"
  jq -r '.watch.default_cooldown_seconds // .watch.cooldown_seconds // 60' "$config_path"
}

notion_config_get_watch_file_enabled() {
  local config_path="$1"
  local relative_path="$2"
  jq -r --arg rel "$relative_path" '.watch.files[$rel].enabled // false' "$config_path"
}

notion_config_get_watch_file_cooldown_seconds() {
  local config_path="$1"
  local relative_path="$2"
  jq -r --arg rel "$relative_path" '.watch.files[$rel].cooldown_seconds // .watch.default_cooldown_seconds // .watch.cooldown_seconds // 60' "$config_path"
}

notion_config_set_watch_default_cooldown_seconds() {
  local config_path="$1"
  local cooldown_seconds="$2"
  local tmp_cfg

  tmp_cfg="$(mktemp)"
  jq \
    --argjson cooldown "$cooldown_seconds" \
    '
      .watch = ((.watch // {}) + {
        default_cooldown_seconds: $cooldown
      })
    ' "$config_path" >"$tmp_cfg"
  mv "$tmp_cfg" "$config_path"
}

notion_config_set_watch_file_settings() {
  local config_path="$1"
  local relative_path="$2"
  local enabled="$3"
  local cooldown_seconds="$4"
  local tmp_cfg

  tmp_cfg="$(mktemp)"
  jq \
    --arg rel "$relative_path" \
    --argjson enabled "$enabled" \
    --argjson cooldown "$cooldown_seconds" \
    '
      .watch = (.watch // {})
      | .watch.files = (.watch.files // {})
      | .watch.files[$rel] = ((.watch.files[$rel] // {}) + {
          enabled: $enabled,
          cooldown_seconds: $cooldown
        })
    ' "$config_path" >"$tmp_cfg"
  mv "$tmp_cfg" "$config_path"
}

notion_config_get_last_upload_epoch() {
  local config_path="$1"
  local relative_path="$2"
  jq -r --arg rel "$relative_path" '.watch.files[$rel].last_uploaded_at // 0' "$config_path"
}

notion_config_set_last_upload_epoch() {
  local config_path="$1"
  local relative_path="$2"
  local epoch="$3"
  local tmp_cfg

  tmp_cfg="$(mktemp)"
  jq \
    --arg rel "$relative_path" \
    --argjson epoch "$epoch" \
    '
      .watch = (.watch // {})
      | .watch.files = (.watch.files // {})
      | .watch.files[$rel] = ((.watch.files[$rel] // {}) + {last_uploaded_at: $epoch})
    ' "$config_path" >"$tmp_cfg"
  mv "$tmp_cfg" "$config_path"
}

notion_config_get_enabled_watch_files() {
  local config_path="$1"
  jq -r '.watch.files // {} | to_entries | map(select(.value.enabled == true) | .key) | .[]?' "$config_path"
}

notion_config_move_watch_file_state() {
  local config_path="$1"
  local old_relative_path="$2"
  local new_relative_path="$3"
  local tmp_cfg

  tmp_cfg="$(mktemp)"
  jq \
    --arg old_rel "$old_relative_path" \
    --arg new_rel "$new_relative_path" \
    '
      .watch = (.watch // {})
      | .watch.files = (.watch.files // {})
      | if .watch.files[$old_rel] == null then
          .
        else
          .watch.files[$new_rel] = .watch.files[$old_rel]
          | del(.watch.files[$old_rel])
        end
    ' "$config_path" >"$tmp_cfg"
  mv "$tmp_cfg" "$config_path"
}
