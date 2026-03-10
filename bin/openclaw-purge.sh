#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s nullglob

VERSION="0.2.0"
YES=false
DRY_RUN=false
AGGRESSIVE=false
NO_CLI=false
ALLOW_NPX=false

declare -a CHANGES=()
declare -a WARNINGS=()
declare -a REPO_PATHS=()

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET=""
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
fi

usage() {
  cat <<'EOF'
OpenClaw Purge

Usage:
  ./bin/openclaw-purge.sh [options]

Options:
  --yes           Skip confirmation prompt
  --dry-run       Print planned actions without deleting anything
  --aggressive    Scan additional app-data roots for names containing openclaw
  --no-cli        Skip built-in "openclaw uninstall" and package-manager uninstall attempts
  --allow-npx     Allow npx fallback when the openclaw CLI is missing
  --repo-path     Remove an explicit OpenClaw source checkout after service cleanup
  --help          Show this help message
  --version       Print version
EOF
}

log_step() {
  printf '%s[step]%s %s\n' "$C_BLUE" "$C_RESET" "$1"
}

log_info() {
  printf '%s[info]%s %s\n' "$C_BLUE" "$C_RESET" "$1"
}

log_ok() {
  printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

log_warn() {
  printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
  WARNINGS+=("$1")
}

log_err() {
  printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

record_change() {
  CHANGES+=("$1")
}

print_command() {
  printf '  %q' "$@"
  printf '\n'
}

run_destructive() {
  if $DRY_RUN; then
    printf '[dry-run]'
    print_command "$@"
    return 0
  fi
  if "$@"; then
    return 0
  fi
  return 1
}

run_best_effort() {
  if $DRY_RUN; then
    printf '[dry-run]'
    print_command "$@"
    return 0
  fi
  "$@" >/dev/null 2>&1 || true
}

remove_target() {
  local path="$1"
  local label="${2:-$1}"
  if [[ -e "$path" || -L "$path" ]]; then
    if run_destructive rm -rf "$path"; then
      log_ok "removed $label"
      record_change "$label"
    else
      log_warn "failed to remove $label"
    fi
  fi
}

remove_paths() {
  local path
  for path in "$@"; do
    remove_target "$path"
  done
}

remove_explicit_repo_paths() {
  local raw resolved

  ((${#REPO_PATHS[@]} > 0)) || return 0

  log_step "removing explicit source checkout paths"
  for raw in "${REPO_PATHS[@]}"; do
    if [[ ! -e "$raw" ]]; then
      log_warn "repo path not found: $raw"
      continue
    fi
    if [[ ! -d "$raw" ]]; then
      log_warn "repo path is not a directory: $raw"
      continue
    fi
    if ! resolved="$(cd "$raw" 2>/dev/null && pwd -P)"; then
      log_warn "could not resolve repo path: $raw"
      continue
    fi
    case "$resolved" in
      /|"$HOME")
        log_warn "refusing to remove unsafe repo path: $resolved"
        continue
        ;;
    esac
    remove_target "$resolved" "$resolved (source checkout)"
  done
}

remove_state_tree() {
  local state_dir="$1"
  local profile_dir

  log_step "removing known state directories"
  remove_external_config_if_needed "$state_dir"
  remove_target "$state_dir/workspace" "$state_dir/workspace"
  remove_target "$state_dir"

  while IFS= read -r profile_dir; do
    remove_target "$profile_dir/workspace" "$profile_dir/workspace"
    remove_target "$profile_dir"
  done < <(collect_profile_dirs)
}

confirm() {
  if $YES || $DRY_RUN; then
    return 0
  fi
  printf 'This will remove local OpenClaw data from this machine. Continue? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *)
      log_info "aborted"
      exit 0
      ;;
  esac
}

os_type() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux) printf 'linux' ;;
    *)
      log_err "unsupported OS: $(uname -s)"
      exit 1
      ;;
  esac
}

collect_profile_dirs() {
  local entry
  for entry in "$HOME"/.openclaw-*; do
    [[ -d "$entry" ]] || continue
    printf '%s\n' "$entry"
  done
}

remove_external_config_if_needed() {
  local state_dir="$1"
  local config_path="${OPENCLAW_CONFIG_PATH:-}"
  if [[ -z "$config_path" ]]; then
    return 0
  fi
  case "$config_path" in
    "$state_dir"/*|"$state_dir")
      return 0
      ;;
  esac
  remove_target "$config_path" "$config_path (OPENCLAW_CONFIG_PATH)"
}

try_cli_uninstall() {
  if $NO_CLI; then
    return 0
  fi
  if command -v openclaw >/dev/null 2>&1; then
    log_step "running built-in OpenClaw uninstall"
    if $DRY_RUN; then
      printf '[dry-run]'
      print_command openclaw uninstall --all --yes --non-interactive
      record_change "openclaw uninstall --all --yes --non-interactive"
      return 0
    fi
    if openclaw uninstall --all --yes --non-interactive; then
      log_ok "built-in uninstall finished"
      record_change "openclaw uninstall --all --yes --non-interactive"
    else
      log_warn "built-in uninstall failed; continuing with manual cleanup"
    fi
    else
      log_info "openclaw CLI not found; using manual cleanup only"
      if $ALLOW_NPX && command -v npx >/dev/null 2>&1; then
        log_step "running npx fallback uninstaller"
        if $DRY_RUN; then
          printf '[dry-run]'
          print_command npx -y openclaw uninstall --all --yes --non-interactive
          record_change "npx -y openclaw uninstall --all --yes --non-interactive"
          return 0
        fi
        if npx -y openclaw uninstall --all --yes --non-interactive; then
          log_ok "npx fallback uninstall finished"
          record_change "npx -y openclaw uninstall --all --yes --non-interactive"
        else
          log_warn "npx fallback uninstall failed; continuing with manual cleanup"
        fi
      fi
  fi
}

try_pkg_uninstall() {
  if $NO_CLI; then
    return 0
  fi

  if command -v npm >/dev/null 2>&1 && npm ls -g --depth=0 openclaw >/dev/null 2>&1; then
    log_step "removing global npm package"
    if run_destructive npm rm -g openclaw; then
      log_ok "removed global npm package"
      record_change "npm rm -g openclaw"
    else
      log_warn "failed to remove global npm package"
    fi
  fi

  if command -v pnpm >/dev/null 2>&1 && pnpm list -g --depth 0 openclaw >/dev/null 2>&1; then
    log_step "removing global pnpm package"
    if run_destructive pnpm remove -g openclaw; then
      log_ok "removed global pnpm package"
      record_change "pnpm remove -g openclaw"
    else
      log_warn "failed to remove global pnpm package"
    fi
  fi

  if command -v bun >/dev/null 2>&1; then
    if $DRY_RUN; then
      printf '[dry-run]'
      print_command bun remove -g openclaw
      record_change "bun remove -g openclaw"
    else
      if bun remove -g openclaw >/dev/null 2>&1; then
        log_ok "removed global bun package"
        record_change "bun remove -g openclaw"
      fi
    fi
  fi
}

cleanup_macos() {
  local plist label

  log_step "cleaning macOS launch agents"
  for plist in "$HOME"/Library/LaunchAgents/ai.openclaw*.plist "$HOME"/Library/LaunchAgents/com.openclaw*.plist; do
    [[ -e "$plist" ]] || continue
    label="$(basename "$plist" .plist)"
    run_best_effort launchctl bootout "gui/$UID/$label"
    remove_target "$plist"
  done

  log_step "removing macOS app bundles"
  remove_paths "/Applications/OpenClaw.app" "$HOME/Applications/OpenClaw.app"
}

cleanup_linux() {
  local unit_name unit_path

  log_step "cleaning systemd user services"
  for unit_path in "$HOME"/.config/systemd/user/openclaw-gateway*.service; do
    [[ -e "$unit_path" ]] || continue
    unit_name="$(basename "$unit_path")"
    run_best_effort systemctl --user disable --now "$unit_name"
    remove_target "$unit_path"
  done
  run_best_effort systemctl --user daemon-reload
}

aggressive_scan_macos() {
  local root
  local -a roots=(
    "$HOME/Library/Application Support"
    "$HOME/Library/Caches"
    "$HOME/Library/Logs"
    "$HOME/Library/Preferences"
    "$HOME/Library/Saved Application State"
    "$HOME/Library/WebKit"
  )

  log_step "aggressive scan in known macOS app-data roots"
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' match; do
      remove_target "$match"
    done < <(find "$root" -maxdepth 4 \( -iname '*openclaw*' -o -iname 'ai.openclaw*' -o -iname 'com.openclaw*' \) -print0 2>/dev/null)
  done
}

aggressive_scan_linux() {
  local root
  local -a roots=(
    "$HOME/.config"
    "$HOME/.cache"
    "$HOME/.local/share"
    "$HOME/.local/state"
  )

  log_step "aggressive scan in known Linux app-data roots"
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' match; do
      remove_target "$match"
    done < <(find "$root" -maxdepth 4 \( -iname '*openclaw*' -o -iname 'ai.openclaw*' -o -iname 'com.openclaw*' \) -print0 2>/dev/null)
  done
}

summary() {
  printf '\n'
  log_info "summary"
  printf '  mode: %s\n' "$([[ $DRY_RUN == true ]] && printf 'dry-run' || printf 'live')"
  printf '  changed targets: %s\n' "${#CHANGES[@]}"
  if ((${#CHANGES[@]} > 0)); then
    local item
    for item in "${CHANGES[@]}"; do
      printf '    - %s\n' "$item"
    done
  fi
  if ((${#WARNINGS[@]} > 0)); then
    printf '  warnings: %s\n' "${#WARNINGS[@]}"
  fi
  printf '\n'
  log_info "if OpenClaw used a remote gateway, run this script on that gateway host too"
}

while (($# > 0)); do
  case "$1" in
    --yes)
      YES=true
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --aggressive)
      AGGRESSIVE=true
      ;;
    --no-cli)
      NO_CLI=true
      ;;
    --allow-npx)
      ALLOW_NPX=true
      ;;
    --repo-path)
      shift
      if (($# == 0)); then
        log_err "--repo-path requires a directory argument"
        exit 1
      fi
      REPO_PATHS+=("$1")
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      printf '%s\n' "$VERSION"
      exit 0
      ;;
    *)
      log_err "unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

CURRENT_OS="$(os_type)"
STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"

log_info "OpenClaw Purge $VERSION"
log_info "detected OS: $CURRENT_OS"
if [[ ${EUID:-0} -eq 0 ]]; then
  log_warn "running as root is usually unnecessary"
fi

confirm
try_cli_uninstall

case "$CURRENT_OS" in
  macos)
    cleanup_macos
    ;;
  linux)
    cleanup_linux
    ;;
esac

remove_explicit_repo_paths
remove_state_tree "$STATE_DIR"

try_pkg_uninstall

if $AGGRESSIVE; then
  case "$CURRENT_OS" in
    macos)
      aggressive_scan_macos
      ;;
    linux)
      aggressive_scan_linux
      ;;
  esac
fi

summary
