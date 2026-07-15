#!/usr/bin/env bash
# Batch MKV-to-MP4 converter for Fedora/Linux media servers.

set -uo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for library in common metadata media; do
  library_path="${SCRIPT_DIR}/lib/${library}.sh"
  if [[ ! -r "$library_path" ]]; then
    printf '[ERROR] Required library is missing: %s\n' "$library_path" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$library_path"
done
unset library library_path

MODE=convert
TARGET_SIZE_SPEC=""
MAX_HEIGHT_CLI=""
AUDIO_MODE_CLI=""
AUDIO_STREAM_CLI=""
FORCED_SUBTITLE_STREAM_CLI=""
QUALITY_ENCODE_CLI=""
X265_PRESET_CLI=""
JOBS_CLI=""
OMDB_REFRESH_CLI=""
STRICT_SIZE_CLI=""

CONFIG_VARIABLES=(
  FFMPEG FFPROBE JOBS VERBOSE
  OMDB_API_KEY OMDB_URL OMDB_LOG OMDB_LOG_LOCK OMDB_INTERACTIVE OMDB_REFRESH OMDB_CONNECT_TIMEOUT OMDB_MAX_TIME OMDB_RETRIES
  REPAIR_MODE SUBTITLE_MODE FAST_VIDEO_COPY KEEP_OMDB_SOURCE_SIDECAR KEEP_OMDB_OUTPUT_SIDECAR KEEP_OMDB_LOG
  ALLOW_UNTAGGED_AUDIO_FALLBACK ALLOW_FORCED_TITLE_FALLBACK AUDIO_STREAM_INDEX FORCED_SUBTITLE_STREAM FIX_TIMESTAMPS
  QSV_GLOBAL_QUALITY QSV_PRESET X264_CRF X264_PRESET X264_THREADS X265_CRF X265_PRESET USE_VBV VBV_MAXRATE VBV_BUFSIZE AAC_STEREO_BR AC3_51_BR
  TV_MAX_BYTES MP4_TAG_HEADROOM_BYTES AUDIO_MODE QUALITY_ENCODE MAX_HEIGHT SIZE_SAFETY_PERCENT SIZE_RETRY_ATTEMPTS SIZE_TOLERANCE_PERCENT
  STRICT_SIZE_CAP STRICT_TAGGING STRICT_DISK_CHECK
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
  --forced-subtitle-stream N  use an explicit subtitle-relative stream position
  --quality-encode            use software HEVC for tighter compression
  --x265-preset PRESET        libx265 speed/quality preset
  --jobs COUNT                maximum simultaneous conversions
  --refresh-metadata          replace cached OMDb metadata after a valid response
  --strict-size               fail files that remain over their target after retry
  --print-subs-only           report forced English subtitle detection and exit
  -h, --help                  show this help

Important environment settings:
  OMDB_API_KEY                required for new OMDb lookups; no key is embedded
  MEDIA_CONVERSION_CONFIG     optional env-file path to auto-load before defaults
  OMDB_INTERACTIVE=0|1        verify metadata interactively (default: 1)
  REPAIR_MODE=auto|always|never
  SUBTITLE_MODE=burn|copy|extract
  FAST_VIDEO_COPY=0|1
  KEEP_OMDB_SOURCE_SIDECAR=0|1
  KEEP_OMDB_OUTPUT_SIDECAR=0|1
  KEEP_OMDB_LOG=0|1
  ALLOW_UNTAGGED_AUDIO_FALLBACK=0|1
  ALLOW_FORCED_TITLE_FALLBACK=0|1
  AUDIO_STREAM_INDEX=auto|INDEX
  FORCED_SUBTITLE_STREAM=auto|POSITION
  STRICT_TAGGING=0|1
  STRICT_DISK_CHECK=0|1
  SIZE_RETRY_ATTEMPTS=1

Run from the directory containing the MKV files. See README.md for all settings.
EOF
}

load_config_file() {
  local config_path="$1" variable had_var saved_var

  for variable in "${CONFIG_VARIABLES[@]}"; do
    had_var="CONFIG_HAD_${variable}"
    saved_var="CONFIG_VALUE_${variable}"
    if [[ ${!variable+x} ]]; then
      printf -v "$had_var" '%s' 1
      printf -v "$saved_var" '%s' "${!variable}"
    else
      printf -v "$had_var" '%s' 0
      printf -v "$saved_var" '%s' ''
    fi
  done

  set -a
  # shellcheck source=/dev/null
  source "$config_path"
  set +a

  for variable in "${CONFIG_VARIABLES[@]}"; do
    had_var="CONFIG_HAD_${variable}"
    saved_var="CONFIG_VALUE_${variable}"
    if [[ "${!had_var}" == "1" ]]; then
      printf -v "$variable" '%s' "${!saved_var}"
      export "$variable"
    fi
    unset "$had_var" "$saved_var"
  done

  LOADED_CONFIG_PATH="$config_path"
  log_info "Loaded config: ${config_path}"
}

load_local_config() {
  local config_path
  local -a candidates=()

  if [[ -n "${MEDIA_CONVERSION_CONFIG:-}" ]]; then
    candidates+=("$MEDIA_CONVERSION_CONFIG")
  fi
  candidates+=("${SCRIPT_DIR}/media-conversion.local.env")
  if [[ -n "${HOME:-}" ]]; then
    candidates+=("${HOME}/.config/media-conversion.env")
  fi

  for config_path in "${candidates[@]}"; do
    [[ -n "$config_path" ]] || continue
    if [[ ! -e "$config_path" ]]; then
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
      --strict-size) STRICT_SIZE_CLI=1; shift ;;
      *) log_error "Unknown option: $1"; print_usage >&2; exit 1 ;;
    esac
  done
}

load_defaults() {
  FFMPEG="${FFMPEG:-}"
  FFPROBE="${FFPROBE:-}"
  JOBS="${JOBS:-3}"
  VERBOSE="${VERBOSE:-0}"

  OMDB_API_KEY="${OMDB_API_KEY:-}"
  OMDB_URL="${OMDB_URL:-https://www.omdbapi.com}"
  OMDB_LOG="${OMDB_LOG:-omdb_tagging_log.csv}"
  OMDB_LOG_LOCK="${OMDB_LOG_LOCK:-${OMDB_LOG}.lock}"
  OMDB_INTERACTIVE="${OMDB_INTERACTIVE:-1}"
  OMDB_REFRESH="${OMDB_REFRESH:-0}"
  OMDB_CONNECT_TIMEOUT="${OMDB_CONNECT_TIMEOUT:-5}"
  OMDB_MAX_TIME="${OMDB_MAX_TIME:-20}"
  OMDB_RETRIES="${OMDB_RETRIES:-2}"
  OMDB_ENABLED=0

  REPAIR_MODE="${REPAIR_MODE:-auto}"
  SUBTITLE_MODE="${SUBTITLE_MODE:-burn}"
  FAST_VIDEO_COPY="${FAST_VIDEO_COPY:-1}"
  KEEP_OMDB_SOURCE_SIDECAR="${KEEP_OMDB_SOURCE_SIDECAR:-0}"
  KEEP_OMDB_OUTPUT_SIDECAR="${KEEP_OMDB_OUTPUT_SIDECAR:-0}"
  KEEP_OMDB_LOG="${KEEP_OMDB_LOG:-0}"
  ALLOW_UNTAGGED_AUDIO_FALLBACK="${ALLOW_UNTAGGED_AUDIO_FALLBACK:-1}"
  ALLOW_FORCED_TITLE_FALLBACK="${ALLOW_FORCED_TITLE_FALLBACK:-1}"
  AUDIO_STREAM_INDEX="${AUDIO_STREAM_INDEX:-auto}"
  FORCED_SUBTITLE_STREAM="${FORCED_SUBTITLE_STREAM:-auto}"
  FIX_TIMESTAMPS="${FIX_TIMESTAMPS:-1}"

  QSV_GLOBAL_QUALITY="${QSV_GLOBAL_QUALITY:-22}"
  QSV_PRESET="${QSV_PRESET:-medium}"
  X264_CRF="${X264_CRF:-20}"
  X264_PRESET="${X264_PRESET:-veryfast}"
  X264_THREADS="${X264_THREADS:-6}"
  X265_CRF="${X265_CRF:-23}"
  X265_PRESET="${X265_PRESET:-medium}"
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
  STRICT_DISK_CHECK="${STRICT_DISK_CHECK:-0}"

  [[ -n "$MAX_HEIGHT_CLI" ]] && MAX_HEIGHT="$MAX_HEIGHT_CLI"
  [[ -n "$AUDIO_MODE_CLI" ]] && AUDIO_MODE="$AUDIO_MODE_CLI"
  [[ -n "$AUDIO_STREAM_CLI" ]] && AUDIO_STREAM_INDEX="$AUDIO_STREAM_CLI"
  [[ -n "$FORCED_SUBTITLE_STREAM_CLI" ]] && FORCED_SUBTITLE_STREAM="$FORCED_SUBTITLE_STREAM_CLI"
  [[ -n "$QUALITY_ENCODE_CLI" ]] && QUALITY_ENCODE="$QUALITY_ENCODE_CLI"
  [[ -n "$X265_PRESET_CLI" ]] && X265_PRESET="$X265_PRESET_CLI"
  [[ -n "$JOBS_CLI" ]] && JOBS="$JOBS_CLI"
  [[ -n "$OMDB_REFRESH_CLI" ]] && OMDB_REFRESH="$OMDB_REFRESH_CLI"
  [[ -n "$STRICT_SIZE_CLI" ]] && STRICT_SIZE_CAP="$STRICT_SIZE_CLI"
}

validate_stream_override() {
  local name="$1" value="$2"
  if [[ "$value" != auto && ! "$value" =~ ^[0-9]+$ ]]; then
    log_error "${name} must be auto or a non-negative integer, got: ${value}"
    return 1
  fi
}

validate_config() {
  local setting
  validate_positive_integer JOBS "$JOBS" || return 1
  for setting in VERBOSE OMDB_INTERACTIVE OMDB_REFRESH FAST_VIDEO_COPY \
    KEEP_OMDB_SOURCE_SIDECAR KEEP_OMDB_OUTPUT_SIDECAR KEEP_OMDB_LOG \
    ALLOW_UNTAGGED_AUDIO_FALLBACK ALLOW_FORCED_TITLE_FALLBACK FIX_TIMESTAMPS \
    QUALITY_ENCODE USE_VBV STRICT_SIZE_CAP STRICT_TAGGING STRICT_DISK_CHECK; do
    validate_bool "$setting" "${!setting}" || return 1
  done

  validate_nonnegative_integer MAX_HEIGHT "$MAX_HEIGHT" || return 1
  validate_nonnegative_integer X264_THREADS "$X264_THREADS" || return 1
  validate_nonnegative_integer OMDB_RETRIES "$OMDB_RETRIES" || return 1
  validate_positive_integer OMDB_CONNECT_TIMEOUT "$OMDB_CONNECT_TIMEOUT" || return 1
  validate_positive_integer OMDB_MAX_TIME "$OMDB_MAX_TIME" || return 1
  validate_positive_integer TV_MAX_BYTES "$TV_MAX_BYTES" || return 1
  validate_nonnegative_integer MP4_TAG_HEADROOM_BYTES "$MP4_TAG_HEADROOM_BYTES" || return 1
  validate_positive_integer SIZE_SAFETY_PERCENT "$SIZE_SAFETY_PERCENT" || return 1
  validate_nonnegative_integer SIZE_RETRY_ATTEMPTS "$SIZE_RETRY_ATTEMPTS" || return 1
  validate_nonnegative_integer SIZE_TOLERANCE_PERCENT "$SIZE_TOLERANCE_PERCENT" || return 1
  validate_crf X264_CRF "$X264_CRF" || return 1
  validate_crf X265_CRF "$X265_CRF" || return 1
  validate_crf QSV_GLOBAL_QUALITY "$QSV_GLOBAL_QUALITY" || return 1
  validate_positive_integer VBV_MAXRATE "$VBV_MAXRATE" || return 1
  validate_positive_integer VBV_BUFSIZE "$VBV_BUFSIZE" || return 1
  validate_kilobit_rate AAC_STEREO_BR "$AAC_STEREO_BR" || return 1
  validate_kilobit_rate AC3_51_BR "$AC3_51_BR" || return 1
  validate_stream_override AUDIO_STREAM_INDEX "$AUDIO_STREAM_INDEX" || return 1
  validate_stream_override FORCED_SUBTITLE_STREAM "$FORCED_SUBTITLE_STREAM" || return 1

  case "$REPAIR_MODE" in auto|always|never) ;; *) log_error "Invalid REPAIR_MODE: ${REPAIR_MODE}"; return 1 ;; esac
  case "$SUBTITLE_MODE" in burn|copy|extract) ;; *) log_error "Invalid SUBTITLE_MODE: ${SUBTITLE_MODE}"; return 1 ;; esac
  case "$AUDIO_MODE" in surround+stereo|surround|stereo) ;; *) log_error "Invalid AUDIO_MODE: ${AUDIO_MODE}"; return 1 ;; esac
  case "$X265_PRESET" in ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow|placebo) ;;
    *) log_error "Invalid X265_PRESET: ${X265_PRESET}"; return 1 ;;
  esac
  if (( SIZE_SAFETY_PERCENT < 50 || SIZE_SAFETY_PERCENT > 100 )); then
    log_error 'SIZE_SAFETY_PERCENT must be between 50 and 100.'
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
}

discover_input_files() {
  FILES=()
  local candidate base
  local -a candidates=(./*.mkv ./*.MKV)
  for candidate in "${candidates[@]}"; do
    base="$(basename "$candidate")"
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
    IFS='|' read -r detected_type _ _ _ _ _ _ < <(detect_type_and_query "$(basename "${file%.*}")")
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
  [[ -n "$LOADED_CONFIG_PATH" ]] && printf 'Config=%s\n' "$LOADED_CONFIG_PATH" >&2
  printf 'Metadata cleanup source-sidecar=%s output-sidecar=%s log=%s\n' \
    "$KEEP_OMDB_SOURCE_SIDECAR" "$KEEP_OMDB_OUTPUT_SIDECAR" "$KEEP_OMDB_LOG" >&2
  [[ -n "$TARGET_SIZE_BYTES" ]] && printf 'Target size=%s bytes\n' "$TARGET_SIZE_BYTES" >&2
  printf 'TV target=%s bytes metadata headroom=%s bytes\n' "$TV_MAX_BYTES" "$MP4_TAG_HEADROOM_BYTES" >&2
  printf '%s\n' '========================================' >&2
}

move_extracted_subtitle() {
  local staged="$1" output="$2" extension target
  [[ -n "$staged" && -f "$staged" ]] || return 0
  extension="${staged##*.}"
  target="${output%.*}.en.forced.${extension}"
  [[ -e "$target" ]] && target="$(unique_path "$target")"
  mv -f -- "$staged" "$target"
  log_info "Subtitle sidecar: $(basename "$target")"
}

size_is_over_tolerance() {
  local actual="$1" target="$2"
  (( actual * 100 > target * (100 + SIZE_TOLERANCE_PERCENT) ))
}

process_one() (
  local input="$1" output="$2"
  local work_directory="" partial="" repaired="" source="$input" convert_status=0
  local used_repaired=0 detected_type file_name actual_size retry=0 retry_bitrate=""
  local metadata_tagged=0 metadata_confirmed=0
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
  printf '[START] %s\n' "$input" >&2
  print_forced_sub_status "$input"
  file_name="$(basename "$input")"
  IFS='|' read -r detected_type _ _ _ _ _ _ < <(detect_type_and_query "${file_name%.*}")

  case "$REPAIR_MODE" in
    always)
      if ! repair_mkv "$input" "$repaired" "${work_directory}/repair.log"; then
        log_error "Repair failed: ${input}"
        sed -n '1,120p' "${work_directory}/repair.log" >&2
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
          sed -n '1,120p' "${work_directory}/repair.log" >&2
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

  validate_media_output "$partial" "$input" || return 1
  mv -f -- "$partial" "$output" || return 1
  move_extracted_subtitle "$LAST_EXTRACTED_SUBTITLE" "$output" || return 1

  local input_sidecar="${input%.*}.omdb.json"
  copy_omdb_sidecar_for_output "$input_sidecar" "$output" || log_warn "Could not copy metadata sidecar for ${output}."
  if json_is_confirmed_match "${output%.*}.omdb.json"; then
    metadata_confirmed=1
  fi
  if ! tag_media_from_omdb "$output" "$work_directory"; then
    log_warn "Metadata tagging failed: ${output}"
    [[ "$STRICT_TAGGING" == "1" ]] && return 1
  elif [[ "$metadata_confirmed" == "1" ]]; then
    metadata_tagged=1
  fi
  validate_media_output "$output" "$input" || return 1
  cleanup_omdb_file_artifacts "$input" "$output" "$metadata_tagged" "$metadata_confirmed" || \
    log_warn "Could not clean OMDb sidecars for ${output}"

  if [[ -n "$LAST_SIZE_CAP_BYTES" ]]; then
    actual_size="$(file_size_bytes "$output" 2>/dev/null || printf 0)"
    if size_is_over_tolerance "$actual_size" "$LAST_SIZE_CAP_BYTES"; then
      log_warn "Final tagged output exceeds target: actual=${actual_size} target=${LAST_SIZE_CAP_BYTES}."
      [[ "$STRICT_SIZE_CAP" == "1" ]] && return 1
    fi
  fi

  local completion_note=""
  [[ "$used_repaired" == 1 ]] && completion_note=' (repaired)'
  printf '[DONE ] %s -> %s%s\n' "$input" "$(basename "$output")" "$completion_note" >&2
  [[ "$VERBOSE" == "1" ]] && set +x
  return 0
)

ACTIVE_PIDS=()
ACTIVE_FILES=()
ACTIVE_LOCKS=()
ALL_LOCKS=()
FAILURES=0

wait_for_first_worker() {
  local pid="${ACTIVE_PIDS[0]}" file="${ACTIVE_FILES[0]}" lock="${ACTIVE_LOCKS[0]}"
  if ! wait "$pid"; then
    FAILURES=$((FAILURES + 1))
    log_error "Worker failed: ${file}"
  fi
  release_output_reservation "$lock"
  ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  ACTIVE_FILES=("${ACTIVE_FILES[@]:1}")
  ACTIVE_LOCKS=("${ACTIVE_LOCKS[@]:1}")
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
      wait_for_first_worker
    fi
  done

  while (( ${#ACTIVE_PIDS[@]} > 0 )); do
    wait_for_first_worker
  done
}

main() {
  parse_cli "$@"
  load_local_config || exit 1
  load_defaults
  validate_config || exit 1
  initialize_runtime || exit 1
  discover_input_files
  print_banner

  if (( ${#FILES[@]} == 0 )); then
    log_info 'No MKV files found.'
    exit 0
  fi

  if [[ "$MODE" == subs_only ]]; then
    local file
    for file in "${FILES[@]}"; do
      if has_forced_eng_subs "$file"; then
        printf '%s: Forced English Subtitles = True\n' "$(basename "$file")"
      else
        printf '%s: Forced English Subtitles = False\n' "$(basename "$file")"
      fi
    done
    exit 0
  fi

  local required_space
  required_space="$(estimate_required_disk_bytes)"
  check_disk_space . "$required_space" || exit 1

  if [[ "$OMDB_ENABLED" == "1" ]]; then
    local file
    for file in "${FILES[@]}"; do
      omdb_interactive_verify_and_save "$file"
    done
  fi

  run_conversions
  cleanup_omdb_run_artifacts "$FAILURES" || log_warn 'Could not clean OMDb run artifacts.'
  if [[ "$KEEP_OMDB_LOG" != "1" && "$FAILURES" == "0" && ! -f "$OMDB_LOG" ]]; then
    printf '[ALL DONE] failures=%s metadata-log=cleaned\n' "$FAILURES" >&2
  else
    printf '[ALL DONE] failures=%s metadata-log=%s\n' "$FAILURES" "$OMDB_LOG" >&2
  fi
  (( FAILURES == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
