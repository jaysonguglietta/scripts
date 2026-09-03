#!/usr/bin/env bash

# Shared runtime helpers for convert.sh. This file is sourced by the main script.

safe_log_text() {
  local value="${1:-}"
  value="${value//$'\033'/\\e}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\t'/\\t}"
  value="$(LC_ALL=C printf '%s' "$value" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
  printf '%s' "$value"
}

path_has_control_characters() {
  local value="${1:-}"
  case "$value" in
    *$'\033'*|*$'\r'*|*$'\n'*|*$'\t'*) return 0 ;;
  esac
  LC_ALL=C printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'
}

print_sanitized_file_excerpt() {
  local path="$1" maximum_lines="${2:-120}" line count=0
  [[ -f "$path" && "$maximum_lines" =~ ^[1-9][0-9]*$ ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$(safe_log_text "$line")" >&2
    count=$((count + 1))
    (( count >= maximum_lines )) && break
  done < "$path"
}

log_info() {
  printf '[INFO ] %s\n' "$(safe_log_text "$*")" >&2
}

log_warn() {
  printf '[WARN ] %s\n' "$(safe_log_text "$*")" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$(safe_log_text "$*")" >&2
}

command_display() {
  printf '+' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

validate_bool() {
  local name="$1" value="$2"
  case "$value" in
    0|1) return 0 ;;
    *) log_error "${name} must be 0 or 1, got: ${value}"; return 1 ;;
  esac
}

validate_positive_integer() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    log_error "${name} must be a positive integer, got: ${value}"
    return 1
  fi
}

validate_nonnegative_integer() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then
    log_error "${name} must be a non-negative integer, got: ${value}"
    return 1
  fi
}

validate_crf() {
  local name="$1" value="$2"
  validate_nonnegative_integer "$name" "$value" || return 1
  if (( value > 51 )); then
    log_error "${name} must be between 0 and 51, got: ${value}"
    return 1
  fi
}

validate_kilobit_rate() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*k$ ]]; then
    log_error "${name} must use a positive kilobit value such as 192k, got: ${value}"
    return 1
  fi
}

resolve_required_tool() {
  local variable_name="$1"
  shift
  local configured="${!variable_name:-}"
  local candidate resolved=""

  if [[ -n "$configured" ]]; then
    resolved="$(command -v "$configured" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      log_error "${variable_name} command not found: ${configured}"
      return 1
    fi
    printf -v "$variable_name" '%s' "$resolved"
    return 0
  fi

  for candidate in "$@"; do
    resolved="$(command -v "$candidate" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      printf -v "$variable_name" '%s' "$resolved"
      return 0
    fi
  done

  log_error "No supported command found for ${variable_name}: $*"
  return 1
}

parse_size_to_bytes() {
  local raw="${1:-}" cleaned number unit multiplier
  cleaned="$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

  if [[ ! "$cleaned" =~ ^([0-9]+([.][0-9]+)?)(B|K|KB|KIB|M|MB|MIB|G|GB|GIB|T|TB|TIB)?$ ]]; then
    return 1
  fi

  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[3]:-B}"
  case "$unit" in
    B) multiplier=1 ;;
    K|KB|KIB) multiplier=1024 ;;
    M|MB|MIB) multiplier=$((1024 * 1024)) ;;
    G|GB|GIB) multiplier=$((1024 * 1024 * 1024)) ;;
    T|TB|TIB) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac

  awk -v number="$number" -v multiplier="$multiplier" '
    BEGIN {
      bytes = number * multiplier
      if (bytes < 1) exit 1
      printf "%.0f\n", bytes
    }
  '
}

file_size_bytes() {
  local path="$1"
  stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null
}

available_space_bytes() {
  local path="$1"
  df -Pk "$path" 2>/dev/null | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

lowercase() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

language_is_english() {
  local language="${1:-}"
  language="$(lowercase "$language")"
  language="${language//_/-}"
  case "$language" in
    eng|en|english|eng-*|en-*) return 0 ;;
    *) return 1 ;;
  esac
}

language_is_untagged() {
  local language="${1:-}"
  language="$(lowercase "$language")"
  case "$language" in
    ''|und|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

sanitize_filename() {
  local value="$1" base extension=""
  value="${value//$'\033'/}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\t'/ }"
  value="${value//\//-}"
  value="${value//\\/-}"
  value="${value//:/ -}"
  value="${value//\*/-}"
  value="${value//\?/-}"
  value="${value//\"/-}"
  value="${value//</-}"
  value="${value//>/-}"
  value="${value//|/-}"
  value="$(LC_ALL=C printf '%s' "$value" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
  if [[ "$value" == *.* ]]; then
    extension=".${value##*.}"
    base="${value%.*}"
  else
    base="$value"
  fi
  base="$(printf '%s' "$base" | sed -E 's/[[:space:]]+/ /g; s/[-]{2,}/-/g')"
  base="$(printf '%s' "$base" | sed -E 's/^[.[:space:]-]+|[.[:space:]-]+$//g')"
  [[ -n "$base" ]] || base=untitled
  value="$(truncate_filename_bytes "${base}${extension}" 220)"
  printf '%s' "$value"
}

truncate_filename_bytes() {
  local value="$1" maximum="$2" extension="" base bytes
  if [[ "$value" == *.* ]]; then
    extension=".${value##*.}"
    base="${value%.*}"
  else
    base="$value"
  fi
  while :; do
    bytes="$(LC_ALL=C printf '%s' "${base}${extension}" | wc -c | tr -d '[:space:]')"
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
    (( bytes <= maximum )) && break
    [[ -n "$base" ]] || return 1
    base="${base%?}"
  done
  printf '%s' "${base}${extension}"
}

unique_path() {
  local path="$1" base extension candidate
  local number=1

  if [[ ! -e "$path" ]]; then
    printf '%s' "$path"
    return 0
  fi

  base="${path%.*}"
  extension="${path##*.}"
  while (( number < ${MAX_RESERVATION_ATTEMPTS:-10000} )); do
    candidate="${base} (${number}).${extension}"
    if [[ ! -e "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    number=$((number + 1))
  done
  return 1
}

move_file_no_clobber() {
  local source="$1" destination="$2"
  [[ -f "$source" && ! -e "$destination" && ! -L "$destination" ]] || return 1
  mv -n -- "$source" "$destination" || return 1
  [[ ! -e "$source" && -f "$destination" && ! -L "$destination" ]]
}

reservation_lock_path() {
  local candidate="$1" directory checksum
  directory="$(dirname "$candidate")"
  checksum="$(printf '%s' "$candidate" | cksum | awk '{ print $1 }')" || return 1
  [[ "$checksum" =~ ^[0-9]+$ ]] || return 1
  printf '%s/.media-conversion.%s.lock' "$directory" "$checksum"
}

# Atomically reserves an output name across workers and script instances.
reserve_output_path() {
  local requested="$1" base extension candidate lock_dir
  local number=0

  base="${requested%.*}"
  extension="${requested##*.}"
  while (( number < ${MAX_RESERVATION_ATTEMPTS:-10000} )); do
    if (( number == 0 )); then
      candidate="$requested"
    else
      candidate="${base} (${number}).${extension}"
    fi
    lock_dir="$(reservation_lock_path "$candidate")" || return 1

    if [[ ! -e "$candidate" && ! -L "$candidate" ]] && mkdir -m 700 "$lock_dir" 2>/dev/null; then
      if [[ -e "$candidate" || -L "$candidate" ]]; then
        release_output_reservation "$lock_dir"
        number=$((number + 1))
        continue
      fi
      printf '%s\n' "pid=$$" "host=$(hostname 2>/dev/null || printf unknown)" > "${lock_dir}/owner"
      printf '%s|%s\n' "$candidate" "$lock_dir"
      return 0
    fi
    if [[ ! -e "$candidate" && ! -L "$candidate" && ! -d "$lock_dir" ]]; then
      log_error "Could not create output reservation for ${candidate}."
      return 1
    fi
    number=$((number + 1))
  done
  log_error "Exceeded ${MAX_RESERVATION_ATTEMPTS:-10000} attempts while reserving ${requested}."
  return 1
}

release_output_reservation() {
  local lock_dir="${1:-}"
  [[ -n "$lock_dir" && -d "$lock_dir" && ! -L "$lock_dir" ]] || return 0
  case "$(basename "$lock_dir")" in
    .media-conversion.*.lock) ;;
    *) log_warn "Refusing to release unexpected reservation: ${lock_dir}"; return 1 ;;
  esac
  rm -f -- "${lock_dir}/owner"
  rmdir -- "$lock_dir" 2>/dev/null || true
}

make_worker_directory() {
  local output_path="$1" directory
  directory="$(dirname "$output_path")"
  mktemp -d "${directory}/.media-conversion.XXXXXX"
}

cleanup_worker_directory() {
  local directory="${1:-}"
  local base
  [[ -n "$directory" && -d "$directory" ]] || return 0
  base="$(basename "$directory")"
  case "$base" in
    .media-conversion.*) rm -rf -- "$directory" ;;
    *) log_warn "Refusing to remove unexpected worker directory: ${directory}" ;;
  esac
}

log_has_non_monotonic_dts() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  if command -v rg >/dev/null 2>&1; then
    rg -qi 'Non-monotoni(c|ous) DTS' "$log_file"
  else
    grep -Eqi 'Non-monotoni(c|ous) DTS' "$log_file"
  fi
}

ffprobe_duration() {
  local path="$1"
  "$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$path" 2>/dev/null | head -n 1
}

ffprobe_stream_count() {
  local path="$1" selector="$2"
  "$FFPROBE" -v error -select_streams "$selector" -show_entries stream=index -of csv=p=0 "$path" 2>/dev/null |
    awk 'NF { count++ } END { print count + 0 }'
}

ffprobe_audio_language_summary() {
  local path="$1"
  "$FFPROBE" -v error -select_streams a \
    -show_entries stream=index:stream_tags=language -of csv=p=0 "$path" 2>/dev/null |
    awk -F',' '
      {
        language=tolower($2)
        gsub(/_/, "-", language)
        total++
        if (!(language=="eng" || language=="en" || language=="english" || language ~ /^eng-/ || language ~ /^en-/)) bad++
      }
      END { printf "%d|%d\n", total + 0, bad + 0 }
    '
}

durations_are_close() {
  local source="$1" result="$2"
  awk -v source="$source" -v result="$result" \
    -v duration_seconds="${DURATION_TOLERANCE_SECONDS:-5}" \
    -v duration_permille="${DURATION_TOLERANCE_PERMILLE:-1}" '
    BEGIN {
      difference = source - result
      if (difference < 0) difference = -difference
      tolerance = source * duration_permille / 1000
      if (tolerance < duration_seconds) tolerance = duration_seconds
      exit !(difference <= tolerance)
    }
  '
}

validate_media_output() {
  local output="$1" input="$2" validation_mode="${3:-${VALIDATION_MODE:-probe}}"
  local video_count audio_count tagged_audio_count non_english_audio_count output_duration input_duration

  if [[ ! -s "$output" ]]; then
    log_error "Output is missing or empty: ${output}"
    return 1
  fi

  if ! "$FFPROBE" -v error "$output" >/dev/null 2>&1; then
    log_error "ffprobe could not read the completed output: ${output}"
    return 1
  fi

  video_count="$(ffprobe_stream_count "$output" v)"
  audio_count="$(ffprobe_stream_count "$output" a)"
  if (( video_count < 1 || audio_count < 1 )); then
    log_error "Output validation failed: video streams=${video_count}, audio streams=${audio_count}"
    return 1
  fi
  if ! IFS='|' read -r tagged_audio_count non_english_audio_count < <(ffprobe_audio_language_summary "$output"); then
    log_error 'Output validation could not inspect audio language tags.'
    return 1
  fi
  if [[ ! "$tagged_audio_count" =~ ^[0-9]+$ || ! "$non_english_audio_count" =~ ^[0-9]+$ ]] || \
      (( tagged_audio_count != audio_count || non_english_audio_count > 0 )); then
    log_error "Output validation failed: audio streams=${audio_count}, language-tagged=${tagged_audio_count:-unknown}, non-English=${non_english_audio_count:-unknown}"
    return 1
  fi

  output_duration="$(ffprobe_duration "$output")"
  input_duration="$(ffprobe_duration "$input")"
  if [[ -z "$output_duration" ]] || ! awk -v duration="$output_duration" 'BEGIN { exit !(duration > 0) }'; then
    log_error "Output has no valid duration: ${output}"
    return 1
  fi

  if [[ -n "$input_duration" ]] && awk -v duration="$input_duration" 'BEGIN { exit !(duration > 0) }'; then
    if ! durations_are_close "$input_duration" "$output_duration"; then
      log_error "Duration mismatch: input=${input_duration}s output=${output_duration}s"
      return 1
    fi
  fi

  if [[ "$validation_mode" == "decode" ]]; then
    log_info "Decoding output for strict validation: $(basename "$output")"
    if ! "$FFMPEG" -hide_banner -v error -xerror -nostdin -i "$output" \
        -map 0:v:0 -map 0:a:0 -f null - >/dev/null 2>&1; then
      log_error "Full-decode validation failed: ${output}"
      return 1
    fi
  fi

  return 0
}

check_disk_space() {
  local directory="$1" required_bytes="$2"
  local available_bytes
  available_bytes="$(available_space_bytes "$directory" || true)"
  [[ -n "$available_bytes" ]] || return 0

  if (( available_bytes < required_bytes )); then
    log_warn "Estimated working space is ${required_bytes} bytes, but only ${available_bytes} bytes are available."
    [[ "${STRICT_DISK_CHECK:-0}" == "1" ]] && return 1
  else
    log_info "Disk-space check: ${available_bytes} bytes available; approximately ${required_bytes} bytes may be needed."
  fi
}
