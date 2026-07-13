#!/usr/bin/env bash
# Daily system and Local LLM maintenance for Fedora/DNF and Debian/APT.
#
# Friendly Ollama models are rebuilt from:
#   /etc/ollama/modelfiles/<friendly-name>.modelfile
# Example:
#   /etc/ollama/modelfiles/general-assistant.modelfile
# creates or refreshes:
#   general-assistant:latest
#
# The script never reboots automatically and never deletes Ollama models,
# Podman volumes, or Open WebUI application data.

set -Eeuo pipefail

VERSION="2.2.1"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
ORIGINAL_ARGS=("$@")

DRY_RUN=0
VERBOSE="${VERBOSE:-0}"
UPDATE_SYSTEM=1
UPDATE_AI=1
UPDATE_OLLAMA=1
UPDATE_MODELS=1
REBUILD_ASSISTANTS=1
UPDATE_WEBUI=1
CHECK_REBOOT=1
CLEAN_CACHE=0

OLLAMA_SERVICE="${OLLAMA_SERVICE:-ollama.service}"
OLLAMA_URL="${OLLAMA_API_URL:-http://127.0.0.1:11434}"
MODELFILE_DIR="${OLLAMA_MODELFILE_DIR:-/etc/ollama/modelfiles}"

WEBUI_SERVICE="${OPEN_WEBUI_SERVICE:-}"
WEBUI_CONTAINER="${OPEN_WEBUI_CONTAINER:-open-webui}"
WEBUI_IMAGE="${OPEN_WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
WEBUI_URL="${OPEN_WEBUI_HEALTH_URL:-http://127.0.0.1:3000/}"
RESTART_WEBUI_FOR_MODELS="${RESTART_WEBUI_AFTER_MODEL_CHANGES:-1}"

LOG_DIR="${LOG_DIR:-}"
LOCK_FILE="${LOCK_FILE:-/run/lock/local-llm-updates.lock}"
LOG_FILE=""
PM=""
PM_FAMILY=""
START_TIME=0
WARNINGS=0
FAILURES=0
MODELS_CHECKED=0
MODELS_CHANGED=0
ASSISTANTS_REBUILT=0
ASSISTANTS_CHANGED=0
WEBUI_IMAGE_CHANGED=0
WEBUI_RESTARTED=0

declare -a CUSTOM_FILES=()
declare -a CUSTOM_NAMES=()
declare -A CUSTOM_TAGS=()
declare -A BASE_MODELS=()

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [options]

Updates operating-system packages, Ollama, installed base models, friendly
models built from Modelfiles, and a systemd-managed Open WebUI container.

Options:
  -n, --dry-run          Preview actions without applying them.
  -v, --verbose          Show additional system and disk information.
  --only-ai              Skip operating-system package updates.
  --skip-system          Skip operating-system package updates.
  --skip-ai              Skip Ollama, models, assistants, and Open WebUI.
  --skip-ollama          Do not update the Ollama application.
  --skip-models          Do not pull base Ollama models.
  --skip-assistants      Do not rebuild friendly/custom models.
  --skip-open-webui      Do not update or restart Open WebUI.
  --modelfile-dir DIR    Read custom Modelfiles from DIR.
                         Default: $MODELFILE_DIR
  --clean-cache          Clean package-manager caches after updates.
  --log-dir DIR          Write timestamped logs to DIR.
  --no-reboot-check      Skip reboot-required detection.
  --version              Show the script version.
  -h, --help             Show this help text.

Examples:
  sudo $SCRIPT_NAME --dry-run --verbose
  sudo $SCRIPT_NAME --only-ai --verbose
  sudo $SCRIPT_NAME --skip-open-webui
USAGE
}

boolean() {
  case "${1:-0}" in
    ""|0|false|FALSE|no|NO|off|OFF) printf '0\n' ;;
    *) printf '1\n' ;;
  esac
}

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); log "WARNING: $*"; }
fail() { FAILURES=$((FAILURES + 1)); log "ERROR: $*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

run() {
  local description="$1"
  shift
  printf '\n'
  log "$description"
  printf ' +'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=1 ;;
      -v|--verbose) VERBOSE=1 ;;
      --only-ai|--skip-system) UPDATE_SYSTEM=0; CHECK_REBOOT=0 ;;
      --skip-ai) UPDATE_AI=0 ;;
      --skip-ollama) UPDATE_OLLAMA=0 ;;
      --skip-models) UPDATE_MODELS=0 ;;
      --skip-assistants) REBUILD_ASSISTANTS=0 ;;
      --skip-open-webui) UPDATE_WEBUI=0 ;;
      --clean-cache) CLEAN_CACHE=1 ;;
      --no-reboot-check) CHECK_REBOOT=0 ;;
      --modelfile-dir)
        shift
        [[ $# -gt 0 ]] || die "--modelfile-dir requires a directory."
        MODELFILE_DIR="$1"
        ;;
      --log-dir)
        shift
        [[ $# -gt 0 ]] || die "--log-dir requires a directory."
        LOG_DIR="$1"
        ;;
      --version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done
}

require_root() {
  [[ "$EUID" -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || die "sudo is required."
  exec sudo --preserve-env=LOG_DIR,VERBOSE,OLLAMA_SERVICE,OLLAMA_API_URL,\
OLLAMA_MODELFILE_DIR,OPEN_WEBUI_SERVICE,OPEN_WEBUI_CONTAINER,OPEN_WEBUI_IMAGE,\
OPEN_WEBUI_HEALTH_URL,RESTART_WEBUI_AFTER_MODEL_CHANGES,LOCK_FILE \
    "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
}

setup_logging() {
  umask 077
  if [[ -z "$LOG_DIR" ]]; then
    if mkdir -p /var/log/system-updates 2>/dev/null; then
      LOG_DIR=/var/log/system-updates
    else
      LOG_DIR=/tmp/system-updates
      mkdir -p "$LOG_DIR"
    fi
  else
    mkdir -p "$LOG_DIR"
  fi
  LOG_FILE="$LOG_DIR/${SCRIPT_NAME%.sh}-$(date '+%Y%m%d-%H%M%S').log"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || {
    warn "flock is unavailable; overlapping runs cannot be prevented."
    return 0
  }
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another update process already holds $LOCK_FILE."
}

on_exit() {
  local rc=$?
  local elapsed=0
  [[ "$START_TIME" -gt 0 ]] && elapsed=$(( $(date +%s) - START_TIME ))
  if [[ "$rc" -eq 0 && "$FAILURES" -eq 0 ]]; then
    log "Update run finished successfully."
  else
    log "Update run finished with errors (status $rc; failures $FAILURES)."
  fi
  log "Elapsed time: ${elapsed}s"
  [[ -n "$LOG_FILE" ]] && log "Log saved to $LOG_FILE"
}

detect_pm() {
  if command -v dnf5 >/dev/null 2>&1; then PM=dnf5; PM_FAMILY=dnf
  elif command -v dnf >/dev/null 2>&1; then PM=dnf; PM_FAMILY=dnf
  elif command -v apt-get >/dev/null 2>&1; then PM=apt-get; PM_FAMILY=apt
  else die "Expected dnf5, dnf, or apt-get."
  fi
}

show_overview() {
  printf '\n'
  log "System overview"
  log "Hostname: $(hostname)"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    log "OS: ${PRETTY_NAME:-unknown}"
  fi
  log "Kernel: $(uname -r)"
  log "Uptime: $(uptime -p 2>/dev/null || uptime)"
  command -v ollama >/dev/null 2>&1 && \
    log "Ollama: $(ollama --version 2>/dev/null || printf unknown)"
  command -v podman >/dev/null 2>&1 && \
    log "Podman: $(podman --version 2>/dev/null || printf unknown)"
  df -h / /boot 2>/dev/null | awk 'NR == 1 || !seen[$NF]++' | sed 's/^/  /'
}

update_system_packages() {
  local rc=0
  local -a dnf_flags=(-y)
  local -a apt_flags=(-y)

  [[ "$UPDATE_SYSTEM" -eq 1 ]] || { log "Skipping operating-system updates."; return 0; }

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '\n'
    log "Previewing operating-system updates"
    set +e
    case "$PM_FAMILY" in
      dnf) "$PM" upgrade --refresh --assumeno ;;
      apt) apt-get -s full-upgrade ;;
    esac
    rc=$?
    set -e
    case "$PM_FAMILY:$rc" in
      dnf:0|dnf:1|dnf:100|apt:0) ;;
      *) warn "Package preview exited with status $rc." ;;
    esac
    return 0
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    dnf_flags=(-v -y)
    apt_flags=(-V -y)
  fi

  case "$PM_FAMILY" in
    dnf)
      run "Updating Fedora packages" "$PM" "${dnf_flags[@]}" upgrade --refresh || {
        fail "DNF upgrade failed."
        return 1
      }
      run "Removing unneeded Fedora packages" "$PM" "${dnf_flags[@]}" autoremove || \
        warn "DNF autoremove failed."
      [[ "$CLEAN_CACHE" -eq 1 ]] && run "Cleaning DNF caches" "$PM" clean all || true
      ;;
    apt)
      run "Refreshing APT metadata" apt-get update || {
        fail "APT metadata refresh failed."
        return 1
      }
      run "Updating Debian-family packages" apt-get "${apt_flags[@]}" full-upgrade || {
        fail "APT full-upgrade failed."
        return 1
      }
      run "Removing unneeded Debian-family packages" \
        apt-get "${apt_flags[@]}" --purge autoremove || warn "APT autoremove failed."
      if [[ "$CLEAN_CACHE" -eq 1 ]]; then
        run "Cleaning APT cache" apt-get clean || true
        run "Removing obsolete APT files" apt-get autoclean || true
      fi
      ;;
  esac
}

wait_for_url() {
  local url="$1" timeout="${2:-60}" description="${3:-service}" start
  command -v curl >/dev/null 2>&1 || {
    warn "curl is unavailable; cannot health-check $description."
    return 0
  }
  start=$(date +%s)
  while (( $(date +%s) - start < timeout )); do
    if curl --fail --silent --max-time 5 "$url" >/dev/null 2>&1; then
      log "$description health check passed: $url"
      return 0
    fi
    sleep 2
  done
  return 1
}

ensure_ollama() {
  systemctl cat "$OLLAMA_SERVICE" >/dev/null 2>&1 || {
    fail "Ollama service not found: $OLLAMA_SERVICE"
    return 1
  }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    systemctl is-active --quiet "$OLLAMA_SERVICE" || \
      warn "$OLLAMA_SERVICE is inactive; dry-run model discovery may fail."
    return 0
  fi
  systemctl enable "$OLLAMA_SERVICE" >/dev/null 2>&1 || true
  systemctl is-active --quiet "$OLLAMA_SERVICE" || \
    run "Starting Ollama" systemctl start "$OLLAMA_SERVICE" || {
      fail "Could not start $OLLAMA_SERVICE."
      return 1
    }
  wait_for_url "${OLLAMA_URL%/}/api/tags" 60 Ollama || {
    fail "Ollama did not become healthy at ${OLLAMA_URL%/}/api/tags."
    return 1
  }
}

package_owns_file() {
  local file="$1"
  command -v rpm >/dev/null 2>&1 && rpm -qf "$file" >/dev/null 2>&1 && return 0
  command -v dpkg-query >/dev/null 2>&1 && \
    dpkg-query -S "$file" >/dev/null 2>&1 && return 0
  return 1
}

update_ollama_application() {
  local binary resolved installer
  [[ "$UPDATE_OLLAMA" -eq 1 ]] || { log "Skipping Ollama application update."; return 0; }
  command -v ollama >/dev/null 2>&1 || { fail "Ollama is not installed."; return 1; }

  binary=$(command -v ollama)
  resolved=$(readlink -f "$binary" 2>/dev/null || printf '%s' "$binary")
  printf '\n'
  log "Current $(ollama --version 2>/dev/null || printf 'Ollama version unknown')"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run: would update Ollama and restart $OLLAMA_SERVICE."
    return 0
  fi

  if package_owns_file "$resolved"; then
    if [[ "$UPDATE_SYSTEM" -eq 1 ]]; then
      log "Ollama is package-managed and was handled by the system update."
    else
      warn "Ollama is package-managed; it was not checked because system updates were skipped."
    fi
  else
    installer=$(mktemp /tmp/ollama-install.XXXXXX.sh)
    if ! curl --fail --silent --show-error --location \
        https://ollama.com/install.sh --output "$installer"; then
      rm -f "$installer"
      fail "Could not download the Ollama installer."
      return 1
    fi
    chmod 700 "$installer"
    run "Installing the current Ollama release" sh "$installer" || {
      rm -f "$installer"
      fail "The Ollama installer failed."
      return 1
    }
    rm -f "$installer"
  fi

  systemctl daemon-reload || warn "systemd daemon-reload failed after the Ollama update."
  run "Restarting Ollama" systemctl restart "$OLLAMA_SERVICE" || {
    fail "Could not restart $OLLAMA_SERVICE."
    return 1
  }
  ensure_ollama
}

canonical_model() {
  local ref="$1" last="${1##*/}"
  [[ "$last" == *:* ]] && printf '%s\n' "$ref" || printf '%s:latest\n' "$ref"
}

model_id() {
  local requested="$1" canonical
  canonical=$(canonical_model "$requested")
  ollama list 2>/dev/null | awk -v a="$requested" -v b="$canonical" \
    'NR > 1 && ($1 == a || $1 == b) {print $2; exit}'
}

modelfile_name() {
  local name
  name=$(basename "$1")
  printf '%s\n' "${name%.*}"
}

modelfile_from() {
  awk '
    /^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+/ {
      value=$0
      sub(/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$1"
}

discover_custom_models() {
  local file name
  CUSTOM_FILES=(); CUSTOM_NAMES=(); CUSTOM_TAGS=()
  [[ -d "$MODELFILE_DIR" ]] || { log "No custom Modelfile directory: $MODELFILE_DIR"; return 0; }

  while IFS= read -r -d '' file; do
    name=$(modelfile_name "$file")
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
      warn "Skipping $file; use a lowercase filename such as my-assistant.modelfile."
      continue
    fi
    if [[ -n "${CUSTOM_TAGS[$name]:-}" ]]; then
      warn "Skipping duplicate custom model name: $name"
      continue
    fi
    CUSTOM_FILES+=("$file")
    CUSTOM_NAMES+=("$name")
    CUSTOM_TAGS["$name"]=1
    CUSTOM_TAGS["$name:latest"]=1
  done < <(find "$MODELFILE_DIR" -maxdepth 1 -type f -iname '*.modelfile' -print0 | sort -z)
  log "Discovered ${#CUSTOM_FILES[@]} custom Modelfile(s) in $MODELFILE_DIR."
}

is_custom_model() {
  local ref="$1" canonical
  canonical=$(canonical_model "$ref")
  [[ -n "${CUSTOM_TAGS[$ref]:-}" || -n "${CUSTOM_TAGS[$canonical]:-}" ]]
}

is_pullable_ref() {
  local ref="$1"
  [[ -n "$ref" ]] || return 1
  [[ "$ref" != /* && "$ref" != ./* && "$ref" != ../* ]] || return 1
  [[ "$ref" != *.gguf && "$ref" != sha256-* && "$ref" != *'/blobs/'* ]] || return 1
}

collect_base_models() {
  local installed model file from
  BASE_MODELS=()
  installed=$(ollama list 2>/dev/null) || { fail "Could not read installed Ollama models."; return 1; }

  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    is_custom_model "$model" && continue
    BASE_MODELS["$(canonical_model "$model")"]=1
  done < <(printf '%s\n' "$installed" | awk 'NR > 1 && NF {print $1}')

  for file in "${CUSTOM_FILES[@]}"; do
    from=$(modelfile_from "$file")
    [[ -n "$from" ]] || { warn "No FROM instruction found in $file."; continue; }
    is_pullable_ref "$from" || continue
    is_custom_model "$from" && continue
    BASE_MODELS["$(canonical_model "$from")"]=1
  done
}

pull_base_models() {
  local model before after
  [[ "$UPDATE_MODELS" -eq 1 ]] || { log "Skipping Ollama base-model updates."; return 0; }
  ensure_ollama || return 1
  collect_base_models || return 1
  [[ "${#BASE_MODELS[@]}" -gt 0 ]] || { log "No pullable Ollama base models were found."; return 0; }

  printf '\n'
  log "Checking ${#BASE_MODELS[@]} Ollama base model(s)"
  while IFS= read -r model; do
    MODELS_CHECKED=$((MODELS_CHECKED + 1))
    before=$(model_id "$model" || true)
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "Dry run: would run ollama pull $model"
      continue
    fi
    run "Refreshing Ollama base model: $model" ollama pull "$model" || {
      fail "Failed to pull $model."
      continue
    }
    after=$(model_id "$model" || true)
    if [[ -z "$before" || "$before" != "$after" ]]; then
      MODELS_CHANGED=$((MODELS_CHANGED + 1))
      log "Base model changed: $model (${before:-new} -> ${after:-unknown})"
    else
      log "Base model already current: $model"
    fi
  done < <(printf '%s\n' "${!BASE_MODELS[@]}" | sort)
}

rebuild_custom_models() {
  local i file name from before after
  [[ "$REBUILD_ASSISTANTS" -eq 1 ]] || { log "Skipping custom model rebuilds."; return 0; }
  [[ "${#CUSTOM_FILES[@]}" -gt 0 ]] || { log "No custom models need rebuilding."; return 0; }
  ensure_ollama || return 1

  printf '\n'
  log "Rebuilding ${#CUSTOM_FILES[@]} friendly/custom model(s)"
  for ((i=0; i<${#CUSTOM_FILES[@]}; i++)); do
    file="${CUSTOM_FILES[$i]}"
    name="${CUSTOM_NAMES[$i]}"
    from=$(modelfile_from "$file")
    [[ -n "$from" ]] || { fail "Cannot rebuild $name; $file has no FROM instruction."; continue; }

    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "Dry run: would run ollama create $name -f $file (FROM $from)"
      continue
    fi

    before=$(model_id "$name:latest" || true)
    run "Rebuilding custom model: $name (FROM $from)" ollama create "$name" -f "$file" || {
      fail "Failed to rebuild $name."
      continue
    }
    after=$(model_id "$name:latest" || true)
    ASSISTANTS_REBUILT=$((ASSISTANTS_REBUILT + 1))
    if [[ -z "$before" || "$before" != "$after" ]]; then
      ASSISTANTS_CHANGED=$((ASSISTANTS_CHANGED + 1))
      log "Custom model changed: $name:latest (${before:-new} -> ${after:-unknown})"
    else
      log "Custom model already current: $name:latest"
    fi
  done
}

detect_webui_service() {
  local candidate
  if [[ -n "$WEBUI_SERVICE" ]]; then
    systemctl cat "$WEBUI_SERVICE" >/dev/null 2>&1 && { printf '%s\n' "$WEBUI_SERVICE"; return 0; }
    return 1
  fi
  for candidate in container-open-webui.service open-webui.service; do
    systemctl cat "$candidate" >/dev/null 2>&1 && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

normalize_image_id() { printf '%s\n' "${1#sha256:}"; }

update_open_webui() {
  local service image old_id new_id active=0 restart=0
  [[ "$UPDATE_WEBUI" -eq 1 ]] || { log "Skipping Open WebUI update."; return 0; }
  command -v podman >/dev/null 2>&1 || { fail "Podman is not installed."; return 1; }
  service=$(detect_webui_service) || {
    warn "No Open WebUI service found; expected container-open-webui.service or open-webui.service."
    return 0
  }

  systemctl is-active --quiet "$service" && active=1
  if podman container exists "$WEBUI_CONTAINER" 2>/dev/null; then
    image=$(podman inspect --format '{{.Config.Image}}' "$WEBUI_CONTAINER" 2>/dev/null || true)
    old_id=$(podman inspect --format '{{.Image}}' "$WEBUI_CONTAINER" 2>/dev/null || true)
  else
    image=""; old_id=""
  fi
  old_id=$(normalize_image_id "$old_id")
  if [[ -z "$image" || "$image" == '<none>' ]]; then
    image=$(systemctl cat "$service" 2>/dev/null | \
      grep -Eo 'ghcr\.io/open-webui/open-webui:[A-Za-z0-9._-]+' | tail -n 1 || true)
  fi
  [[ -n "$image" ]] || image="$WEBUI_IMAGE"

  printf '\n'
  log "Checking Open WebUI image: $image"
  log "Open WebUI service: $service"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run: would pull $image and restart $service only if required."
    return 0
  fi

  run "Pulling the configured Open WebUI image" podman pull "$image" || {
    fail "Could not pull $image."
    return 1
  }
  new_id=$(podman image inspect --format '{{.Id}}' "$image" 2>/dev/null) || {
    fail "Could not inspect $image."
    return 1
  }
  new_id=$(normalize_image_id "$new_id")
  if [[ -z "$old_id" || "$old_id" != "$new_id" ]]; then
    WEBUI_IMAGE_CHANGED=1
    restart=1
  fi
  if [[ "$(boolean "$RESTART_WEBUI_FOR_MODELS")" -eq 1 ]] &&
     (( MODELS_CHANGED > 0 || ASSISTANTS_CHANGED > 0 )); then
    restart=1
  fi

  if [[ "$active" -eq 0 ]]; then
    run "Starting Open WebUI" systemctl start "$service" || { fail "Could not start $service."; return 1; }
    WEBUI_RESTARTED=1
  elif [[ "$restart" -eq 1 ]]; then
    run "Restarting Open WebUI" systemctl restart "$service" || { fail "Could not restart $service."; return 1; }
    WEBUI_RESTARTED=1
  else
    log "Open WebUI is current; no restart required."
  fi

  systemctl is-active --quiet "$service" || { fail "$service is not active."; return 1; }
  wait_for_url "$WEBUI_URL" 120 "Open WebUI" || {
    fail "Open WebUI did not become healthy at $WEBUI_URL."
    log "Review: journalctl -u $service -n 100 --no-pager"
    return 1
  }
}

update_ai_components() {
  [[ "$UPDATE_AI" -eq 1 ]] || { log "Skipping all local AI updates."; return 0; }
  discover_custom_models
  update_ollama_application || true
  pull_base_models || true
  rebuild_custom_models || true
  update_open_webui || true
}

check_reboot() {
  local rc=0
  [[ "$CHECK_REBOOT" -eq 1 && "$UPDATE_SYSTEM" -eq 1 ]] || return 0
  printf '\n'
  log "Checking whether a reboot is recommended"
  case "$PM_FAMILY" in
    dnf)
      if command -v needs-restarting >/dev/null 2>&1; then
        set +e; needs-restarting -r >/dev/null 2>&1; rc=$?; set -e
        case "$rc" in
          0) log "No reboot required." ;;
          1) log "Reboot recommended." ;;
          *) warn "Could not determine reboot status (status $rc)." ;;
        esac
      else
        log "Reboot detection unavailable; install needs-restarting if desired."
      fi
      ;;
    apt)
      if [[ -f /var/run/reboot-required ]]; then
        log "Reboot recommended."
        [[ -f /var/run/reboot-required.pkgs ]] && sed 's/^/  - /' /var/run/reboot-required.pkgs
      else
        log "No reboot required."
      fi
      ;;
  esac
}

summary() {
  printf '\n'
  log "Update summary"
  log "Base models checked: $MODELS_CHECKED"
  log "Base models changed: $MODELS_CHANGED"
  log "Custom models rebuilt: $ASSISTANTS_REBUILT"
  log "Custom models changed: $ASSISTANTS_CHANGED"
  log "Open WebUI image changed: $([[ "$WEBUI_IMAGE_CHANGED" -eq 1 ]] && printf yes || printf no)"
  log "Open WebUI restarted: $([[ "$WEBUI_RESTARTED" -eq 1 ]] && printf yes || printf no)"
  log "Warnings: $WARNINGS"
  log "Failures: $FAILURES"
}

parse_args "$@"
VERBOSE=$(boolean "$VERBOSE")
require_root
setup_logging
START_TIME=$(date +%s)
trap on_exit EXIT
trap 'log "Update run interrupted."; exit 130' INT TERM

acquire_lock
detect_pm
log "Starting $SCRIPT_NAME version $VERSION on $(hostname)"
log "Mode: $([[ "$DRY_RUN" -eq 1 ]] && printf dry-run || printf apply)"
log "Package manager: $PM"
log "Modelfile directory: $MODELFILE_DIR"
log "Log file: $LOG_FILE"

[[ "$VERBOSE" -eq 1 ]] && show_overview
update_system_packages || true
update_ai_components
check_reboot
summary
[[ "$FAILURES" -eq 0 ]] || exit 1
