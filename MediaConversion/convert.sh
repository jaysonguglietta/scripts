#!/usr/bin/env bash
# Batch MKV-to-MP4 converter for Fedora/Linux media servers.

set -uo pipefail
shopt -s extglob nullglob

if (( EUID == 0 )); then
  PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
  export PATH
fi

bootstrap_path_is_trusted() {
  local path="$1" kind="$2" owner mode current_uid permissions

  if [[ "$kind" == directory ]]; then
    [[ -d "$path" && ! -L "$path" ]] || return 1
  else
    [[ -f "$path" && ! -L "$path" ]] || return 1
  fi
  owner="$(stat -c %u "$path" 2>/dev/null || stat -f %u "$path" 2>/dev/null)" || return 1
  mode="$(stat -c %a "$path" 2>/dev/null || stat -f %Lp "$path" 2>/dev/null)" || return 1
  current_uid="$(id -u)"
  [[ "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  if [[ "$owner" != "$current_uid" && "$owner" != "0" ]]; then
    return 1
  fi
  permissions=$((8#$mode))
  (( (permissions & 0022) == 0 ))
}

require_trusted_bootstrap_path() {
  local path="$1" kind="$2"
  if [[ "${MEDIA_CONVERSION_ALLOW_UNSAFE_PATHS:-0}" == "1" ]]; then
    return 0
  fi
  if ! bootstrap_path_is_trusted "$path" "$kind"; then
    printf '[ERROR] Refusing unsafe %s path: %q\n' "$kind" "$path" >&2
    printf '[ERROR] It must be a non-symlink owned by the current user or root and not group/world writable.\n' >&2
    return 1
  fi
}

require_private_file_path() {
  local path="$1" label="$2" mode permissions
  require_trusted_bootstrap_path "$path" file || return 1
  mode="$(stat -c %a "$path" 2>/dev/null || stat -f %Lp "$path" 2>/dev/null)" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  permissions=$((8#$mode))
  if (( (permissions & 0077) != 0 )); then
    printf '[ERROR] Refusing %s readable or writable by group/others: %q\n' "$label" "$path" >&2
    printf '[ERROR] Protect it with chmod 600.\n' >&2
    return 1
  fi
}

require_private_config_path() {
  require_private_file_path "$1" config
}

canonicalize_parent_path() {
  local path="$1" directory filename
  directory="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
  filename="$(basename "$path")"
  printf '%s/%s' "$directory" "$filename"
}

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
require_trusted_bootstrap_path "$SCRIPT_DIR" directory || exit 1
require_trusted_bootstrap_path "${SCRIPT_DIR}/${SCRIPT_NAME}" file || exit 1
require_trusted_bootstrap_path "${SCRIPT_DIR}/lib" directory || exit 1
for library in common metadata media; do
  library_path="${SCRIPT_DIR}/lib/${library}.sh"
  if [[ ! -r "$library_path" ]]; then
    printf '[ERROR] Required library is missing: %s\n' "$library_path" >&2
    exit 1
  fi
  require_trusted_bootstrap_path "$library_path" file || exit 1
  # shellcheck source=/dev/null
  source "$library_path"
done
unset library library_path SCRIPT_NAME

MODE=convert
TARGET_SIZE_SPEC=""
MAX_HEIGHT_CLI=""
AUDIO_MODE_CLI=""
AUDIO_STREAM_CLI=""
AUDIO_TRACK_CLI=""
FORCED_SUBTITLE_STREAM_CLI=""
QUALITY_ENCODE_CLI=""
X265_PRESET_CLI=""
JOBS_CLI=""
OMDB_REFRESH_CLI=""
STRICT_SIZE_CLI=""
STRICT_METADATA_CLI=""
EXISTING_POLICY_CLI=""
QSV_MODE_CLI=""
VALIDATION_MODE_CLI=""

CONFIG_VARIABLES=(
  FFMPEG FFPROBE JOBS VERBOSE
  OMDB_API_KEY OMDB_URL OMDB_LOG OMDB_LOG_LOCK OMDB_INTERACTIVE OMDB_REFRESH OMDB_CONNECT_TIMEOUT OMDB_MAX_TIME OMDB_RETRIES
  REPAIR_MODE SUBTITLE_MODE FAST_VIDEO_COPY KEEP_OMDB_SOURCE_SIDECAR KEEP_OMDB_OUTPUT_SIDECAR KEEP_OMDB_LOG
  MEDIA_STATE_DIR FFMPEG_LOG_LEVEL
  ALLOW_UNTAGGED_AUDIO_FALLBACK ALLOW_COMMENTARY_AUDIO_FALLBACK FORCE_SELECTED_AUDIO_AS_ENGLISH FORCE_SELECTED_SUBTITLE_AS_ENGLISH
  ALLOW_FORCED_TITLE_FALLBACK AUDIO_STREAM_INDEX AUDIO_TRACK_POSITION FORCED_SUBTITLE_STREAM FIX_TIMESTAMPS
  QSV_MODE QSV_LOW_POWER QSV_GLOBAL_QUALITY QSV_PRESET X264_CRF X264_PRESET X264_THREADS X265_CRF X265_PRESET X265_THREADS USE_VBV VBV_MAXRATE VBV_BUFSIZE AAC_STEREO_BR AC3_51_BR
  TV_MAX_BYTES MP4_TAG_HEADROOM_BYTES AUDIO_MODE QUALITY_ENCODE MAX_HEIGHT SIZE_SAFETY_PERCENT SIZE_RETRY_ATTEMPTS SIZE_TOLERANCE_PERCENT
  STRICT_SIZE_CAP STRICT_TAGGING STRICT_METADATA STRICT_DISK_CHECK OMDB_CONFIRM_CACHED OMDB_RESPONSE_MAX_BYTES
  POSTER_MAX_BYTES POSTER_ALLOWED_HOSTS DURATION_TOLERANCE_SECONDS DURATION_TOLERANCE_PERMILLE VALIDATION_MODE HDR_MODE
  EXISTING_POLICY MAX_RESERVATION_ATTEMPTS
)
LOADED_CONFIG_PATH=""

print_usage() {
  cat <<'EOF'
Usage:
  ./convert.sh [options]

Options:
  --target-size SIZE          best-effort output cap, e.g. 2GB or 700MB
  --max-height HEIGHT         downscale video to at most HEIGHT pixels
  --audio MODE                surround+stereo, surround, or stereo
  --audio-stream INDEX        use an explicit absolute audio stream index
  --track N                   use the Nth audio track (1-based among audio streams)
  --forced-subtitle-stream N  use an explicit subtitle-relative stream position
  --quality-encode            use software HEVC for tighter compression
  --x265-preset PRESET        libx265 speed/quality preset
  --jobs COUNT                maximum simultaneous conversions
  --refresh-metadata          replace cached OMDb metadata after a valid response
  --strict-metadata           require confirmed metadata and successful tagging
  --strict-size               fail files that remain over their target after retry
  --existing POLICY           unique or skip when the target MP4 already exists
  --qsv MODE                  auto, off, or force
  --validation MODE           probe or decode
  --inspect                   print stream inventories and exit
  --dry-run                   print conversion decisions without writing files
  --print-subs-only           report forced English subtitle detection and exit
  -h, --help                  show this help

Important environment settings:
  OMDB_API_KEY                required for new OMDb lookups; no key is embedded
  MEDIA_CONVERSION_CONFIG     optional env-file path to auto-load before defaults
  OMDB_INTERACTIVE=0|1        require metadata confirmation before convert (default: 1)
  REPAIR_MODE=auto|always|never
  SUBTITLE_MODE=burn|copy|extract
  FAST_VIDEO_COPY=0|1
  KEEP_OMDB_SOURCE_SIDECAR=0|1
  KEEP_OMDB_OUTPUT_SIDECAR=0|1
  KEEP_OMDB_LOG=0|1
  ALLOW_UNTAGGED_AUDIO_FALLBACK=0|1
  ALLOW_COMMENTARY_AUDIO_FALLBACK=0|1
  FORCE_SELECTED_AUDIO_AS_ENGLISH=0|1
  FORCE_SELECTED_SUBTITLE_AS_ENGLISH=0|1
  ALLOW_FORCED_TITLE_FALLBACK=0|1
  AUDIO_STREAM_INDEX=auto|INDEX
  AUDIO_TRACK_POSITION=auto|N
  FORCED_SUBTITLE_STREAM=auto|POSITION
  STRICT_TAGGING=0|1
  STRICT_METADATA=0|1
  STRICT_DISK_CHECK=0|1
  SIZE_RETRY_ATTEMPTS=1

Run from the directory containing the MKV files. See README.md for all settings.
EOF
}

trim_config_whitespace() {
  local value="${1:-}"
  value="${value##+([[:space:]])}"
  value="${value%%+([[:space:]])}"
  printf '%s' "$value"
}

config_variable_is_allowed() {
  local requested="$1" variable
  for variable in "${CONFIG_VARIABLES[@]}"; do
    [[ "$requested" == "$variable" ]] && return 0
  done
  return 1
}

parse_config_value() {
  local raw
  raw="$(trim_config_whitespace "$1")"
  if [[ "$raw" == \"* ]]; then
    [[ ${#raw} -ge 2 && "$raw" == *\" ]] || return 1
    printf '%s' "${raw:1:${#raw}-2}"
  elif [[ "$raw" == \'* ]]; then
    [[ ${#raw} -ge 2 && "$raw" == *\' ]] || return 1
    printf '%s' "${raw:1:${#raw}-2}"
  else
    printf '%s' "$raw"
  fi
}

load_config_file() {
  local config_path="$1" line stripped key raw value variable line_number=0

  if path_has_control_characters "$config_path"; then
    log_error 'Config paths cannot contain control characters.'
    return 1
  fi
  config_path="$(canonicalize_parent_path "$config_path")" || {
    log_error "Could not resolve config directory: ${config_path}"
    return 1
  }
  require_trusted_bootstrap_path "$(dirname "$config_path")" directory || return 1
  require_private_config_path "$config_path" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    stripped="$(trim_config_whitespace "$line")"
    [[ -z "$stripped" || "$stripped" == \#* ]] && continue
    [[ "$stripped" == export[[:space:]]* ]] && stripped="$(trim_config_whitespace "${stripped#export}")"
    if [[ ! "$stripped" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      log_error "Invalid config syntax at ${config_path}:${line_number}."
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    raw="${BASH_REMATCH[2]}"
    if ! config_variable_is_allowed "$key"; then
      log_error "Unsupported config variable ${key} at ${config_path}:${line_number}."
      return 1
    fi
    if [[ ${!key+x} ]]; then
      continue
    fi
    if ! value="$(parse_config_value "$raw")"; then
      log_error "Invalid quoted value for ${key} at ${config_path}:${line_number}."
      return 1
    fi
    printf -v "$key" '%s' "$value"
  done < "$config_path"

  # Settings are consumed by this shell; child media tools do not need secrets or policy values.
  for variable in "${CONFIG_VARIABLES[@]}"; do
    [[ ${!variable+x} ]] && export -n "$variable" 2>/dev/null || true
  done
  LOADED_CONFIG_PATH="$config_path"
  log_info "Loaded config: ${config_path}"
}

load_local_config() {
  local config_path
  local -a candidates=()

  if [[ -n "${MEDIA_CONVERSION_CONFIG:-}" ]]; then
    config_path="$MEDIA_CONVERSION_CONFIG"
    if [[ ! -e "$config_path" && ! -L "$config_path" ]]; then
      log_error "Configured file does not exist: ${config_path}"
      return 1
    fi
    if [[ ! -r "$config_path" ]]; then
      log_error "Config file is not readable: ${config_path}"
      return 1
    fi
    load_config_file "$config_path"
    return $?
  fi
  candidates+=("${SCRIPT_DIR}/media-conversion.local.env")
  if [[ -n "${HOME:-}" ]]; then
    candidates+=("${HOME}/.config/media-conversion.env")
  fi

  for config_path in "${candidates[@]}"; do
    [[ -n "$config_path" ]] || continue
    if [[ ! -e "$config_path" && ! -L "$config_path" ]]; then
      continue
    fi
    if [[ ! -r "$config_path" ]]; then
      log_error "Config file is not readable: ${config_path}"
      return 1
    fi
    load_config_file "$config_path"
    return 0
  done

  return 0
}

require_option_value() {
  local option="$1" value="${2:-}"
  if [[ -z "$value" ]]; then
    log_error "${option} requires a value."
    return 1
  fi
}

parse_cli() {
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print_usage
        exit 0
        ;;
      --print-subs-only)
        MODE=subs_only
        shift
        ;;
      --inspect)
        MODE=inspect
        shift
        ;;
      --dry-run)
        MODE=dry_run
        shift
        ;;
      --target-size)
        require_option_value "$1" "${2:-}" || exit 1
        TARGET_SIZE_SPEC="$2"
        shift 2
        ;;
      --target-size=*) TARGET_SIZE_SPEC="${1#*=}"; shift ;;
      --max-height)
        require_option_value "$1" "${2:-}" || exit 1
        MAX_HEIGHT_CLI="$2"
        shift 2
        ;;
      --max-height=*) MAX_HEIGHT_CLI="${1#*=}"; shift ;;
      --audio)
        require_option_value "$1" "${2:-}" || exit 1
        AUDIO_MODE_CLI="$2"
        shift 2
        ;;
      --audio=*) AUDIO_MODE_CLI="${1#*=}"; shift ;;
      --audio-stream)
        require_option_value "$1" "${2:-}" || exit 1
        AUDIO_STREAM_CLI="$2"
        shift 2
        ;;
      --audio-stream=*) AUDIO_STREAM_CLI="${1#*=}"; shift ;;
      --track|--Track)
        require_option_value "$1" "${2:-}" || exit 1
        AUDIO_TRACK_CLI="$2"
        shift 2
        ;;
      --track=*|--Track=*) AUDIO_TRACK_CLI="${1#*=}"; shift ;;
      --forced-subtitle-stream)
        require_option_value "$1" "${2:-}" || exit 1
        FORCED_SUBTITLE_STREAM_CLI="$2"
        shift 2
        ;;
      --forced-subtitle-stream=*) FORCED_SUBTITLE_STREAM_CLI="${1#*=}"; shift ;;
      --quality-encode) QUALITY_ENCODE_CLI=1; shift ;;
      --x265-preset)
        require_option_value "$1" "${2:-}" || exit 1
        X265_PRESET_CLI="$2"
        shift 2
        ;;
      --x265-preset=*) X265_PRESET_CLI="${1#*=}"; shift ;;
      --jobs)
        require_option_value "$1" "${2:-}" || exit 1
        JOBS_CLI="$2"
        shift 2
        ;;
      --jobs=*) JOBS_CLI="${1#*=}"; shift ;;
      --refresh-metadata) OMDB_REFRESH_CLI=1; shift ;;
      --strict-metadata) STRICT_METADATA_CLI=1; shift ;;
      --strict-size) STRICT_SIZE_CLI=1; shift ;;
      --existing)
        require_option_value "$1" "${2:-}" || exit 1
        EXISTING_POLICY_CLI="$2"
        shift 2
        ;;
      --existing=*) EXISTING_POLICY_CLI="${1#*=}"; shift ;;
      --qsv)
        require_option_value "$1" "${2:-}" || exit 1
        QSV_MODE_CLI="$2"
        shift 2
        ;;
      --qsv=*) QSV_MODE_CLI="${1#*=}"; shift ;;
      --validation)
        require_option_value "$1" "${2:-}" || exit 1
        VALIDATION_MODE_CLI="$2"
        shift 2
        ;;
      --validation=*) VALIDATION_MODE_CLI="${1#*=}"; shift ;;
      *) log_error "Unknown option: $1"; print_usage >&2; exit 1 ;;
    esac
  done
}

load_defaults() {
  FFMPEG="${FFMPEG:-}"
  FFPROBE="${FFPROBE:-}"
  JOBS="${JOBS:-1}"
  VERBOSE="${VERBOSE:-0}"

  OMDB_API_KEY="${OMDB_API_KEY:-}"
  OMDB_URL="${OMDB_URL:-https://www.omdbapi.com}"
  if [[ -z "${MEDIA_STATE_DIR:-}" ]]; then
    if [[ -n "${XDG_STATE_HOME:-}" ]]; then
      MEDIA_STATE_DIR="${XDG_STATE_HOME}/media-conversion"
    elif [[ -n "${HOME:-}" ]]; then
      MEDIA_STATE_DIR="${HOME}/.local/state/media-conversion"
    else
      MEDIA_STATE_DIR="${TMPDIR:-/tmp}/media-conversion-$(id -u)"
    fi
  fi
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  OMDB_LOG="${OMDB_LOG:-}"
  OMDB_LOG_LOCK="${OMDB_LOG_LOCK:-}"
  OMDB_LOG_IS_PER_RUN=0
  OMDB_INTERACTIVE="${OMDB_INTERACTIVE:-1}"
  OMDB_REFRESH="${OMDB_REFRESH:-0}"
  OMDB_CONFIRM_CACHED="${OMDB_CONFIRM_CACHED:-1}"
  OMDB_CONNECT_TIMEOUT="${OMDB_CONNECT_TIMEOUT:-5}"
  OMDB_MAX_TIME="${OMDB_MAX_TIME:-20}"
  OMDB_RETRIES="${OMDB_RETRIES:-2}"
  OMDB_RESPONSE_MAX_BYTES="${OMDB_RESPONSE_MAX_BYTES:-1048576}"
  POSTER_MAX_BYTES="${POSTER_MAX_BYTES:-10485760}"
  POSTER_ALLOWED_HOSTS="${POSTER_ALLOWED_HOSTS:-m.media-amazon.com,media-amazon.com,ia.media-imdb.com,media-imdb.com}"
  OMDB_ENABLED=0

  REPAIR_MODE="${REPAIR_MODE:-auto}"
  SUBTITLE_MODE="${SUBTITLE_MODE:-burn}"
  FAST_VIDEO_COPY="${FAST_VIDEO_COPY:-1}"
  KEEP_OMDB_SOURCE_SIDECAR="${KEEP_OMDB_SOURCE_SIDECAR:-0}"
  KEEP_OMDB_OUTPUT_SIDECAR="${KEEP_OMDB_OUTPUT_SIDECAR:-0}"
  KEEP_OMDB_LOG="${KEEP_OMDB_LOG:-0}"
  ALLOW_UNTAGGED_AUDIO_FALLBACK="${ALLOW_UNTAGGED_AUDIO_FALLBACK:-1}"
  ALLOW_COMMENTARY_AUDIO_FALLBACK="${ALLOW_COMMENTARY_AUDIO_FALLBACK:-0}"
  FORCE_SELECTED_AUDIO_AS_ENGLISH="${FORCE_SELECTED_AUDIO_AS_ENGLISH:-0}"
  FORCE_SELECTED_SUBTITLE_AS_ENGLISH="${FORCE_SELECTED_SUBTITLE_AS_ENGLISH:-0}"
  ALLOW_FORCED_TITLE_FALLBACK="${ALLOW_FORCED_TITLE_FALLBACK:-1}"
  AUDIO_STREAM_INDEX="${AUDIO_STREAM_INDEX:-auto}"
  AUDIO_TRACK_POSITION="${AUDIO_TRACK_POSITION:-auto}"
  FORCED_SUBTITLE_STREAM="${FORCED_SUBTITLE_STREAM:-auto}"
  FIX_TIMESTAMPS="${FIX_TIMESTAMPS:-1}"

  QSV_MODE="${QSV_MODE:-auto}"
  QSV_AVAILABLE=0
  QSV_LOW_POWER="${QSV_LOW_POWER:-0}"
  QSV_GLOBAL_QUALITY="${QSV_GLOBAL_QUALITY:-22}"
  QSV_PRESET="${QSV_PRESET:-medium}"
  X264_CRF="${X264_CRF:-20}"
  X264_PRESET="${X264_PRESET:-veryfast}"
  X264_THREADS="${X264_THREADS:-0}"
  X265_CRF="${X265_CRF:-23}"
  X265_PRESET="${X265_PRESET:-medium}"
  X265_THREADS="${X265_THREADS:-0}"
  USE_VBV="${USE_VBV:-1}"
  VBV_MAXRATE="${VBV_MAXRATE:-25000}"
  VBV_BUFSIZE="${VBV_BUFSIZE:-30000}"
  AAC_STEREO_BR="${AAC_STEREO_BR:-192k}"
  AC3_51_BR="${AC3_51_BR:-640k}"

  TV_MAX_BYTES="${TV_MAX_BYTES:-1073741824}"
  MP4_TAG_HEADROOM_BYTES="${MP4_TAG_HEADROOM_BYTES:-16777216}"
  AUDIO_MODE="${AUDIO_MODE:-surround+stereo}"
  QUALITY_ENCODE="${QUALITY_ENCODE:-0}"
  MAX_HEIGHT="${MAX_HEIGHT:-0}"
  TARGET_SIZE_BYTES=""
  SIZE_SAFETY_PERCENT="${SIZE_SAFETY_PERCENT:-97}"
  SIZE_RETRY_ATTEMPTS="${SIZE_RETRY_ATTEMPTS:-1}"
  SIZE_TOLERANCE_PERCENT="${SIZE_TOLERANCE_PERCENT:-2}"
  STRICT_SIZE_CAP="${STRICT_SIZE_CAP:-0}"
  STRICT_TAGGING="${STRICT_TAGGING:-0}"
  STRICT_METADATA="${STRICT_METADATA:-0}"
  STRICT_DISK_CHECK="${STRICT_DISK_CHECK:-0}"
  DURATION_TOLERANCE_SECONDS="${DURATION_TOLERANCE_SECONDS:-5}"
  DURATION_TOLERANCE_PERMILLE="${DURATION_TOLERANCE_PERMILLE:-1}"
  VALIDATION_MODE="${VALIDATION_MODE:-probe}"
  HDR_MODE="${HDR_MODE:-preserve}"
  EXISTING_POLICY="${EXISTING_POLICY:-unique}"
  MAX_RESERVATION_ATTEMPTS="${MAX_RESERVATION_ATTEMPTS:-10000}"
  FFMPEG_LOG_LEVEL="${FFMPEG_LOG_LEVEL:-warning}"

  [[ -n "$MAX_HEIGHT_CLI" ]] && MAX_HEIGHT="$MAX_HEIGHT_CLI"
  [[ -n "$AUDIO_MODE_CLI" ]] && AUDIO_MODE="$AUDIO_MODE_CLI"
  [[ -n "$AUDIO_STREAM_CLI" ]] && AUDIO_STREAM_INDEX="$AUDIO_STREAM_CLI"
  [[ -n "$AUDIO_TRACK_CLI" ]] && AUDIO_TRACK_POSITION="$AUDIO_TRACK_CLI"
  [[ -n "$FORCED_SUBTITLE_STREAM_CLI" ]] && FORCED_SUBTITLE_STREAM="$FORCED_SUBTITLE_STREAM_CLI"
  [[ -n "$QUALITY_ENCODE_CLI" ]] && QUALITY_ENCODE="$QUALITY_ENCODE_CLI"
  [[ -n "$X265_PRESET_CLI" ]] && X265_PRESET="$X265_PRESET_CLI"
  [[ -n "$JOBS_CLI" ]] && JOBS="$JOBS_CLI"
  [[ -n "$OMDB_REFRESH_CLI" ]] && OMDB_REFRESH="$OMDB_REFRESH_CLI"
  [[ -n "$STRICT_METADATA_CLI" ]] && STRICT_METADATA="$STRICT_METADATA_CLI"
  [[ -n "$STRICT_SIZE_CLI" ]] && STRICT_SIZE_CAP="$STRICT_SIZE_CLI"
  [[ -n "$EXISTING_POLICY_CLI" ]] && EXISTING_POLICY="$EXISTING_POLICY_CLI"
  [[ -n "$QSV_MODE_CLI" ]] && QSV_MODE="$QSV_MODE_CLI"
  [[ -n "$VALIDATION_MODE_CLI" ]] && VALIDATION_MODE="$VALIDATION_MODE_CLI"
}

deexport_config_variables() {
  local variable
  for variable in "${CONFIG_VARIABLES[@]}"; do
    [[ ${!variable+x} ]] && export -n "$variable" 2>/dev/null || true
  done
}

validate_stream_override() {
  local name="$1" value="$2"
  if [[ "$value" != auto && ! "$value" =~ ^[0-9]+$ ]]; then
    log_error "${name} must be auto or a non-negative integer, got: ${value}"
    return 1
  fi
}

validate_track_override() {
  local name="$1" value="$2"
  if [[ "$value" != auto && ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    log_error "${name} must be auto or a positive integer, got: ${value}"
    return 1
  fi
}

validate_config() {
  local setting
  validate_positive_integer JOBS "$JOBS" || return 1
  for setting in VERBOSE OMDB_INTERACTIVE OMDB_REFRESH FAST_VIDEO_COPY \
    KEEP_OMDB_SOURCE_SIDECAR KEEP_OMDB_OUTPUT_SIDECAR KEEP_OMDB_LOG \
    ALLOW_UNTAGGED_AUDIO_FALLBACK ALLOW_COMMENTARY_AUDIO_FALLBACK FORCE_SELECTED_AUDIO_AS_ENGLISH FORCE_SELECTED_SUBTITLE_AS_ENGLISH \
    ALLOW_FORCED_TITLE_FALLBACK FIX_TIMESTAMPS QUALITY_ENCODE USE_VBV QSV_LOW_POWER STRICT_SIZE_CAP \
    STRICT_TAGGING STRICT_METADATA STRICT_DISK_CHECK OMDB_CONFIRM_CACHED; do
    validate_bool "$setting" "${!setting}" || return 1
  done

  validate_nonnegative_integer MAX_HEIGHT "$MAX_HEIGHT" || return 1
  validate_nonnegative_integer X264_THREADS "$X264_THREADS" || return 1
  validate_nonnegative_integer X265_THREADS "$X265_THREADS" || return 1
  validate_nonnegative_integer OMDB_RETRIES "$OMDB_RETRIES" || return 1
  validate_positive_integer OMDB_CONNECT_TIMEOUT "$OMDB_CONNECT_TIMEOUT" || return 1
  validate_positive_integer OMDB_MAX_TIME "$OMDB_MAX_TIME" || return 1
  validate_positive_integer OMDB_RESPONSE_MAX_BYTES "$OMDB_RESPONSE_MAX_BYTES" || return 1
  validate_positive_integer POSTER_MAX_BYTES "$POSTER_MAX_BYTES" || return 1
  validate_positive_integer TV_MAX_BYTES "$TV_MAX_BYTES" || return 1
  validate_nonnegative_integer MP4_TAG_HEADROOM_BYTES "$MP4_TAG_HEADROOM_BYTES" || return 1
  validate_positive_integer SIZE_SAFETY_PERCENT "$SIZE_SAFETY_PERCENT" || return 1
  validate_nonnegative_integer SIZE_RETRY_ATTEMPTS "$SIZE_RETRY_ATTEMPTS" || return 1
  validate_nonnegative_integer SIZE_TOLERANCE_PERCENT "$SIZE_TOLERANCE_PERCENT" || return 1
  validate_nonnegative_integer DURATION_TOLERANCE_SECONDS "$DURATION_TOLERANCE_SECONDS" || return 1
  validate_nonnegative_integer DURATION_TOLERANCE_PERMILLE "$DURATION_TOLERANCE_PERMILLE" || return 1
  validate_positive_integer MAX_RESERVATION_ATTEMPTS "$MAX_RESERVATION_ATTEMPTS" || return 1
  validate_crf X264_CRF "$X264_CRF" || return 1
  validate_crf X265_CRF "$X265_CRF" || return 1
  validate_crf QSV_GLOBAL_QUALITY "$QSV_GLOBAL_QUALITY" || return 1
  validate_positive_integer VBV_MAXRATE "$VBV_MAXRATE" || return 1
  validate_positive_integer VBV_BUFSIZE "$VBV_BUFSIZE" || return 1
  validate_kilobit_rate AAC_STEREO_BR "$AAC_STEREO_BR" || return 1
  validate_kilobit_rate AC3_51_BR "$AC3_51_BR" || return 1
  validate_stream_override AUDIO_STREAM_INDEX "$AUDIO_STREAM_INDEX" || return 1
  validate_track_override AUDIO_TRACK_POSITION "$AUDIO_TRACK_POSITION" || return 1
  validate_stream_override FORCED_SUBTITLE_STREAM "$FORCED_SUBTITLE_STREAM" || return 1

  case "$REPAIR_MODE" in auto|always|never) ;; *) log_error "Invalid REPAIR_MODE: ${REPAIR_MODE}"; return 1 ;; esac
  case "$SUBTITLE_MODE" in burn|copy|extract) ;; *) log_error "Invalid SUBTITLE_MODE: ${SUBTITLE_MODE}"; return 1 ;; esac
  case "$AUDIO_MODE" in surround+stereo|surround|stereo) ;; *) log_error "Invalid AUDIO_MODE: ${AUDIO_MODE}"; return 1 ;; esac
  case "$QSV_MODE" in auto|off|force) ;; *) log_error "Invalid QSV_MODE: ${QSV_MODE}"; return 1 ;; esac
  case "$VALIDATION_MODE" in probe|decode) ;; *) log_error "Invalid VALIDATION_MODE: ${VALIDATION_MODE}"; return 1 ;; esac
  case "$HDR_MODE" in preserve|reject) ;; *) log_error "Invalid HDR_MODE: ${HDR_MODE}"; return 1 ;; esac
  case "$EXISTING_POLICY" in unique|skip) ;; *) log_error "Invalid EXISTING_POLICY: ${EXISTING_POLICY}"; return 1 ;; esac
  case "$FFMPEG_LOG_LEVEL" in quiet|panic|fatal|error|warning|info|verbose|debug|trace) ;;
    *) log_error "Invalid FFMPEG_LOG_LEVEL: ${FFMPEG_LOG_LEVEL}"; return 1 ;;
  esac
  case "$X264_PRESET" in ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow|placebo) ;;
    *) log_error "Invalid X264_PRESET: ${X264_PRESET}"; return 1 ;;
  esac
  case "$X265_PRESET" in ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow|placebo) ;;
    *) log_error "Invalid X265_PRESET: ${X265_PRESET}"; return 1 ;;
  esac
  case "$QSV_PRESET" in veryfast|faster|fast|medium|slow|slower|veryslow) ;;
    *) log_error "Invalid QSV_PRESET: ${QSV_PRESET}"; return 1 ;;
  esac
  if (( SIZE_SAFETY_PERCENT < 50 || SIZE_SAFETY_PERCENT > 100 )); then
    log_error 'SIZE_SAFETY_PERCENT must be between 50 and 100.'
    return 1
  fi
  if (( DURATION_TOLERANCE_SECONDS == 0 && DURATION_TOLERANCE_PERMILLE == 0 )); then
    log_error 'At least one duration tolerance must be greater than zero.'
    return 1
  fi
  if [[ "$AUDIO_STREAM_INDEX" != auto && "$AUDIO_TRACK_POSITION" != auto ]]; then
    log_error 'Set only one of AUDIO_STREAM_INDEX or AUDIO_TRACK_POSITION.'
    return 1
  fi
  if [[ ! "$POSTER_ALLOWED_HOSTS" =~ ^[A-Za-z0-9.,-]+$ ]]; then
    log_error 'POSTER_ALLOWED_HOSTS must be a comma-separated list of DNS names.'
    return 1
  fi
  if [[ "$MEDIA_STATE_DIR" != /* ]]; then
    log_error 'MEDIA_STATE_DIR must be an absolute path.'
    return 1
  fi

  if [[ -n "$TARGET_SIZE_SPEC" ]]; then
    TARGET_SIZE_BYTES="$(parse_size_to_bytes "$TARGET_SIZE_SPEC")" || {
      log_error "Invalid --target-size: ${TARGET_SIZE_SPEC}"
      return 1
    }
  fi
  if [[ -n "$TARGET_SIZE_BYTES" ]] && (( TARGET_SIZE_BYTES <= MP4_TAG_HEADROOM_BYTES )); then
    log_error 'Target size must be larger than MP4_TAG_HEADROOM_BYTES.'
    return 1
  fi
  if (( TV_MAX_BYTES <= MP4_TAG_HEADROOM_BYTES )); then
    log_error 'TV_MAX_BYTES must be larger than MP4_TAG_HEADROOM_BYTES.'
    return 1
  fi
  if [[ -n "$OMDB_API_KEY" && "$OMDB_URL" != https://* ]]; then
    log_error 'OMDB_URL must use HTTPS when an API key is configured.'
    return 1
  fi
  if [[ "$STRICT_METADATA" == "1" ]]; then
    STRICT_TAGGING=1
  fi
}

initialize_state_directory() {
  local old_umask artifact parent
  if path_has_control_characters "$MEDIA_STATE_DIR"; then
    log_error 'MEDIA_STATE_DIR cannot contain control characters.'
    return 1
  fi
  old_umask="$(umask)"
  umask 077
  if ! mkdir -p -- "$MEDIA_STATE_DIR"; then
    umask "$old_umask"
    log_error "Could not create private state directory: ${MEDIA_STATE_DIR}"
    return 1
  fi
  if [[ -L "$MEDIA_STATE_DIR" ]]; then
    umask "$old_umask"
    log_error 'MEDIA_STATE_DIR cannot be a symlink.'
    return 1
  fi
  MEDIA_STATE_DIR="$(cd "$MEDIA_STATE_DIR" 2>/dev/null && pwd -P)" || {
    umask "$old_umask"
    log_error 'Could not resolve MEDIA_STATE_DIR.'
    return 1
  }
  chmod 700 "$MEDIA_STATE_DIR" 2>/dev/null || true
  umask "$old_umask"
  require_trusted_bootstrap_path "$MEDIA_STATE_DIR" directory || return 1
  [[ -w "$MEDIA_STATE_DIR" ]] || { log_error "State directory is not writable: ${MEDIA_STATE_DIR}"; return 1; }

  if [[ -z "$OMDB_LOG" ]]; then
    OMDB_LOG="${MEDIA_STATE_DIR}/omdb-tagging-${RUN_ID}.csv"
    OMDB_LOG_IS_PER_RUN=1
  elif [[ "$OMDB_LOG" != /* ]]; then
    OMDB_LOG="${MEDIA_STATE_DIR}/${OMDB_LOG}"
  fi
  if [[ -z "$OMDB_LOG_LOCK" ]]; then
    OMDB_LOG_LOCK="${OMDB_LOG}.lock"
  elif [[ "$OMDB_LOG_LOCK" != /* ]]; then
    OMDB_LOG_LOCK="${MEDIA_STATE_DIR}/${OMDB_LOG_LOCK}"
  fi
  if [[ "$OMDB_LOG" == "$OMDB_LOG_LOCK" ]]; then
    log_error 'OMDB_LOG and OMDB_LOG_LOCK must use different paths.'
    return 1
  fi
  OMDB_LOG="$(canonicalize_parent_path "$OMDB_LOG")" || { log_error 'Could not resolve OMDb log directory.'; return 1; }
  OMDB_LOG_LOCK="$(canonicalize_parent_path "$OMDB_LOG_LOCK")" || { log_error 'Could not resolve OMDb lock directory.'; return 1; }
  for artifact in "$OMDB_LOG" "$OMDB_LOG_LOCK"; do
    if path_has_control_characters "$artifact"; then
      log_error 'OMDb log and lock paths cannot contain control characters.'
      return 1
    fi
    parent="$(dirname "$artifact")"
    require_trusted_bootstrap_path "$parent" directory || return 1
    [[ -w "$parent" ]] || { log_error "OMDb log directory is not writable: ${parent}"; return 1; }
    if [[ -e "$artifact" || -L "$artifact" ]]; then
      require_private_file_path "$artifact" 'OMDb log/lock' || return 1
    fi
  done
}

probe_qsv_encoder() {
  case "$QSV_MODE" in
    off) QSV_AVAILABLE=0; return 0 ;;
    force) QSV_AVAILABLE=1; return 0 ;;
  esac
  if "$FFMPEG" -hide_banner -loglevel error -nostdin -f lavfi -i color=c=black:s=128x72:r=1 \
      -frames:v 1 -vf format=nv12 -c:v hevc_qsv -low_power "$QSV_LOW_POWER" -f null - </dev/null >/dev/null 2>&1; then
    QSV_AVAILABLE=1
    log_info 'Intel QSV HEVC preflight succeeded.'
  else
    QSV_AVAILABLE=0
    log_warn 'Intel QSV HEVC preflight failed; software encoding will be used.'
  fi
}

initialize_runtime() {
  resolve_required_tool FFMPEG ffmpeg-git ffmpeg || return 1
  resolve_required_tool FFPROBE ffprobe-git ffprobe || return 1

  if [[ -n "$OMDB_API_KEY" ]]; then
    if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      OMDB_ENABLED=1
    else
      log_warn 'OMDB_API_KEY is set, but curl or jq is unavailable; new metadata lookups are disabled.'
    fi
  else
    log_warn 'OMDB_API_KEY is not set; existing sidecars will be reused, but no new metadata will be fetched.'
  fi

  if [[ "$MODE" == convert || "$MODE" == dry_run ]]; then
    probe_qsv_encoder
  fi

  TIMING_IN_FLAGS=()
  TIMING_OUT_FLAGS=()
  if [[ "$FIX_TIMESTAMPS" == "1" ]]; then
    # shellcheck disable=SC2034 # Read by lib/media.sh after this module is sourced.
    TIMING_IN_FLAGS=(-fflags +genpts)
    # shellcheck disable=SC2034 # Read by lib/media.sh after this module is sourced.
    TIMING_OUT_FLAGS=(-avoid_negative_ts make_zero -fps_mode vfr)
  fi

  MP4_OUTPUT_FLAGS=()
  if (( MP4_TAG_HEADROOM_BYTES > 0 )); then
    MP4_OUTPUT_FLAGS=(-moov_size "$MP4_TAG_HEADROOM_BYTES")
  else
    # shellcheck disable=SC2034 # Read by the media and metadata modules.
    MP4_OUTPUT_FLAGS=(-movflags +faststart)
  fi
  FFMPEG_PROGRESS_FLAGS=(-hide_banner -loglevel "$FFMPEG_LOG_LEVEL" -stats -nostdin)
}

discover_input_files() {
  FILES=()
  local candidate base
  local -a candidates=(./*.mkv ./*.MKV)
  for candidate in "${candidates[@]}"; do
    base="$(basename "$candidate")"
    if [[ -L "$candidate" || ! -f "$candidate" || ! -r "$candidate" ]]; then
      log_warn "Ignoring non-regular, symlinked, or unreadable input: ${candidate}"
      continue
    fi
    if path_has_control_characters "$candidate"; then
      log_warn "Ignoring an input whose name contains terminal control characters: ${candidate}"
      continue
    fi
    case "$base" in
      *.repaired.mkv|*.repaired.MKV|*.part.mkv|*.part.MKV)
        log_warn "Ignoring temporary-looking input: ${candidate}"
        ;;
      *) FILES+=("$candidate") ;;
    esac
  done
}

estimate_required_disk_bytes() {
  local file source_size output_size estimate detected_type size_cap repair_size tag_copies
  local -a estimates=() sorted=()
  for file in "${FILES[@]}"; do
    source_size="$(file_size_bytes "$file" 2>/dev/null || printf 0)"
    detected_type="$(determine_media_type "$file")"
    size_cap="$(target_max_bytes_for_type "$detected_type")"
    if [[ -n "$size_cap" ]]; then
      output_size="$size_cap"
    else
      output_size=$((source_size + MP4_TAG_HEADROOM_BYTES))
    fi

    repair_size=0
    [[ "$REPAIR_MODE" != "never" ]] && repair_size="$source_size"
    tag_copies=1
    if [[ "$OMDB_ENABLED" == "1" ]] || json_is_confirmed_match "${file%.*}.omdb.json"; then
      # Final file + staged source + FFmpeg-tagged temporary can coexist.
      tag_copies=3
    fi
    estimate=$((repair_size + (output_size * tag_copies)))
    estimates+=("$estimate")
  done
  while IFS= read -r estimate; do
    [[ -n "$estimate" ]] && sorted+=("$estimate")
  done < <(printf '%s\n' "${estimates[@]}" | sort -nr)

  local total=0 index limit="$JOBS"
  (( limit > ${#sorted[@]} )) && limit=${#sorted[@]}
  for ((index=0; index<limit; index++)); do
    total=$((total + sorted[index]))
  done
  printf '%s' "$total"
}

print_banner() {
  printf '%s\n' '========================================' >&2
  printf 'convert.sh - transactional MKV to MP4 converter\n' >&2
  printf 'Found %s MKV file(s) in %s\n' "${#FILES[@]}" "$(pwd)" >&2
  printf 'Workers=%s repair=%s subtitles=%s fast-copy=%s\n' "$JOBS" "$REPAIR_MODE" "$SUBTITLE_MODE" "$FAST_VIDEO_COPY" >&2
  printf 'Audio=%s quality-encode=%s max-height=%s\n' "$AUDIO_MODE" "$QUALITY_ENCODE" "$MAX_HEIGHT" >&2
  printf 'OMDb enabled=%s interactive=%s refresh=%s\n' "$OMDB_ENABLED" "$OMDB_INTERACTIVE" "$OMDB_REFRESH" >&2
  printf 'QSV=%s available=%s validation=%s HDR=%s existing=%s\n' \
    "$QSV_MODE" "$QSV_AVAILABLE" "$VALIDATION_MODE" "$HDR_MODE" "$EXISTING_POLICY" >&2
  [[ -n "$LOADED_CONFIG_PATH" ]] && printf 'Config=%s\n' "$(safe_log_text "$LOADED_CONFIG_PATH")" >&2
  printf 'Metadata cleanup source-sidecar=%s output-sidecar=%s log=%s\n' \
    "$KEEP_OMDB_SOURCE_SIDECAR" "$KEEP_OMDB_OUTPUT_SIDECAR" "$KEEP_OMDB_LOG" >&2
  [[ -n "$TARGET_SIZE_BYTES" ]] && printf 'Target size=%s bytes\n' "$TARGET_SIZE_BYTES" >&2
  printf 'TV target=%s bytes metadata headroom=%s bytes\n' "$TV_MAX_BYTES" "$MP4_TAG_HEADROOM_BYTES" >&2
  [[ "$MODE" == convert ]] && printf 'Private state=%s\n' "$(safe_log_text "$MEDIA_STATE_DIR")" >&2
  printf '%s\n' '========================================' >&2
}

print_stream_inventory() {
  local file="$1" line
  printf '\n== %s ==\n' "$(safe_log_text "$(basename "$file")")"
  "$FFPROBE" -v error -show_entries \
    stream=index,codec_type,codec_name,width,height,pix_fmt,color_transfer,channels:stream_disposition=default,forced,comment,hearing_impaired,visual_impaired:stream_tags=language,title \
    -of compact=p=0:nk=0 "$file" |
    while IFS= read -r line || [[ -n "$line" ]]; do
      printf '%s\n' "$(safe_log_text "$line")"
    done
}

print_conversion_plan() {
  local file="$1" output audio_selection audio_index audio_kind audio_language audio_details
  local forced_position subtitle_codec video_codec pixel_format hdr=no qsv_decision
  output="$(suggest_output_path "$file")"
  if ! audio_selection="$(pick_audio_stream_index "$file")"; then
    log_error "No eligible audio stream for dry run: ${file}"
    return 1
  fi
  IFS='|' read -r audio_index audio_kind <<< "$audio_selection"
  audio_language="$(get_audio_stream_language "$file" "$audio_index" || true)"
  audio_details="$(get_audio_codec_and_channels "$file" "$audio_index" || true)"
  if ! forced_position="$(pick_forced_eng_sub_pos "$file")"; then
    return 1
  fi
  subtitle_codec="$(get_subtitle_codec_by_pos "$file" "$forced_position" 2>/dev/null || true)"
  video_codec="$(get_video_codec_name "$file" || true)"
  pixel_format="$(get_video_pixel_format "$file" || true)"
  source_is_hdr "$file" && hdr=yes
  if qsv_decision="$(qsv_skip_reason "$file")"; then
    :
  else
    qsv_decision='Intel QSV eligible'
  fi
  printf '\n[PLAN ] %s\n' "$(safe_log_text "$file")"
  printf '        output=%s\n' "$(safe_log_text "$output")"
  printf '        video=%s pixel-format=%s hdr=%s encoder=%s\n' \
    "${video_codec:-unknown}" "${pixel_format:-unknown}" "$hdr" "$(safe_log_text "$qsv_decision")"
  printf '        audio-stream=0:%s selection=%s details=%s language=%s\n' \
    "$audio_index" "$audio_kind" "${audio_details:-unknown}" "${audio_language:-untagged}"
  printf '        forced-subtitle=%s codec=%s mode=%s\n' \
    "${forced_position:-none}" "${subtitle_codec:-none}" "$SUBTITLE_MODE"
}

move_extracted_subtitle() {
  local staged="$1" output="$2" extension target
  [[ -n "$staged" && -f "$staged" ]] || return 0
  extension="${staged##*.}"
  target="${output%.*}.en.forced.${extension}"
  [[ -e "$target" ]] && target="$(unique_path "$target")"
  move_file_no_clobber "$staged" "$target" || return 1
  log_info "Subtitle sidecar: $(basename "$target")"
  printf '%s' "$target"
}

size_is_over_tolerance() {
  local actual="$1" target="$2"
  (( actual * 100 > target * (100 + SIZE_TOLERANCE_PERCENT) ))
}

process_one() (
  local input="$1" output="$2"
  local work_directory="" partial="" repaired="" source="$input" convert_status=0
  local used_repaired=0 detected_type actual_size retry=0 retry_bitrate=""
  local metadata_tagged=0 metadata_confirmed=0 sidecar_copy_failed=0 published_subtitle=""
  WORKER_DIRECTORY=""

  # shellcheck disable=SC2317,SC2329 # Invoked indirectly by the EXIT trap.
  cleanup_worker() {
    [[ -n "${WORKER_DIRECTORY:-}" ]] && cleanup_worker_directory "$WORKER_DIRECTORY"
  }
  trap cleanup_worker EXIT
  trap 'exit 130' INT TERM

  work_directory="$(make_worker_directory "$output")" || {
    log_error "Could not create a worker directory for ${output}."
    return 1
  }
  WORKER_DIRECTORY="$work_directory"
  partial="${work_directory}/output.part.mp4"
  repaired="${work_directory}/repaired.mkv"

  [[ "$VERBOSE" == "1" ]] && set -x
  printf '[START] %s\n' "$(safe_log_text "$input")" >&2
  print_forced_sub_status "$input"
  detected_type="$(determine_media_type "$input")"

  case "$REPAIR_MODE" in
    always)
      if ! repair_mkv "$input" "$repaired" "${work_directory}/repair.log"; then
        log_error "Repair failed: ${input}"
        print_sanitized_file_excerpt "${work_directory}/repair.log" 120 || true
        return 1
      fi
      source="$repaired"
      used_repaired=1
      convert_from_source "$source" "$partial" "$detected_type" "$input" "$work_directory"
      convert_status=$?
      ;;
    auto)
      convert_from_source "$source" "$partial" "$detected_type" "$input" "$work_directory"
      convert_status=$?
      if [[ "$convert_status" -eq 10 || "$convert_status" -eq 11 ]]; then
        log_warn "Retrying $(basename "$input") through an isolated MKV repair."
        if repair_mkv "$input" "$repaired" "${work_directory}/repair.log"; then
          source="$repaired"
          used_repaired=1
          convert_from_source "$source" "$partial" "$detected_type" "$input" "$work_directory"
          convert_status=$?
        else
          log_error "Repair failed: ${input}"
          print_sanitized_file_excerpt "${work_directory}/repair.log" 120 || true
        fi
      fi
      ;;
    never)
      convert_from_source "$source" "$partial" "$detected_type" "$input" "$work_directory"
      convert_status=$?
      ;;
  esac

  if [[ "$convert_status" -ne 0 ]]; then
    log_error "Conversion failed: ${input}"
    return 1
  fi
  validate_media_output "$partial" "$input" probe || return 1

  if [[ "$LAST_USED_FAST_COPY" == "1" && -n "$LAST_SIZE_CAP_BYTES" ]]; then
    actual_size="$(file_size_bytes "$partial" 2>/dev/null || printf 0)"
    if size_is_over_tolerance "$actual_size" "$LAST_SIZE_CAP_BYTES"; then
      log_warn 'Fast-copy output exceeded its target; retrying with video encoding.'
      rm -f -- "$partial" "${work_directory}"/forced-subtitle.*
      convert_from_source "$source" "$partial" "$detected_type" "$input" "$work_directory" '' 1
      convert_status=$?
      [[ "$convert_status" -eq 0 ]] || return 1
    fi
  fi

  while [[ -n "$LAST_SIZE_CAP_BYTES" && -n "$LAST_VIDEO_BITRATE_KBPS" && "$retry" -lt "$SIZE_RETRY_ATTEMPTS" ]]; do
    actual_size="$(file_size_bytes "$partial" 2>/dev/null || printf 0)"
    size_is_over_tolerance "$actual_size" "$LAST_SIZE_CAP_BYTES" || break
    retry_bitrate="$(calculate_retry_bitrate "$LAST_VIDEO_BITRATE_KBPS" "$LAST_SIZE_CAP_BYTES" "$actual_size")"
    retry=$((retry + 1))
    log_warn "Output exceeded target; retry ${retry}/${SIZE_RETRY_ATTEMPTS} at ${retry_bitrate}k."
    rm -f -- "$partial" "${work_directory}"/forced-subtitle.*
    convert_from_source "$source" "$partial" "$detected_type" "$input" "$work_directory" "$retry_bitrate"
    convert_status=$?
    [[ "$convert_status" -eq 0 ]] || return 1
  done

  if [[ -n "$LAST_SIZE_CAP_BYTES" ]]; then
    actual_size="$(file_size_bytes "$partial" 2>/dev/null || printf 0)"
    if size_is_over_tolerance "$actual_size" "$LAST_SIZE_CAP_BYTES"; then
      log_warn "Output remains over target: actual=${actual_size} target=${LAST_SIZE_CAP_BYTES}."
      [[ "$STRICT_SIZE_CAP" == "1" ]] && return 1
    fi
  fi

  local input_sidecar="${input%.*}.omdb.json"
  validate_media_output "$partial" "$input" probe || return 1
  if json_is_confirmed_match "$input_sidecar"; then
    metadata_confirmed=1
  fi
  if ! tag_media_from_omdb "$partial" "$work_directory" "$input_sidecar" "$output"; then
    log_warn "Metadata tagging failed: ${output}"
    [[ "$STRICT_TAGGING" == "1" ]] && return 1
  elif [[ "$metadata_confirmed" == "1" ]]; then
    metadata_tagged=1
  fi
  validate_media_output "$partial" "$input" || return 1

  if [[ -n "$LAST_SIZE_CAP_BYTES" ]]; then
    actual_size="$(file_size_bytes "$partial" 2>/dev/null || printf 0)"
    if size_is_over_tolerance "$actual_size" "$LAST_SIZE_CAP_BYTES"; then
      log_warn "Final tagged output exceeds target: actual=${actual_size} target=${LAST_SIZE_CAP_BYTES}."
      [[ "$STRICT_SIZE_CAP" == "1" ]] && return 1
    fi
  fi

  if ! published_subtitle="$(move_extracted_subtitle "$LAST_EXTRACTED_SUBTITLE" "$output")"; then
    return 1
  fi
  if ! move_file_no_clobber "$partial" "$output"; then
    log_error "Final output appeared before publication; refusing to overwrite it: ${output}"
    [[ -n "$published_subtitle" ]] && rm -f -- "$published_subtitle"
    return 1
  fi

  if [[ "$KEEP_OMDB_OUTPUT_SIDECAR" == "1" ]]; then
    if ! copy_omdb_sidecar_for_output "$input_sidecar" "$output"; then
      sidecar_copy_failed=1
      log_warn "Could not copy metadata sidecar for ${output}; preserving the source sidecar."
    fi
  fi
  cleanup_omdb_file_artifacts "$input" "$output" "$metadata_tagged" "$metadata_confirmed" "$sidecar_copy_failed" || \
    log_warn "Could not clean OMDb sidecars for ${output}"

  local completion_note=""
  [[ "$used_repaired" == 1 ]] && completion_note=' (repaired)'
  printf '[DONE ] %s -> %s%s metadata=%s\n' "$(safe_log_text "$input")" "$(safe_log_text "$(basename "$output")")" "$completion_note" \
    "$([[ "$metadata_tagged" == 1 ]] && printf tagged || printf skipped)" >&2
  [[ "$VERBOSE" == "1" ]] && set +x
  return 0
)

ACTIVE_PIDS=()
ACTIVE_FILES=()
ACTIVE_LOCKS=()
ALL_LOCKS=()
FAILURES=0

wait_for_any_worker() {
  local pid="" file lock status=0 index=0 current
  if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
    wait -n -p pid "${ACTIVE_PIDS[@]}" || status=$?
    for current in "${!ACTIVE_PIDS[@]}"; do
      if [[ "${ACTIVE_PIDS[current]}" == "$pid" ]]; then
        index="$current"
        break
      fi
    done
  else
    pid="${ACTIVE_PIDS[0]}"
    wait "$pid" || status=$?
  fi
  file="${ACTIVE_FILES[index]}"
  lock="${ACTIVE_LOCKS[index]}"
  if (( status != 0 )); then
    FAILURES=$((FAILURES + 1))
    log_error "Worker failed: ${file}"
  fi
  release_output_reservation "$lock"
  unset 'ACTIVE_PIDS[index]' 'ACTIVE_FILES[index]' 'ACTIVE_LOCKS[index]'
  ACTIVE_PIDS=("${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}")
  ACTIVE_FILES=("${ACTIVE_FILES[@]+"${ACTIVE_FILES[@]}"}")
  ACTIVE_LOCKS=("${ACTIVE_LOCKS[@]+"${ACTIVE_LOCKS[@]}"}")
}

terminate_process_tree() {
  local parent_pid="$1" child_pid
  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r child_pid; do
      [[ -n "$child_pid" ]] && terminate_process_tree "$child_pid"
    done < <(pgrep -P "$parent_pid" 2>/dev/null || true)
  fi
  kill -TERM "$parent_pid" 2>/dev/null || true
}

stop_active_workers() {
  local pid lock
  log_warn 'Interrupt received; stopping active conversion workers.'
  for pid in "${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}"; do
    terminate_process_tree "$pid"
  done
  for pid in "${ACTIVE_PIDS[@]+"${ACTIVE_PIDS[@]}"}"; do
    wait "$pid" 2>/dev/null || true
  done
  for lock in "${ALL_LOCKS[@]+"${ALL_LOCKS[@]}"}"; do
    release_output_reservation "$lock"
  done
  exit 130
}

cleanup_parent() {
  local lock
  for lock in "${ALL_LOCKS[@]+"${ALL_LOCKS[@]}"}"; do
    release_output_reservation "$lock"
  done
}

run_conversions() {
  local input requested reservation output lock pid
  trap stop_active_workers INT TERM
  trap cleanup_parent EXIT

  for input in "${FILES[@]}"; do
    requested="$(suggest_output_path "$input")"
    if [[ "$EXISTING_POLICY" == skip && ( -e "$requested" || -L "$requested" ) ]]; then
      log_info "Skipping existing output: ${requested}"
      continue
    fi
    reservation="$(reserve_output_path "$requested")" || {
      log_error "Could not reserve an output path for ${input}."
      FAILURES=$((FAILURES + 1))
      continue
    }
    IFS='|' read -r output lock <<< "$reservation"
    ALL_LOCKS+=("$lock")
    [[ "$output" != "${input%.*}.mp4" ]] && log_info "Reserved output: $(basename "$output")"

    process_one "$input" "$output" &
    pid=$!
    ACTIVE_PIDS+=("$pid")
    ACTIVE_FILES+=("$input")
    ACTIVE_LOCKS+=("$lock")
    if (( ${#ACTIVE_PIDS[@]} >= JOBS )); then
      wait_for_any_worker
    fi
  done

  while (( ${#ACTIVE_PIDS[@]} > 0 )); do
    wait_for_any_worker
  done
}

main() {
  trap stop_active_workers INT TERM
  parse_cli "$@"
  load_local_config || exit 1
  load_defaults
  deexport_config_variables
  validate_config || exit 1
  initialize_runtime || exit 1
  discover_input_files
  if [[ "$MODE" == convert ]]; then
    initialize_state_directory || exit 1
  fi
  print_banner

  if (( ${#FILES[@]} == 0 )); then
    log_info 'No MKV files found.'
    exit 0
  fi

  if [[ "$MODE" == subs_only ]]; then
    local file
    for file in "${FILES[@]}"; do
      if has_forced_eng_subs "$file"; then
        printf '%s: Forced English Subtitles = True\n' "$(safe_log_text "$(basename "$file")")"
      else
        printf '%s: Forced English Subtitles = False\n' "$(safe_log_text "$(basename "$file")")"
      fi
    done
    exit 0
  fi

  if [[ "$MODE" == inspect ]]; then
    local file inspect_failures=0
    for file in "${FILES[@]}"; do
      print_stream_inventory "$file" || inspect_failures=$((inspect_failures + 1))
    done
    (( inspect_failures == 0 ))
    exit $?
  fi

  if [[ "$MODE" == dry_run ]]; then
    local file plan_failures=0
    for file in "${FILES[@]}"; do
      print_conversion_plan "$file" || plan_failures=$((plan_failures + 1))
    done
    (( plan_failures == 0 ))
    exit $?
  fi

  if (( ${#FILES[@]} > 1 )) && [[ "$AUDIO_STREAM_INDEX" != auto || "$AUDIO_TRACK_POSITION" != auto ]]; then
    log_warn 'A manual audio override applies to every file in this batch; use --dry-run to verify each selection.'
  fi

  local required_space
  required_space="$(estimate_required_disk_bytes)"
  check_disk_space . "$required_space" || exit 1

  local file
  for file in "${FILES[@]}"; do
    if ! omdb_interactive_verify_and_save "$file"; then
      log_error "Metadata confirmation did not complete for ${file}; stopping before conversion."
      cleanup_omdb_run_artifacts 1 || true
      exit 1
    fi
  done

  run_conversions
  cleanup_omdb_run_artifacts "$FAILURES" || log_warn 'Could not clean OMDb run artifacts.'
  if [[ "$KEEP_OMDB_LOG" != "1" && "$FAILURES" == "0" && ! -f "$OMDB_LOG" ]]; then
    printf '[ALL DONE] failures=%s metadata-log=cleaned\n' "$FAILURES" >&2
  else
    printf '[ALL DONE] failures=%s metadata-log=%s\n' "$FAILURES" "$(safe_log_text "$OMDB_LOG")" >&2
  fi
  (( FAILURES == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
