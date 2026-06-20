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
    local tmp_cfg
    tmp_cfg="$(mktemp)"
    jq '
      .watch = (.watch // {})
      | .watch.default_cooldown_seconds = (.watch.default_cooldown_seconds // .watch.cooldown_seconds // 60)
      | .watch.files = (
          if (.watch.files // null) != null then
            .watch.files
          elif (.sync_state.uploads // null) != null then
            (.sync_state.uploads
              | to_entries
              | map({
                  key: .key,
                  value: {
                    enabled: (.watch.auto_upload_on_save // false),
                    cooldown_seconds: (.watch.cooldown_seconds // 60),
                    last_uploaded_at: (.value.last_uploaded_at // 0)
                  }
                })
              | from_entries)
          else
            {}
          end
        )
      | del(.watch.auto_upload_on_save)
      | del(.watch.cooldown_seconds)
      | del(.sync_state)
    ' "$config_path" >"$tmp_cfg"
    mv "$tmp_cfg" "$config_path"
    return 0
  fi

  notion_print_error "Unsupported config version '$version' in $config_path"
  notion_print_error "Run a newer notion-cli version that supports this migration path."
  return 1
}

# Finds config from current directory context and runs migration/validation hook.
# Example: config_path="$(notion_find_and_prepare_config)"
notion_find_and_prepare_config() {
  local start_dir="${1:-}"
  local config_path
  if [[ -n "$start_dir" ]]; then
    config_path="$(find_config_from_dir "$start_dir")" || return 1
  else
    config_path="$(find_config)" || return 1
  fi
  notion_config_migrate_in_place "$config_path" || return 1
  echo "$config_path"
}
