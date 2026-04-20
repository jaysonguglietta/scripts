#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ORIGINAL_ARGS=("$@")
DRY_RUN=0
CHECK_REBOOT=1
CUSTOM_LOG_DIR="${LOG_DIR:-}"
PACKAGE_MANAGER=""
PACKAGE_FAMILY=""
LOG_FILE=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Safely update a Fedora or Debian-family server.

Options:
  -n, --dry-run         Preview package actions without applying them.
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

update_with_dnf() {
  local -a cmd_flags=(-y)

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
  local -a simulate_flags=()

  run_cmd "Refreshing package metadata" apt-get update

  if [[ "$DRY_RUN" -eq 1 ]]; then
    simulate_flags+=(-s)
  fi

  run_cmd "Applying available updates" \
    apt-get "${simulate_flags[@]}" -y full-upgrade
  run_cmd "Removing unneeded packages" \
    apt-get "${simulate_flags[@]}" -y --purge autoremove

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

if [[ "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sudo is required when running as a non-root user."
  exec sudo --preserve-env=LOG_DIR "$0" "${ORIGINAL_ARGS[@]}"
fi

setup_logging
trap 'rc=$?; if [[ $rc -eq 0 ]]; then log "Update run finished successfully."; else log "Update run failed with exit code $rc."; fi; if [[ -n "${LOG_FILE:-}" ]]; then log "Log saved to $LOG_FILE"; fi' EXIT
trap 'log "Update run interrupted."; exit 130' INT TERM

detect_package_manager

log "Starting update run on $(hostname)"
log "Package manager: $PACKAGE_MANAGER"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Mode: dry-run"
else
  log "Mode: apply changes"
fi
log "Log file: $LOG_FILE"

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
