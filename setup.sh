#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./setup.sh [--config-dir DIRECTORY]

Install the Lua modules and connect them to Hammerspoon.
Defaults to ~/.hammerspoon. Existing files are backed up before updating;
the separate user configuration is preserved on subsequent runs.

Options:
  --config-dir DIRECTORY  Use a custom Hammerspoon configuration directory.
  -h, --help             Show this help.
EOF
}

fail() {
    printf 'Setup failed: %s\n' "$*" >&2
    exit 1
}

config_dir="${HOME:?HOME is not set}/.hammerspoon"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-dir)
            [[ $# -ge 2 && -n "$2" ]] || fail '--config-dir requires a directory.'
            config_dir="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done

source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
modules=(init.lua config.lua omniwm.lua normalize.lua workspace_chooser.lua icons.lua cache.lua i18n.lua canvas_picker.lua)
for file in "${modules[@]}" examples/hammerspoon-init.lua; do
    [[ -f "$source_dir/$file" ]] || fail "Missing source file: $source_dir/$file"
done

mkdir -p -- "$config_dir"
config_dir="$(cd -- "$config_dir" && pwd -P)"
install_dir="$config_dir/omniwm-workspace-chooser"
init_file="$config_dir/init.lua"
user_config="$config_dir/omniwm-workspace-chooser-config.lua"

for file in "$init_file" "$user_config"; do
    if [[ -e "$file" || -L "$file" ]]; then
        [[ -f "$file" ]] || fail "Expected a regular file: $file"
    fi
done
if [[ -e "$install_dir" || -L "$install_dir" ]]; then
    [[ -d "$install_dir" ]] || fail "Expected a directory: $install_dir"
    [[ "$(cd -- "$install_dir" && pwd -P)" != "$source_dir" ]] || fail 'Source and install directories are the same.'
fi

backup_dir=''
if [[ -e "$init_file" || -e "$install_dir" ]]; then
    backup_dir="$(mktemp -d "$config_dir/omniwm-workspace-chooser-backup.XXXXXX")"
    if [[ -e "$init_file" ]]; then cp -pL -- "$init_file" "$backup_dir/init.lua"; fi
    if [[ -e "$install_dir" ]]; then cp -RL -- "$install_dir" "$backup_dir/omniwm-workspace-chooser"; fi
fi

mkdir -p -- "$install_dir"
for file in "${modules[@]}"; do
    cp -- "$source_dir/$file" "$install_dir/$file"
done

if [[ ! -e "$user_config" ]]; then
    cp -- "$source_dir/examples/hammerspoon-init.lua" "$user_config"
    printf 'Created configuration: %s\n' "$user_config"
else
    printf 'Kept existing configuration: %s\n' "$user_config"
fi

# Recognize both the managed loader and an existing manual installation.
# Leave existing loader code intact to avoid duplicate hotkeys/configuration.
if [[ -f "$init_file" ]] && grep -Eq 'omniwmWorkspaceChooser|omniwm-workspace-chooser' "$init_file"; then
    printf 'Existing OmniWM loader found; init.lua unchanged.\n'
else
    cat >> "$init_file" <<'LUA'

-- OmniWM Workspace Column Mover (configuration in omniwm-workspace-chooser-config.lua)
require("omniwm-workspace-chooser-config")
LUA
    printf 'Added loader to: %s\n' "$init_file"
fi

printf '\nInstalled modules: %s\n' "$install_dir"
if [[ -n "$backup_dir" ]]; then printf 'Backup: %s\n' "$backup_dir"; fi
printf 'Edit settings in: %s\n' "$user_config"
printf '\nOpen Hammerspoon and choose Reload Config, then press Hyper + W.\n'
printf 'Grant Hammerspoon Accessibility access in System Settings if needed.\n'
