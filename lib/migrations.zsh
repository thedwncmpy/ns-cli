#!/usr/bin/env zsh
set -euo pipefail

# Returns the current config schema version supported by this CLI.
# Example: notion_config_current_version
notion_config_current_version() {
  echo "1"
}

# Validates (and future-migrates) an on-disk config file in place.
# Example: notion_config_migrate_in_place "$config_path"
notion_config_migrate_in_place() {
  local config_path="$1"
  local version
  version="$(jq -r '.version // 0' "$config_path")"

  if [[ "$version" == "1" ]]; then
    return 0
  fi

  notion_print_error "Unsupported config version '$version' in $config_path"
  notion_print_error "Run a newer notion-cli version that supports this migration path."
  return 1
}

# Finds config from current directory context and runs migration/validation hook.
# Example: config_path="$(notion_find_and_prepare_config)"
notion_find_and_prepare_config() {
  local config_path
  config_path="$(find_config)" || return 1
  notion_config_migrate_in_place "$config_path" || return 1
  echo "$config_path"
}
