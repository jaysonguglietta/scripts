#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ORIGINAL_ARGS=("$@")
DRY_RUN=0
VERBOSE="${VERBOSE:-0}"
CHECK_REBOOT=1
UPDATE_AI=1
UPDATE_OLLAMA_MODELS=1
UPDATE_OPEN_WEBUI=1
OPEN_WEBUI_CONTAINER="${OPEN_WEBUI_CONTAINER:-open-webui}"
CUSTOM_LOG_DIR="${LOG_DIR:-}"
PACKAGE_MANAGER=""
PACKAGE_FAMILY=""
LOG_FILE=""
START_TIME_EPOCH=0

normalize_verbose() {
  case "${VERBOSE}" in
    ""|0|false|FALSE|no|NO|off|OFF)
      VERBOSE=0
      ;;
    *)
      VERBOSE=1
      ;;
  esac
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Safely update a Fedora or Debian-family server.

Options:
  -n, --dry-run         Preview package actions without applying them.
  -v, --verbose         Show system details and pending update information.
  --log-dir DIR         Write logs to DIR.
  --no-reboot-check     Skip reboot-required detection.
  --skip-ai             Skip Ollama, model, and Open WebUI updates.
  --skip-models         Update Ollama but do not refresh installed models.
  --skip-open-webui     Do not update the Open WebUI container.
  -h, --help            Show this help text.

Defaults:
  - Logs go to /var/log/system-updates when possible.
  - Logs fall back to /tmp/system-updates if needed.
  - Installed Ollama models are refreshed by re-pulling their existing tags.
  - Open WebUI is updated only when a container named open-webui exists.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

run_cmd() {
  local description="$1"
  shift

  printf '\n'
  log "$description"
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

choose_log_dir() {
  local requested="${1:-}"

  if [[ -n "$requested" ]]; then
    mkdir -p "$requested"
    printf '%s\n' "$requested"
    return 0
  fi

  if mkdir -p /var/log/system-updates 2>/dev/null; then
    printf '%s\n' "/var/log/system-updates"
    return 0
  fi

  mkdir -p /tmp/system-updates
  printf '%s\n' "/tmp/system-updates"
}

setup_logging() {
  local log_dir

  umask 077
  log_dir="$(choose_log_dir "$CUSTOM_LOG_DIR")"
  LOG_FILE="${log_dir}/${SCRIPT_NAME%.sh}-$(date '+%Y%m%d-%H%M%S').log"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

detect_package_manager() {
  if command -v dnf5 >/dev/null 2>&1; then
    PACKAGE_MANAGER="dnf5"
    PACKAGE_FAMILY="dnf"
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    PACKAGE_MANAGER="dnf"
    PACKAGE_FAMILY="dnf"
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PACKAGE_MANAGER="apt-get"
    PACKAGE_FAMILY="apt"
    return 0
  fi

  die "No supported package manager found. Expected dnf5, dnf, or apt-get."
}

show_system_overview() {
  local package_tool_version=""
  local uptime_text=""

  printf '\n'
  log "System overview"
  log "Hostname: $(hostname)"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    log "OS: ${PRETTY_NAME:-unknown}"
  fi

  log "Kernel: $(uname -r)"

  if command -v uptime >/dev/null 2>&1; then
    uptime_text="$(uptime -p 2>/dev/null || uptime)"
    log "Uptime: $uptime_text"
  fi

  package_tool_version="$("$PACKAGE_MANAGER" --version 2>/dev/null | head -n 1 || true)"
  if [[ -n "$package_tool_version" ]]; then
    log "Package tool: $package_tool_version"
  fi
}

show_disk_usage() {
  local label="$1"
  local -a paths=("/")

  if ! command -v df >/dev/null 2>&1; then
    return 0
  fi

  if [[ -d /boot ]]; then
    paths+=("/boot")
  fi

  printf '\n'
  log "$label"
  df -h "${paths[@]}" 2>/dev/null | awk 'NR == 1 || !seen[$NF]++' | sed 's/^/  /'
}

show_available_updates() {
  local rc=0

  printf '\n'
  log "Listing available updates"

  case "$PACKAGE_FAMILY" in
    dnf)
      set +e
      "$PACKAGE_MANAGER" check-update
      rc=$?
      set -e
      case "$rc" in
        0) log "No pending updates reported." ;;
        100) log "Update list displayed above." ;;
        *) log "Could not list updates (exit code $rc)." ;;
      esac
      ;;
    apt)
      if command -v apt >/dev/null 2>&1; then
        set +e
        apt list --upgradable 2>/dev/null
        rc=$?
        set -e
        if [[ "$rc" -ne 0 ]]; then
          log "Could not list upgradable packages with apt."
        fi
      else
        set +e
        apt-get -s full-upgrade
        rc=$?
        set -e
        if [[ "$rc" -ne 0 ]]; then
          log "Could not simulate full-upgrade to list pending packages."
        fi
      fi
      ;;
  esac
}

elapsed_seconds() {
  printf '%s\n' "$(( $(date +%s) - START_TIME_EPOCH ))"
}

update_with_dnf() {
  local -a cmd_flags=(-y)

  if [[ "$VERBOSE" -eq 1 ]]; then
    cmd_flags=(-v -y)
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cmd_flags+=(--assumeno)
  fi

  run_cmd "Refreshing repositories and applying available updates" \
    "$PACKAGE_MANAGER" "${cmd_flags[@]}" upgrade --refresh
  run_cmd "Removing unneeded packages" \
    "$PACKAGE_MANAGER" "${cmd_flags[@]}" autoremove

  if [[ "$DRY_RUN" -eq 0 ]]; then
    run_cmd "Cleaning cached metadata and packages" "$PACKAGE_MANAGER" clean all
  else
    log "Dry run enabled: skipping cache cleanup."
  fi
}

update_with_apt() {
  local -a cmd_flags=(-y)

  if [[ "$VERBOSE" -eq 1 ]]; then
    cmd_flags+=(-V)
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cmd_flags+=(-s)
  fi

  run_cmd "Refreshing package metadata" apt-get update
  run_cmd "Applying available updates" \
    apt-get "${cmd_flags[@]}" full-upgrade
  run_cmd "Removing unneeded packages" \
    apt-get "${cmd_flags[@]}" --purge autoremove

  if [[ "$DRY_RUN" -eq 0 ]]; then
    run_cmd "Cleaning package caches" apt-get clean
    run_cmd "Removing obsolete package files" apt-get autoclean
  else
    log "Dry run enabled: skipping cache cleanup."
  fi
}


update_ollama() {
  local ollama_bin=""
  local before_version=""
  local after_version=""
  local installer=""

  if ! command -v ollama >/dev/null 2>&1; then
    log "Ollama is not installed; skipping Ollama and model updates."
    return 0
  fi

  ollama_bin="$(command -v ollama)"
  before_version="$(ollama --version 2>/dev/null || true)"
  printf '\n'
  log "Updating Ollama"
  [[ -n "$before_version" ]] && log "Current Ollama version: $before_version"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run enabled: would update Ollama and restart its service."
  elif command -v rpm >/dev/null 2>&1 && rpm -qf "$ollama_bin" >/dev/null 2>&1; then
    log "Ollama is RPM-managed and was handled by the system package update."
    systemctl restart ollama 2>/dev/null || true
  else
    installer="$(mktemp /tmp/ollama-install.XXXXXX.sh)"
    if curl --fail --silent --show-error --location \
      https://ollama.com/install.sh --output "$installer"; then
      chmod 700 "$installer"
      run_cmd "Installing the latest Ollama release" sh "$installer"
      systemctl restart ollama 2>/dev/null || true
    else
      rm -f "$installer"
      die "Unable to download the Ollama installer."
    fi
    rm -f "$installer"
  fi

  after_version="$(ollama --version 2>/dev/null || true)"
  [[ -n "$after_version" ]] && log "Installed Ollama version: $after_version"
}

update_ollama_models() {
  local model=""
  local -a models=()

  if [[ "$UPDATE_OLLAMA_MODELS" -ne 1 ]]; then
    log "Skipping Ollama model updates by request."
    return 0
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    return 0
  fi

  if ! systemctl is-active --quiet ollama 2>/dev/null; then
    log "Ollama service is not active; skipping model updates."
    return 0
  fi

  mapfile -t models < <(ollama list 2>/dev/null | awk 'NR > 1 && NF > 0 {print $1}')
  if [[ "${#models[@]}" -eq 0 ]]; then
    log "No installed Ollama models were found."
    return 0
  fi

  printf '\n'
  log "Refreshing ${#models[@]} installed Ollama model(s)"
  for model in "${models[@]}"; do
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "Dry run: would run ollama pull $model"
    else
      run_cmd "Refreshing Ollama model: $model" ollama pull "$model"
    fi
  done
}

podman_as() {
  local owner="$1"
  shift

  if [[ "$owner" == "root" ]]; then
    podman "$@"
  else
    local uid
    uid="$(id -u "$owner")"
    runuser -u "$owner" -- env \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      podman "$@"
  fi
}

find_open_webui_owner() {
  if podman container exists "$OPEN_WEBUI_CONTAINER" 2>/dev/null; then
    printf '%s\n' root
    return 0
  fi

  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && \
    podman_as "$SUDO_USER" container exists "$OPEN_WEBUI_CONTAINER" 2>/dev/null; then
    printf '%s\n' "$SUDO_USER"
    return 0
  fi

  return 1
}

update_open_webui() {
  local owner=""
  local image=""
  local old_image_id=""
  local new_image_id=""
  local backup_file=""

  if [[ "$UPDATE_OPEN_WEBUI" -ne 1 ]]; then
    log "Skipping Open WebUI update by request."
    return 0
  fi

  if ! command -v podman >/dev/null 2>&1; then
    log "Podman is not installed; skipping Open WebUI update."
    return 0
  fi

  if ! owner="$(find_open_webui_owner)"; then
    log "No Podman container named '$OPEN_WEBUI_CONTAINER' was found; skipping Open WebUI update."
    return 0
  fi

  image="$(podman_as "$owner" inspect --format '{{.Config.Image}}' "$OPEN_WEBUI_CONTAINER" 2>/dev/null || true)"
  if [[ -z "$image" || "$image" == "<none>" ]]; then
    image="ghcr.io/open-webui/open-webui:main"
  fi

  old_image_id="$(podman_as "$owner" inspect --format '{{.Image}}' "$OPEN_WEBUI_CONTAINER")"
  printf '\n'
  log "Checking Open WebUI image as Podman user: $owner"
  log "Open WebUI image: $image"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run: would pull $image and recreate $OPEN_WEBUI_CONTAINER if its image changed."
    return 0
  fi

  run_cmd "Pulling the current Open WebUI image" podman_as "$owner" pull "$image"
  new_image_id="$(podman_as "$owner" image inspect --format '{{.Id}}' "$image")"

  if [[ "$old_image_id" == "$new_image_id" ]]; then
    log "Open WebUI is already current."
    return 0
  fi

  backup_file="${LOG_FILE%.log}-open-webui-inspect.json"
  podman_as "$owner" inspect "$OPEN_WEBUI_CONTAINER" > "$backup_file"
  log "Saved the prior container configuration to $backup_file"

  if podman_as "$owner" container clone --help >/dev/null 2>&1; then
    run_cmd "Recreating Open WebUI with the new image" \
      podman_as "$owner" container clone --destroy --force --run \
      --name "$OPEN_WEBUI_CONTAINER" "$OPEN_WEBUI_CONTAINER" "$image"
  else
    log "The installed Podman version lacks 'container clone'. The new image was pulled,"
    log "but the running Open WebUI container was not replaced automatically."
    return 0
  fi

  if podman_as "$owner" container inspect --format '{{.State.Running}}' "$OPEN_WEBUI_CONTAINER" | grep -qx true; then
    log "Open WebUI was updated and is running."
  else
    die "Open WebUI was recreated but is not running. Review: podman logs $OPEN_WEBUI_CONTAINER"
  fi
}

update_ai_components() {
  if [[ "$UPDATE_AI" -ne 1 ]]; then
    log "Skipping local AI updates by request."
    return 0
  fi

  update_ollama
  update_ollama_models
  update_open_webui
}

check_reboot_status() {
  if [[ "$CHECK_REBOOT" -ne 1 ]]; then
    return 0
  fi

  printf '\n'
  log "Checking whether a reboot is recommended"

  case "$PACKAGE_FAMILY" in
    dnf)
      if command -v needs-restarting >/dev/null 2>&1; then
        if needs-restarting -r >/dev/null 2>&1; then
          log "No reboot required."
        else
          case "$?" in
            1) log "Reboot recommended." ;;
            *) log "Could not determine reboot status from needs-restarting." ;;
          esac
        fi
      else
        log "Skipping reboot check: install needs-restarting for Fedora reboot detection."
      fi
      ;;
    apt)
      if [[ -f /var/run/reboot-required ]]; then
        log "Reboot recommended."
        if [[ -f /var/run/reboot-required.pkgs ]]; then
          log "Packages requesting a reboot:"
          sed 's/^/  - /' /var/run/reboot-required.pkgs
        fi
      else
        log "No reboot required."
      fi
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1
      ;;
    -v|--verbose)
      VERBOSE=1
      ;;
    --log-dir)
      shift
      [[ $# -gt 0 ]] || die "--log-dir requires a directory path."
      CUSTOM_LOG_DIR="$1"
      ;;
    --no-reboot-check)
      CHECK_REBOOT=0
      ;;
    --skip-ai)
      UPDATE_AI=0
      ;;
    --skip-models)
      UPDATE_OLLAMA_MODELS=0
      ;;
    --skip-open-webui)
      UPDATE_OPEN_WEBUI=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown option: $1"
      ;;
  esac
  shift
done

normalize_verbose

if [[ "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sudo is required when running as a non-root user."
  exec sudo --preserve-env=LOG_DIR,VERBOSE,OPEN_WEBUI_CONTAINER "$0" "${ORIGINAL_ARGS[@]}"
fi

setup_logging
START_TIME_EPOCH="$(date +%s)"
trap 'rc=$?; duration="$(elapsed_seconds)"; if [[ $rc -eq 0 ]]; then log "Update run finished successfully."; else log "Update run failed with exit code $rc."; fi; log "Elapsed time: ${duration}s"; if [[ -n "${LOG_FILE:-}" ]]; then log "Log saved to $LOG_FILE"; fi' EXIT
trap 'log "Update run interrupted."; exit 130' INT TERM

detect_package_manager

log "Starting update run on $(hostname)"
log "Package manager: $PACKAGE_MANAGER"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Mode: dry-run"
else
  log "Mode: apply changes"
fi
if [[ "$VERBOSE" -eq 1 ]]; then
  log "Verbose mode: enabled"
else
  log "Verbose mode: disabled"
fi
log "Log file: $LOG_FILE"

if [[ "$VERBOSE" -eq 1 ]]; then
  show_system_overview
  show_disk_usage "Disk usage before updates"
  show_available_updates
fi

case "$PACKAGE_FAMILY" in
  dnf)
    update_with_dnf
    ;;
  apt)
    update_with_apt
    ;;
  *)
    die "Unsupported package family: $PACKAGE_FAMILY"
    ;;
esac

update_ai_components

check_reboot_status

if [[ "$VERBOSE" -eq 1 ]]; then
  show_disk_usage "Disk usage after updates"
fi
