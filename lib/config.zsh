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
  "mappings": {}
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
  local cfg_dir="$abs_notes_root/.notion-cli"
  local cfg_path="$cfg_dir/config.json"

  if [[ -f "$cfg_path" && "$force" -ne 1 ]]; then
    notion_print_error "config already exists at $cfg_path (use --force to overwrite)"
    return 1
  fi

  mkdir -p "$cfg_dir"
  notion_write_config "$cfg_path" "$database_id" "$abs_notes_root" "$title_property"

  notion_print_success "Initialized config at $cfg_path"
}

# Finds .notion-cli/config.json by walking up from current directory.
# Example: config_path="$(find_config)"
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
