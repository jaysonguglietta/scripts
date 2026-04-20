#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ORIGINAL_ARGS=("$@")
DRY_RUN=0
VERBOSE="${VERBOSE:-0}"
CHECK_REBOOT=1
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
  -h, --help            Show this help text.

Defaults:
  - Logs go to /var/log/system-updates when possible.
  - Logs fall back to /tmp/system-updates if needed.
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
  exec sudo --preserve-env=LOG_DIR,VERBOSE "$0" "${ORIGINAL_ARGS[@]}"
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

check_reboot_status

if [[ "$VERBOSE" -eq 1 ]]; then
  show_disk_usage "Disk usage after updates"
fi
