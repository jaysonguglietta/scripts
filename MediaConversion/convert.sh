#!/usr/bin/env bash
# convert.sh
#
# MKV -> MP4 (Plex on Apple TV 4K optimized)
# - Automatic MKV repair retry in auto mode (mkvmerge preferred, ffmpeg copy fallback)
# - Keep English audio only (prefer highest-channel English); optional fallback to an untagged default track; keep 5.1 when possible + add AAC stereo fallback
# - Forced English subtitles only: burn/copy/extract modes; always drop non-English subtitles
# - Fast path: copy compatible H.264/HEVC video into MP4 when burn-in is not needed
# - Always do OMDb lookup (omdbapi.com)
# - Download poster (if available)
# - Embed poster + metadata into produced MP4
# - Graceful fallbacks if OMDb doesn't match or tools missing
# - Enhanced year detection for movies and SxxExx detection for TV
# - Hard-stop on Ctrl-C (kills all background jobs)
# - TV episodes: try to keep encoded MP4 <= 1 GiB by default (best-effort)
# - Optional --target-size SIZE cap for any file, e.g. --target-size 2GB
# - Optional quality controls for tight size targets: --max-height, --audio, --quality-encode
# - Reserve MP4 metadata headroom so MetaFetch can tag converted files in place
# - Interactive OMDb verification and ability to select alternatives
# - Automatically rename output MP4s based on confirmed OMDb metadata
#
# USAGE EXAMPLES (quick):
#   ./convert.sh
#     - Convert all *.mkv in the current directory.
#
#   ./convert.sh --print-subs-only
#     - Scan all *.mkv in the current directory and print:
#         <file>: Forced English Subtitles = True|False
#       Then exit (no conversion, no OMDb lookups).
#
#   ./convert.sh --target-size 2GB
#     - Aim to keep each output MP4 under ~2 GiB (best-effort bitrate cap).
#
#   ./convert.sh --target-size 2GB --max-height 720 --audio stereo --quality-encode
#     - Better quality when shrinking large sources to a small file: downscale,
#       spend less on audio, and use slower software HEVC instead of fast QSV.
#
#   ./convert.sh -h
#     - Show brief help.
#
#   JOBS=4 FFMPEG=ffmpeg FFPROBE=ffprobe ./convert.sh
#     - Run up to 4 conversions in parallel, using system ffmpeg/ffprobe.
#
#   VERBOSE=1 JOBS=1 ./convert.sh
#     - Foreground, single-file at a time, with bash tracing enabled per file.
#
#   OMDB_INTERACTIVE=0 OMDB_API_KEY=yourkey ./convert.sh
#     - Non-interactive OMDb lookups (still attempted for every file).
#
#   TV_MAX_BYTES=$((700*1024*1024)) ./convert.sh
#     - Aim to keep TV episodes under ~700 MiB (best-effort bitrate cap).
#
#   REPAIR_MODE=auto SUBTITLE_MODE=extract ./convert.sh
#     - Retry with a repaired MKV only after a conversion failure; extract forced English subtitles as sidecars.
#
#   ALLOW_UNTAGGED_AUDIO_FALLBACK=1 ./convert.sh
#     - If no audio track is tagged English, allow the default/untagged audio track to be used.
#
set -uo pipefail
shopt -s nullglob


############################################
# CLI args
#   --print-subs-only : scan files and print forced English subtitle presence, then exit
#   --target-size SIZE: best-effort output size cap for any file
#   --max-height N    : downscale video to at most N pixels high
#   --audio MODE     : surround+stereo|surround|stereo
#   --quality-encode : use slower software HEVC for better compression quality
############################################
MODE="convert"
TARGET_SIZE_SPEC=""
MAX_HEIGHT_CLI=""
AUDIO_MODE_CLI=""
QUALITY_ENCODE_CLI=""

print_usage() {
  cat >&2 <<'EOF'
Usage:
  ./convert.sh [options]

Options:
  --target-size SIZE        best-effort output size cap for any file, e.g. 2GB or 700MB
  --max-height HEIGHT       downscale video to at most HEIGHT pixels high, e.g. 720
  --audio MODE              surround+stereo, surround, or stereo
  --quality-encode          use slower software HEVC for better quality at small sizes
  --print-subs-only         scan current dir for MKV and report forced English subtitles
  -h, --help                show this help

Environment overrides:
  FFMPEG, FFPROBE, JOBS, VERBOSE, OMDB_API_KEY, OMDB_INTERACTIVE,
  REPAIR_MODE=auto|always|never, SUBTITLE_MODE=burn|copy|extract,
  FAST_VIDEO_COPY=0|1, ALLOW_UNTAGGED_AUDIO_FALLBACK=0|1,
  AUDIO_MODE=surround+stereo|surround|stereo, QUALITY_ENCODE=0|1,
  MAX_HEIGHT=0, TV_MAX_BYTES=1073741824, MP4_TAG_HEADROOM_BYTES=16777216, ...
EOF
}

parse_size_to_bytes() {
  local raw="${1:-}" cleaned number unit multiplier
  cleaned="$(printf "%s" "$raw" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      print_usage
      exit 0
      ;;
    --print-subs-only)
      MODE="subs_only"
      shift
      ;;
    --target-size)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "[ERROR] --target-size requires a value, e.g. --target-size 2GB" >&2
        exit 1
      fi
      TARGET_SIZE_SPEC="$2"
      shift 2
      ;;
    --target-size=*)
      TARGET_SIZE_SPEC="${1#*=}"
      if [[ -z "$TARGET_SIZE_SPEC" ]]; then
        echo "[ERROR] --target-size requires a value, e.g. --target-size=2GB" >&2
        exit 1
      fi
      shift
      ;;
    --max-height)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "[ERROR] --max-height requires a value, e.g. --max-height 720" >&2
        exit 1
      fi
      MAX_HEIGHT_CLI="$2"
      shift 2
      ;;
    --max-height=*)
      MAX_HEIGHT_CLI="${1#*=}"
      if [[ -z "$MAX_HEIGHT_CLI" ]]; then
        echo "[ERROR] --max-height requires a value, e.g. --max-height=720" >&2
        exit 1
      fi
      shift
      ;;
    --audio)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "[ERROR] --audio requires a value: surround+stereo, surround, or stereo" >&2
        exit 1
      fi
      AUDIO_MODE_CLI="$2"
      shift 2
      ;;
    --audio=*)
      AUDIO_MODE_CLI="${1#*=}"
      if [[ -z "$AUDIO_MODE_CLI" ]]; then
        echo "[ERROR] --audio requires a value: surround+stereo, surround, or stereo" >&2
        exit 1
      fi
      shift
      ;;
    --quality-encode)
      QUALITY_ENCODE_CLI="1"
      shift
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

############################################
# Startup banner + basic env defaults
############################################
VERBOSE="${VERBOSE:-0}"                 # 1 = enable per-file set -x tracing
FFMPEG="${FFMPEG:-ffmpeg-git}"
FFPROBE="${FFPROBE:-ffprobe-git}"
JOBS="${JOBS:-3}"
OMDB_API_KEY="${OMDB_API_KEY:-68e81c13}"
OMDB_URL="${OMDB_URL:-https://www.omdbapi.com}"
OMDB_LOG="${OMDB_LOG:-omdb_tagging_log.csv}"
OMDB_LOG_LOCK="${OMDB_LOG_LOCK:-${OMDB_LOG}.lock}"
OMDB_INTERACTIVE="${OMDB_INTERACTIVE:-1}"
REPAIR_MODE="${REPAIR_MODE:-auto}"      # auto|always|never
SUBTITLE_MODE="${SUBTITLE_MODE:-burn}"  # burn|copy|extract
FAST_VIDEO_COPY="${FAST_VIDEO_COPY:-1}" # 1 = copy compatible H.264/HEVC video when possible
ALLOW_UNTAGGED_AUDIO_FALLBACK="${ALLOW_UNTAGGED_AUDIO_FALLBACK:-1}" # 1 = use default/untagged audio if no English tag exists
FIX_TIMESTAMPS="${FIX_TIMESTAMPS:-1}"
QSV_GLOBAL_QUALITY="${QSV_GLOBAL_QUALITY:-22}"
QSV_PRESET="${QSV_PRESET:-medium}"
X264_CRF="${X264_CRF:-20}"
X264_PRESET="${X264_PRESET:-veryfast}"
X264_THREADS="${X264_THREADS:-6}"
X265_CRF="${X265_CRF:-23}"
X265_PRESET="${X265_PRESET:-slow}"
USE_VBV="${USE_VBV:-1}"
VBV_MAXRATE="${VBV_MAXRATE:-25000}"
VBV_BUFSIZE="${VBV_BUFSIZE:-30000}"
AAC_STEREO_BR="${AAC_STEREO_BR:-192k}"
AC3_51_BR="${AC3_51_BR:-640k}"
TV_MAX_BYTES="${TV_MAX_BYTES:-1073741824}"  # 1 GiB default
MP4_TAG_HEADROOM_BYTES="${MP4_TAG_HEADROOM_BYTES:-16777216}"  # 16 MiB reserved for later MetaFetch tags
AUDIO_MODE="${AUDIO_MODE:-surround+stereo}" # surround+stereo|surround|stereo
QUALITY_ENCODE="${QUALITY_ENCODE:-0}"       # 1 = software libx265 instead of QSV/x264
MAX_HEIGHT="${MAX_HEIGHT:-0}"               # 0 = do not downscale
TARGET_SIZE_BYTES=""

[[ -n "$AUDIO_MODE_CLI" ]] && AUDIO_MODE="$AUDIO_MODE_CLI"
[[ -n "$QUALITY_ENCODE_CLI" ]] && QUALITY_ENCODE="$QUALITY_ENCODE_CLI"
[[ -n "$MAX_HEIGHT_CLI" ]] && MAX_HEIGHT="$MAX_HEIGHT_CLI"

if [[ -n "$TARGET_SIZE_SPEC" ]]; then
  if ! TARGET_SIZE_BYTES="$(parse_size_to_bytes "$TARGET_SIZE_SPEC")"; then
    echo "[ERROR] Invalid --target-size: ${TARGET_SIZE_SPEC} (examples: 2GB, 700MB, 1536M)" >&2
    exit 1
  fi
fi

TIMING_IN_FLAGS=()
TIMING_OUT_FLAGS=()
if [[ "$FIX_TIMESTAMPS" == "1" ]]; then
  TIMING_IN_FLAGS=(-fflags +genpts -avoid_negative_ts make_zero)
  TIMING_OUT_FLAGS=(-vsync vfr)
fi

case "$REPAIR_MODE" in
  auto|always|never) ;;
  *)
    echo "[ERROR] Invalid REPAIR_MODE: ${REPAIR_MODE} (expected auto|always|never)" >&2
    exit 1
    ;;
esac

case "$SUBTITLE_MODE" in
  burn|copy|extract) ;;
  *)
    echo "[ERROR] Invalid SUBTITLE_MODE: ${SUBTITLE_MODE} (expected burn|copy|extract)" >&2
    exit 1
    ;;
esac

case "$FAST_VIDEO_COPY" in
  0|1) ;;
  *)
    echo "[ERROR] Invalid FAST_VIDEO_COPY: ${FAST_VIDEO_COPY} (expected 0 or 1)" >&2
    exit 1
    ;;
esac

case "$ALLOW_UNTAGGED_AUDIO_FALLBACK" in
  0|1) ;;
  *)
    echo "[ERROR] Invalid ALLOW_UNTAGGED_AUDIO_FALLBACK: ${ALLOW_UNTAGGED_AUDIO_FALLBACK} (expected 0 or 1)" >&2
    exit 1
    ;;
esac

case "$AUDIO_MODE" in
  surround+stereo|surround|stereo) ;;
  *)
    echo "[ERROR] Invalid AUDIO_MODE: ${AUDIO_MODE} (expected surround+stereo, surround, or stereo)" >&2
    exit 1
    ;;
esac

case "$QUALITY_ENCODE" in
  0|1) ;;
  *)
    echo "[ERROR] Invalid QUALITY_ENCODE: ${QUALITY_ENCODE} (expected 0 or 1)" >&2
    exit 1
    ;;
esac

case "$MAX_HEIGHT" in
  ''|*[!0-9]*)
    echo "[ERROR] Invalid MAX_HEIGHT: ${MAX_HEIGHT} (expected non-negative integer pixels)" >&2
    exit 1
    ;;
esac

case "$TV_MAX_BYTES" in
  ''|*[!0-9]*)
    echo "[ERROR] Invalid TV_MAX_BYTES: ${TV_MAX_BYTES} (expected positive integer bytes)" >&2
    exit 1
    ;;
esac
if (( TV_MAX_BYTES <= 0 )); then
  echo "[ERROR] Invalid TV_MAX_BYTES: ${TV_MAX_BYTES} (expected positive integer bytes)" >&2
  exit 1
fi

case "$MP4_TAG_HEADROOM_BYTES" in
  ''|*[!0-9]*)
    echo "[ERROR] Invalid MP4_TAG_HEADROOM_BYTES: ${MP4_TAG_HEADROOM_BYTES} (expected non-negative integer bytes)" >&2
    exit 1
    ;;
esac

MP4_OUTPUT_FLAGS=()
if (( MP4_TAG_HEADROOM_BYTES > 0 )); then
  # -moov_size writes the MP4 movie header at the front and leaves free space after it.
  # MetaFetch can then grow title/artwork atoms later without rewriting the full media payload.
  MP4_OUTPUT_FLAGS=(-moov_size "$MP4_TAG_HEADROOM_BYTES")
else
  MP4_OUTPUT_FLAGS=(-movflags +faststart)
fi

############################################
# Hard-stop on Ctrl-C: kill entire process group
############################################
trap 'echo "[ABORT] Ctrl-C pressed — killing all jobs"; kill 0' SIGINT

############################################
# Input files (current dir) and banner
############################################
FILES=(./*.mkv ./*.MKV)
# Print startup banner and file count immediately
echo "========================================" >&2
echo "convert.sh — MKV → MP4 batch converter" >&2
echo "Found ${#FILES[@]} MKV file(s) in $(pwd)" >&2
echo "Parallel jobs: ${JOBS}  OMDb interactive: ${OMDB_INTERACTIVE}  VERBOSE: ${VERBOSE}" >&2
echo "Repair mode: ${REPAIR_MODE}  Subtitle mode: ${SUBTITLE_MODE}  Fast video copy: ${FAST_VIDEO_COPY}" >&2
echo "Allow untagged audio fallback: ${ALLOW_UNTAGGED_AUDIO_FALLBACK}  Audio mode: ${AUDIO_MODE}" >&2
echo "Quality encode: ${QUALITY_ENCODE}  Max height: ${MAX_HEIGHT}" >&2
if [[ -n "$TARGET_SIZE_BYTES" ]]; then
  echo "Target max bytes: ${TARGET_SIZE_BYTES} (from --target-size ${TARGET_SIZE_SPEC}; applies to all files)" >&2
fi
echo "TV max bytes: ${TV_MAX_BYTES}" >&2
echo "MP4 tag headroom: ${MP4_TAG_HEADROOM_BYTES} bytes" >&2
echo "========================================" >&2

[[ ${#FILES[@]} -eq 0 ]] && { echo "[INFO] No MKV files found; exiting." >&2; exit 0; }

############################################
# CSV helper
############################################
esc_csv() {
  local s="${1:-}"
  s="${s//\"/\"\"}"
  printf "\"%s\"" "$s"
}

############################################
# Filename helpers (sanitize/unique)
############################################
sanitize_filename() {
  local s="$1"
  s="${s//\//-}"
  s="${s//\\/ -}"
  s="${s//:/ -}"
  s="${s//\*/-}"
  s="${s//\?/ -}"
  s="${s//\"/-}"
  s="${s//</-}"
  s="${s//>/-}"
  s="${s//|/-}"
  s="$(echo "$s" | sed -E 's/[[:space:]]+/ /g; s/[-]{2,}/-/g')"
  s="$(echo "$s" | sed -E 's/^[[:space:]-]+|[[:space:]-]+$//g')"
  s="${s%%.}"
  echo "$s"
}

unique_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    printf "%s" "$path"
    return 0
  fi
  local base="${path%.*}"
  local ext="${path##*.}"
  local n=1
  while [[ -e "${base} (${n}).${ext}" ]]; do
    n=$((n+1))
  done
  printf "%s" "${base} (${n}).${ext}"
}

############################################
# Title/OMDb helpers (cleaning, detection)
############################################
clean_title() {
  local s="$1"
  s="$(echo "$s" | sed -E 's/[._-]+/ /g')"
  s="$(echo "$s" | sed -E '
    s/\b(480p|720p|1080p|2160p|4k|uhd|hdr|sdr|dolby|vision|dv)\b//Ig;
    s/\b(x264|x265|h264|h265|hevc|av1)\b//Ig;
    s/\b(10bit|8bit)\b//Ig;
    s/\b(web|webdl|web-dl|webrip|bluray|bdrip|brrip|dvdrip|hdtv)\b//Ig;
    s/\b(nf|amzn|dsnp|hulu|appletv|atvp)\b//Ig;
    s/\b(aac|ac3|eac3|dts|dtshd|truehd|atmos)\b//Ig;
    s/\b(5\.1|7\.1|2\.0)\b//Ig;
    s/\b(mkv|mp4)\b//Ig;
    s/\b(rarbg|yify|ion10|ntb|fgt)\b//Ig;
  ')"
  s="$(echo "$s" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+|[[:space:]]+$//g')"
  echo "$s"
}

parse_sxxexx() {
  local s="$1"
  s="$(echo "$s" | sed -E 's/[._-]+/ /g')"
  if [[ "$s" =~ ^(.*)[[:space:]]+[sS]([0-9]{1,2})[eE]([0-9]{1,2}).*$ ]]; then
    local series="${BASH_REMATCH[1]}"
    local season=$((10#${BASH_REMATCH[2]}))
    local episode=$((10#${BASH_REMATCH[3]}))
    series="$(echo "$series" | sed -E 's/[[:space:]]+$//')"
    printf "%s|%s|%s" "$series" "$season" "$episode"
    return 0
  fi
  return 1
}

detect_movie_year() {
  local s="$1"
  local norm y
  norm="$(echo "$s" | sed -E 's/[._]+/ /g')"
  y="$(echo "$norm" \
    | grep -oE '(^|[[:space:]\(\[\{<]|-)[[:space:]]*((19|20)[0-9]{2})[[:space:]]*($|[[:space:]\)\]\}>]|-)' \
    | grep -oE '(19|20)[0-9]{2}' \
    | tail -n1 || true)"
  [[ -n "$y" ]] && echo "$y"
}

strip_year_from_title() {
  local title="$1"
  local year="$2"
  [[ -z "$year" ]] && { echo "$title"; return 0; }
  local t="$title"
  t="$(echo "$t" | sed -E "s/[\(\[\{<][[:space:]]*${year}[[:space:]]*[\)\]\}>]//g")"
  t="$(echo "$t" | sed -E "s/(^|[[:space:]\-])${year}([[:space:]\-]|$)/ /g")"
  t="$(echo "$t" | sed -E "s/[[:space:]]+/ /g; s/^[[:space:]]+|[[:space:]]+$//g")"
  echo "$t"
}

detect_type_and_query() {
  local base="$1"
  local cleaned parsed series season episode year titleq
  cleaned="$(clean_title "$base")"
  if parsed="$(parse_sxxexx "$cleaned")"; then
    IFS='|' read -r series season episode <<< "$parsed"
    printf "tv|%s|%s|%s|%s|" "$cleaned" "$series" "$season" "$episode"
    return 0
  fi
  year="$(detect_movie_year "$cleaned" || true)"
  titleq="$(strip_year_from_title "$cleaned" "$year")"
  printf "movie|%s||||%s|%s" "$cleaned" "$titleq" "$year"
}

omdb_api_request() {
  command -v curl >/dev/null 2>&1 || return 1
  local endpoint="${OMDB_URL%/}/"
  local -a curl_args=(-sG --data-urlencode "apikey=${OMDB_API_KEY}")
  while (($#)); do
    curl_args+=(--data-urlencode "$1")
    shift
  done
  curl "${curl_args[@]}" "$endpoint"
}

############################################
# OMDb functions (lookup/search/fetch)
############################################
omdb_lookup() {
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local base="$1"
  local dtype cleaned series season episode titleq year json
  IFS='|' read -r dtype cleaned series season episode titleq year < <(detect_type_and_query "$base")
  if [[ "$dtype" == "tv" ]]; then
    json="$(omdb_api_request "t=${series}" "Season=${season}" "Episode=${episode}")"
    if [[ "$(echo "$json" | jq -r '.Response')" == "True" ]]; then
      echo "$json"
      return 0
    fi
  fi
  if [[ -n "${year:-}" ]]; then
    json="$(omdb_api_request "t=${titleq}" "y=${year}")"
    if [[ "$(echo "$json" | jq -r '.Response')" != "True" ]]; then
      json="$(omdb_api_request "t=${titleq}")"
    fi
  else
    json="$(omdb_api_request "t=${titleq}")"
  fi
  echo "$json"
}

omdb_search() {
  local query="$1"
  omdb_api_request "s=${query}"
}

omdb_fetch_by_id() {
  local imdbid="$1"
  omdb_api_request "i=${imdbid}"
}

omdb_prompt_read() {
  local prompt="$1" varname="$2"
  if [[ -t 0 ]]; then
    read -r -p "$prompt" "$varname"
    return $?
  fi

  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf "%s" "$prompt" > /dev/tty
    IFS= read -r "$varname" < /dev/tty
    return $?
  fi

  return 1
}

# Interactive verification and save chosen JSON to <inputbase>.omdb.json
omdb_interactive_verify_and_save() {
  local filepath="$1"
  local base="$(basename "$filepath" .mkv)"
  local outjson="${filepath%.*}.omdb.json"

  if [[ "${OMDB_INTERACTIVE:-1}" != "1" ]]; then
    echo "[OMDb] interactive verification disabled; using automatic lookup for ${filepath}" >&2
    omdb_lookup "$base" > "$outjson" 2>/dev/null || echo "{}" > "$outjson"
    return 0
  fi

  if [[ ! -t 0 && ! -r /dev/tty ]]; then
    echo "[OMDb] no interactive terminal available; using automatic lookup for ${filepath}" >&2
    omdb_lookup "$base" > "$outjson" 2>/dev/null || echo "{}" > "$outjson"
    return 0
  fi

  local json
  json="$(omdb_lookup "$base" 2>/dev/null || true)"
  local ok
  ok="$(echo "$json" | jq -r '.Response // "False"' 2>/dev/null || echo "False")"

  if [[ "$ok" == "True" ]]; then
    local title year typ imdbid plot
    title="$(echo "$json" | jq -r '.Title // ""')"
    year="$(echo "$json" | jq -r '.Year // ""')"
    typ="$(echo "$json" | jq -r '.Type // ""')"
    imdbid="$(echo "$json" | jq -r '.imdbID // ""')"
    plot="$(echo "$json" | jq -r '.Plot // ""')"

    echo
    echo "OMDb matched: $title ($year) [${typ}] imdb:$imdbid"
    if [[ -n "$plot" ]]; then
      echo "Plot: ${plot:0:200}"
    fi
    echo
    while true; do
      if ! omdb_prompt_read "Is this match correct? (y)es / (n)o / (s)earch alternatives / (k)skip: " ans; then
        echo "[OMDb] prompt unavailable; saving automatic match for ${filepath}" >&2
        printf "%s" "$json" > "$outjson"
        return 0
      fi
      case "${ans,,}" in
        y|yes)
          printf "%s" "$json" > "$outjson"
          echo "[OMDb] saved match to ${outjson}"
          return 0
          ;;
        n|no|s)
          break
          ;;
        k)
          echo "{}" > "$outjson"
          echo "[OMDb] skipped for ${filepath}"
          return 0
          ;;
        *)
          echo "Please answer y, n, s, or k."
          ;;
      esac
    done
  else
    echo
    echo "No direct OMDb match for '${base}'."
  fi

  local cleaned
  cleaned="$(clean_title "$base")"
  echo "Searching OMDb for alternatives using: '$cleaned' ..."
  local search_json
  search_json="$(omdb_search "$cleaned" 2>/dev/null || true)"
  local total
  total="$(echo "$search_json" | jq -r '.totalResults // 0' 2>/dev/null || echo 0)"
  if [[ "$total" == "0" ]]; then
    echo "No alternatives found."
    if [[ -n "$json" ]]; then
      printf "%s" "$json" > "$outjson"
    else
      echo "{}" > "$outjson"
    fi
    return 0
  fi

  echo
  echo "Alternatives:"
  echo "----------------------------------------"
  echo "$search_json" | jq -r '.Search[] | "\(.Title) | \(.Year) | \(.imdbID) | \(.Type)"' | nl -w2 -s'. ' | sed -n '1,8p'
  echo "----------------------------------------"
  echo "Enter number to select alternative, or '0' to cancel / keep original / skip."

  local choice
  while true; do
    if ! omdb_prompt_read "Choice [0-8]: " choice; then
      echo "[OMDb] prompt unavailable; keeping original/no selection for ${filepath}" >&2
      if [[ -n "$json" ]]; then
        printf "%s" "$json" > "$outjson"
      else
        echo "{}" > "$outjson"
      fi
      return 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if [[ "$choice" -eq 0 ]]; then
        if [[ -n "$json" ]]; then
          printf "%s" "$json" > "$outjson"
        else
          echo "{}" > "$outjson"
        fi
        echo "[OMDb] kept original/no selection for ${filepath}"
        return 0
      fi
      local selected_imdb
      selected_imdb="$(echo "$search_json" | jq -r ".Search[$((choice-1))].imdbID" 2>/dev/null || true)"
      if [[ -n "$selected_imdb" && "$selected_imdb" != "null" ]]; then
        local fulljson
        fulljson="$(omdb_fetch_by_id "$selected_imdb" 2>/dev/null || true)"
        if [[ -n "$fulljson" ]]; then
          printf "%s" "$fulljson" > "$outjson"
          echo "[OMDb] saved selected alternative to ${outjson}"
          return 0
        else
          echo "Failed to fetch details for imdbID ${selected_imdb}."
          echo "Try another number or 0 to cancel."
        fi
      else
        echo "Invalid selection. Choose a number shown in the list or 0 to cancel."
      fi
    else
      echo "Please enter a numeric choice."
    fi
  done
}

############################################
# Subtitle helpers
############################################
pick_forced_sub_pos() {
  "$FFPROBE" -v error -select_streams s \
    -show_entries stream_disposition=forced:stream_tags=language \
    -of csv=p=0 "$1" | awk -F',' '
      BEGIN { pos=0; best=-1; fallback=-1 }
      {
        forced=$1;
        lang=tolower($2);
        if (forced==1 && lang=="eng" && best==-1) best=pos;
        if (forced==1 && fallback==-1) fallback=pos;
        pos++;
      }
      END {
        if (best!=-1) print best;
        else if (fallback!=-1) print fallback;
      }'
}

has_forced_subs() {
  [[ -n "$(pick_forced_sub_pos "$1")" ]]
}

pick_forced_eng_sub_pos() {
  "$FFPROBE" -v error -select_streams s \
    -show_entries stream_disposition=forced:stream_tags=language \
    -of csv=p=0 "$1" | awk -F',' '
      BEGIN { pos=0; best=-1 }
      {
        forced=$1;
        lang=tolower($2);
        if (forced==1 && lang=="eng" && best==-1) best=pos;
        pos++;
      }
      END { if (best!=-1) print best; }'
}

has_forced_eng_subs() {
  [[ -n "$(pick_forced_eng_sub_pos "$1")" ]]
}

print_forced_sub_status() {
  local file="$1"
  if has_forced_eng_subs "$file"; then
    echo "[INFO ] Forced English Subtitles = True" >&2
  else
    echo "[INFO ] Forced English Subtitles = False" >&2
  fi
}

############################################
# Repair
############################################
repair_mkv() {
  local in="$1" out="$2"
  if command -v mkvmerge >/dev/null 2>&1; then
    mkvmerge -o "$out" "$in" >/dev/null 2>&1 && return 0
  fi
  "$FFMPEG" -y -fflags +discardcorrupt -err_detect ignore_err \
    -i "$in" -map 0 -c copy "$out" >/dev/null 2>&1
}

############################################
# Audio selection + Apple TV policy
############################################
pick_best_eng_audio_stream_index() {
  "$FFPROBE" -v error -select_streams a \
    -show_entries stream=index,codec_name,channels:stream_tags=language \
    -of csv=p=0 "$1" | awk -F',' '
      BEGIN { best_idx=""; best_ch=-1 }
      {
        idx=$1; codec=$2; ch=$3; lang=tolower($4);
        if (lang=="eng" || lang=="en" || lang=="english" || lang ~ /^eng[-_]/ || lang ~ /^en[-_]/) {
          if (ch+0 > best_ch) { best_ch=ch+0; best_idx=idx; }
        }
      }
      END { if (best_idx!="") print best_idx }'
}

pick_best_untagged_audio_stream_index() {
  "$FFPROBE" -v error -select_streams a \
    -show_entries stream=index,channels:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$1" | awk -F',' '
      BEGIN { best_default_idx=""; best_default_ch=-1; best_blank_idx=""; best_blank_ch=-1 }
      {
        idx=$1; ch=$2+0; def=$3+0; lang=tolower($4);
        if (lang=="") {
          if (def==1 && ch > best_default_ch) { best_default_ch=ch; best_default_idx=idx; }
          if (ch > best_blank_ch) { best_blank_ch=ch; best_blank_idx=idx; }
        }
      }
      END {
        if (best_default_idx!="") print best_default_idx;
        else if (best_blank_idx!="") print best_blank_idx;
      }'
}

pick_audio_stream_index() {
  local file="$1"
  local eng_idx=""
  eng_idx="$(pick_best_eng_audio_stream_index "$file")"
  if [[ -n "$eng_idx" ]]; then
    printf "%s|english" "$eng_idx"
    return 0
  fi

  if [[ "$ALLOW_UNTAGGED_AUDIO_FALLBACK" == "1" ]]; then
    local fallback_idx=""
    fallback_idx="$(pick_best_untagged_audio_stream_index "$file")"
    if [[ -n "$fallback_idx" ]]; then
      printf "%s|untagged" "$fallback_idx"
      return 0
    fi
  fi

  return 1
}

get_audio_stream_language() {
  local file="$1" stream_index="$2"
  "$FFPROBE" -v error \
    -select_streams a \
    -show_entries stream=index:stream_tags=language \
    -of csv=p=0 "$file" | awk -F',' -v idx="$stream_index" '
      $1==idx { print tolower($2); exit }'
}

get_audio_codec_and_channels() {
  local file="$1" stream_index="$2"
  "$FFPROBE" -v error \
    -select_streams a \
    -show_entries stream=index,codec_name,channels \
    -of csv=p=0 "$file" | awk -F',' -v idx="$stream_index" '
      $1==idx { print $2 "," $3; exit }'
}

build_audio_args_with_stereo_fallback() {
  local astream_idx="$1" acodec="$2" ach="$3"
  local -a args=()
  args+=(-map "0:${astream_idx}")
  if [[ "$AUDIO_MODE" == "stereo" || "$ach" -lt 6 ]]; then
    args+=(-c:a:0 aac -b:a:0 "$AAC_STEREO_BR" -ac:a:0 2 -disposition:a:0 default)
    args+=(-metadata:s:a:0 title="English Stereo")
    args+=(-metadata:s:a:0 language=eng)
  elif [[ "$AUDIO_MODE" == "surround" ]]; then
    if [[ -z "${TARGET_SIZE_BYTES:-}" && ( "$acodec" == "eac3" || "$acodec" == "ac3" ) ]]; then
      args+=(-c:a:0 copy)
    else
      args+=(-c:a:0 ac3 -b:a:0 "$AC3_51_BR" -ac:a:0 6 -channel_layout:a:0 5.1)
    fi
    args+=(-disposition:a:0 default)
    args+=(-metadata:s:a:0 title="English 5.1")
    args+=(-metadata:s:a:0 language=eng)
  else
    if [[ -z "${TARGET_SIZE_BYTES:-}" && ( "$acodec" == "eac3" || "$acodec" == "ac3" ) ]]; then
      args+=(-c:a:0 copy)
    else
      args+=(-c:a:0 ac3 -b:a:0 "$AC3_51_BR" -ac:a:0 6 -channel_layout:a:0 5.1)
    fi
    args+=(-map "0:${astream_idx}" -c:a:1 aac -b:a:1 "$AAC_STEREO_BR" -ac:a:1 2)
    args+=(-disposition:a:0 default -disposition:a:1 0)
    args+=(-metadata:s:a:0 title="English 5.1" -metadata:s:a:1 title="English Stereo")
    args+=(-metadata:s:a:0 language=eng -metadata:s:a:1 language=eng)
  fi
  printf '%s\n' "${args[@]}"
}

audio_total_kbps_for_budget() {
  local ach="$1" ac3_kbps aac_kbps
  ac3_kbps="${AC3_51_BR%k}"
  aac_kbps="${AAC_STEREO_BR%k}"

  if [[ "$AUDIO_MODE" == "stereo" || "$ach" -lt 6 ]]; then
    printf "%s" "$aac_kbps"
  elif [[ "$AUDIO_MODE" == "surround" ]]; then
    printf "%s" "$ac3_kbps"
  else
    printf "%s" $((ac3_kbps + aac_kbps))
  fi
}

x264_extra_args() {
  local -a x=()
  if [[ "$X264_THREADS" != "0" ]]; then
    x+=(-threads "$X264_THREADS")
  fi
  if [[ "$USE_VBV" == "1" ]]; then
    x+=(-x264-params "vbv-maxrate=${VBV_MAXRATE}:vbv-bufsize=${VBV_BUFSIZE}")
  fi
  printf '%s\n' "${x[@]}"
}

get_video_codec_name() {
  "$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of csv=p=0 "$1" | head -n1
}

video_codec_can_copy_to_mp4() {
  local codec="$1"
  [[ "$codec" == "h264" || "$codec" == "hevc" ]]
}

get_subtitle_codec_by_pos() {
  local file="$1" subpos="$2"
  "$FFPROBE" -v error -select_streams s \
    -show_entries stream=codec_name \
    -of csv=p=0 "$file" | awk -v pos="$subpos" 'NR-1==pos { print; exit }'
}

subtitle_codec_supports_mov_text() {
  local codec="$1"
  case "$codec" in
    mov_text|subrip|ass|ssa|webvtt)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

file_size_bytes() {
  local path="$1"
  stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null
}

target_payload_budget_bytes() {
  local budget="$1"
  if (( MP4_TAG_HEADROOM_BYTES > 0 && budget > MP4_TAG_HEADROOM_BYTES )); then
    budget=$((budget - MP4_TAG_HEADROOM_BYTES))
  fi
  printf "%s" "$budget"
}

target_max_bytes_for_type() {
  local detected_type="$1"
  if [[ -n "${TARGET_SIZE_BYTES:-}" ]]; then
    printf "%s" "$TARGET_SIZE_BYTES"
  elif [[ "$detected_type" == "tv" ]]; then
    printf "%s" "$TV_MAX_BYTES"
  fi
}

tv_payload_budget_bytes() {
  target_payload_budget_bytes "$TV_MAX_BYTES"
}

build_video_filter_arg() {
  local src="$1" subtitle_action="$2" forced_sub_pos="$3"
  local -a filters=()

  if (( MAX_HEIGHT > 0 )); then
    filters+=("scale=-2:'min(${MAX_HEIGHT},ih)'")
  fi

  if [[ "$subtitle_action" == "burn" ]]; then
    local subfile_esc
    subfile_esc="$(ffmpeg_subtitles_filter_escape "$src")"
    filters+=("subtitles='${subfile_esc}':si=${forced_sub_pos}")
  fi

  local IFS=,
  printf "%s" "${filters[*]}"
}

can_use_fast_video_copy() {
  local file="$1" detected_type="$2" video_codec="$3" subtitle_action="$4"
  [[ "$FAST_VIDEO_COPY" == "1" ]] || return 1
  [[ "$subtitle_action" != "burn" ]] || return 1
  [[ "$QUALITY_ENCODE" != "1" ]] || return 1
  (( MAX_HEIGHT == 0 )) || return 1
  video_codec_can_copy_to_mp4 "$video_codec" || return 1

  local target_max_bytes
  target_max_bytes="$(target_max_bytes_for_type "$detected_type")"
  if [[ -n "$target_max_bytes" ]]; then
    local source_size source_budget
    source_size="$(file_size_bytes "$file" 2>/dev/null || true)"
    source_budget="$(target_payload_budget_bytes "$target_max_bytes")"
    [[ -n "$source_size" ]] || return 1
    [[ "$source_size" -le "$source_budget" ]] || return 1
  fi

  return 0
}

extract_forced_eng_subtitle() {
  local file="$1" subpos="$2" subcodec="$3" out_mp4="$4"
  [[ -n "$subpos" ]] || return 0

  local sidecar codec_arg ext
  case "$subcodec" in
    mov_text|subrip)
      ext="srt"
      codec_arg="srt"
      ;;
    webvtt)
      ext="vtt"
      codec_arg="webvtt"
      ;;
    ass|ssa)
      ext="ass"
      codec_arg="ass"
      ;;
    *)
      ext="mks"
      codec_arg="copy"
      ;;
  esac

  sidecar="$(unique_path "${out_mp4%.*}.en.forced.${ext}")"
  echo "[SUBS ] Extracting forced English subtitle to $(basename "$sidecar")" >&2

  if [[ "$codec_arg" == "copy" ]]; then
    "$FFMPEG" -y -v warning \
      -i "$file" \
      -map "0:s:${subpos}" \
      -map_metadata -1 \
      -c:s copy \
      "$sidecar" >/dev/null 2>&1
  else
    "$FFMPEG" -y -v warning \
      -i "$file" \
      -map "0:s:${subpos}" \
      -map_metadata -1 \
      -c:s "$codec_arg" \
      "$sidecar" >/dev/null 2>&1
  fi
}

log_has_non_monotonic_dts() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  if command -v rg >/dev/null 2>&1; then
    rg -q 'Non-monotonic DTS' "$log_file"
  else
    grep -q 'Non-monotonic DTS' "$log_file"
  fi
}

convert_from_source() {
  local src="$1" out="$2" detected_type="$3" original_in="$4"
  local astream_idx acodec ach video_codec selected_audio_kind audio_lang
  local forced_eng_sub_pos="" subtitle_codec="" subtitle_action="none"
  local VIDEO_BITRATE="" encode_ok=0
  local -a audio_args=() x264_extras=() subtitle_args=() video_copy_args=() vf_args=()
  local vf_arg duration target_bps audio_total_kbps audio_total_bps video_bps video_kbps final_size
  local size_cap_bytes size_cap_label
  local fast_copy_log="" fast_copy_had_dts=0

  IFS='|' read -r astream_idx selected_audio_kind <<< "$(pick_audio_stream_index "$src" || true)"
  if [[ -z "$astream_idx" ]]; then
    echo "[FAIL ] no English audio stream found and no untagged fallback was eligible: $original_in" >&2
    return 20
  fi

  IFS=',' read -r acodec ach <<< "$(get_audio_codec_and_channels "$src" "$astream_idx")"
  audio_lang="$(get_audio_stream_language "$src" "$astream_idx" || true)"
  mapfile -t audio_args < <(build_audio_args_with_stereo_fallback "$astream_idx" "$acodec" "$ach")
  mapfile -t x264_extras < <(x264_extra_args)
  video_codec="$(get_video_codec_name "$src")"

  if [[ "$selected_audio_kind" == "untagged" ]]; then
    echo "[WARN ] No audio track was tagged English; using untagged/default audio stream 0:${astream_idx}" >&2
  fi

  if [[ -n "$audio_lang" ]]; then
    echo "[AUDIO] mode=${AUDIO_MODE} primary=0:${astream_idx} codec=${acodec} ch=${ach} lang=${audio_lang}" >&2
  else
    echo "[AUDIO] mode=${AUDIO_MODE} primary=0:${astream_idx} codec=${acodec} ch=${ach} lang=untagged" >&2
  fi
  [[ -n "$video_codec" ]] && echo "[VIDEO] source codec=${video_codec}" >&2

  forced_eng_sub_pos="$(pick_forced_eng_sub_pos "$src" || true)"
  if [[ -n "$forced_eng_sub_pos" ]]; then
    subtitle_codec="$(get_subtitle_codec_by_pos "$src" "$forced_eng_sub_pos")"
    case "$SUBTITLE_MODE" in
      burn)
        subtitle_action="burn"
        ;;
      copy)
        if subtitle_codec_supports_mov_text "$subtitle_codec"; then
          subtitle_action="copy"
          subtitle_args=(-map "0:s:${forced_eng_sub_pos}" -c:s mov_text -metadata:s:s:0 language=eng -disposition:s:0 forced)
        else
          subtitle_action="extract"
          echo "[WARN ] Forced English subtitle codec '${subtitle_codec:-unknown}' is not MP4 text-compatible; extracting a sidecar instead." >&2
        fi
        ;;
      extract)
        subtitle_action="extract"
        ;;
    esac
  fi

  case "$subtitle_action" in
    burn)
      echo "[SUBS ] Forced English subtitles -> burn into video" >&2
      ;;
    copy)
      echo "[SUBS ] Forced English subtitles -> keep in MP4 as mov_text" >&2
      ;;
    extract)
      echo "[SUBS ] Forced English subtitles -> extract sidecar after conversion" >&2
      ;;
    none)
      echo "[SUBS ] No forced English subtitles kept" >&2
      ;;
  esac

  vf_arg="$(build_video_filter_arg "$src" "$subtitle_action" "$forced_eng_sub_pos")"
  if [[ -n "$vf_arg" ]]; then
    vf_args=(-vf "$vf_arg")
    echo "[VIDEO] filter=${vf_arg}" >&2
  fi

  if can_use_fast_video_copy "$src" "$detected_type" "$video_codec" "$subtitle_action"; then
    echo "[FAST ] Compatible ${video_codec} video -> MP4 copy path" >&2
    video_copy_args=(-c:v copy)
    [[ "$video_codec" == "hevc" ]] && video_copy_args+=(-tag:v hvc1)

    fast_copy_log="$(mktemp /tmp/convert-fast-copy.XXXXXX.log 2>/dev/null || true)"
    if [[ -n "$fast_copy_log" ]]; then
      if "$FFMPEG" -y -stats \
          "${TIMING_IN_FLAGS[@]}" \
          -i "$src" \
          "${TIMING_OUT_FLAGS[@]}" \
          -map 0:v:0 \
          -copytb 1 \
          "${audio_args[@]}" \
          "${subtitle_args[@]}" \
          "${video_copy_args[@]}" \
          "${MP4_OUTPUT_FLAGS[@]}" "$out" 2> >(tee "$fast_copy_log" >&2); then
        if log_has_non_monotonic_dts "$fast_copy_log"; then
          fast_copy_had_dts=1
        fi
      fi
      rm -f "$fast_copy_log"
    elif "$FFMPEG" -y -stats \
        "${TIMING_IN_FLAGS[@]}" \
        -i "$src" \
        "${TIMING_OUT_FLAGS[@]}" \
        -map 0:v:0 \
        -copytb 1 \
        "${audio_args[@]}" \
        "${subtitle_args[@]}" \
        "${video_copy_args[@]}" \
        "${MP4_OUTPUT_FLAGS[@]}" "$out"; then
      fast_copy_had_dts=0
    fi

    if [[ -s "$out" && "$fast_copy_had_dts" -eq 0 ]]; then
      if [[ "$subtitle_action" == "extract" ]]; then
        extract_forced_eng_subtitle "$src" "$forced_eng_sub_pos" "$subtitle_codec" "$out" || \
          echo "[WARN ] Failed to extract forced English subtitle sidecar" >&2
      fi
      return 0
    fi

    rm -f "$out"
    if [[ "$fast_copy_had_dts" -eq 1 ]]; then
      if [[ "$REPAIR_MODE" != "never" && "$src" == "$original_in" ]]; then
        echo "[WARN ] Fast video copy produced non-monotonic DTS; retrying with repaired MKV" >&2
        return 11
      fi
      echo "[WARN ] Fast video copy produced non-monotonic DTS; falling back to encode path" >&2
    else
      echo "[WARN ] Fast video copy failed; falling back to encode path" >&2
    fi
  fi

  size_cap_bytes="$(target_max_bytes_for_type "$detected_type")"
  if [[ -n "$size_cap_bytes" ]]; then
    duration="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null || echo "")"
    if [[ -n "$duration" ]]; then
      if awk "BEGIN{exit !($duration > 0)}"; then
        local target_payload_bytes
        target_payload_bytes="$(target_payload_budget_bytes "$size_cap_bytes")"
        target_bps="$(awk -v bytes="$target_payload_bytes" -v dur="$duration" 'BEGIN{printf "%.0f", (bytes*8)/dur}')"
        audio_total_kbps="$(audio_total_kbps_for_budget "$ach")"
        audio_total_bps=$((audio_total_kbps * 1000))
        video_bps="$(awk -v t="$target_bps" -v a="$audio_total_bps" 'BEGIN{v=t-a; if(v<100000) v=100000; printf "%.0f", v}')"
        video_kbps=$(( (video_bps + 500) / 1000 ))
        if [[ "$video_kbps" -lt 200 ]]; then
          video_kbps=200
        fi
        VIDEO_BITRATE="${video_kbps}k"
        if [[ -n "${TARGET_SIZE_BYTES:-}" ]]; then
          size_cap_label="requested target"
        else
          size_cap_label="TV episode target"
        fi
        echo "[SIZE ] ${size_cap_label}: max size=${size_cap_bytes} bytes; tag headroom=${MP4_TAG_HEADROOM_BYTES}; media budget=${target_payload_bytes}; audio budget=${audio_total_kbps}k; duration=${duration}s; video bitrate=${VIDEO_BITRATE}" >&2
      else
        echo "[WARN ] Could not parse duration for size calc; skipping size cap" >&2
      fi
    else
      echo "[WARN ] No duration found; skipping size cap" >&2
    fi
  fi

  if [[ "$QUALITY_ENCODE" == "1" ]]; then
    echo "[X265 ] Quality encode -> software HEVC (${X265_PRESET})" >&2
    if [[ -n "$VIDEO_BITRATE" ]]; then
      if "$FFMPEG" -y -stats \
          "${TIMING_IN_FLAGS[@]}" \
          -i "$src" \
          "${TIMING_OUT_FLAGS[@]}" \
          -map 0:v:0 \
          "${audio_args[@]}" \
          "${subtitle_args[@]}" \
          "${vf_args[@]}" \
          -c:v libx265 -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize "${VBV_BUFSIZE}k" -preset "$X265_PRESET" -tag:v hvc1 \
          "${MP4_OUTPUT_FLAGS[@]}" "$out"; then
        encode_ok=1
      else
        echo "[WARN ] Quality encode failed; falling back to standard encoder path" >&2
      fi
    else
      if "$FFMPEG" -y -stats \
          "${TIMING_IN_FLAGS[@]}" \
          -i "$src" \
          "${TIMING_OUT_FLAGS[@]}" \
          -map 0:v:0 \
          "${audio_args[@]}" \
          "${subtitle_args[@]}" \
          "${vf_args[@]}" \
          -c:v libx265 -crf "$X265_CRF" -preset "$X265_PRESET" -tag:v hvc1 \
          "${MP4_OUTPUT_FLAGS[@]}" "$out"; then
        encode_ok=1
      else
        echo "[WARN ] Quality encode failed; falling back to standard encoder path" >&2
      fi
    fi
  fi

  if [[ "$encode_ok" -ne 1 && "$subtitle_action" == "burn" ]]; then
    echo "[CPU  ] Forced English subs -> burn-in (x264)" >&2
    if [[ -n "$VIDEO_BITRATE" ]]; then
      if "$FFMPEG" -y -stats \
          "${TIMING_IN_FLAGS[@]}" \
          -i "$src" \
          "${TIMING_OUT_FLAGS[@]}" \
          -map 0:v:0 \
          "${audio_args[@]}" \
          "${vf_args[@]}" \
          -c:v libx264 -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize "${VBV_BUFSIZE}k" -preset "$X264_PRESET" \
          "${x264_extras[@]}" \
          "${MP4_OUTPUT_FLAGS[@]}" "$out"; then
        encode_ok=1
      fi
    else
      if "$FFMPEG" -y -stats \
          "${TIMING_IN_FLAGS[@]}" \
          -i "$src" \
          "${TIMING_OUT_FLAGS[@]}" \
          -map 0:v:0 \
          "${audio_args[@]}" \
          "${vf_args[@]}" \
          -c:v libx264 -crf "$X264_CRF" -preset "$X264_PRESET" \
          "${x264_extras[@]}" \
          "${MP4_OUTPUT_FLAGS[@]}" "$out"; then
        encode_ok=1
      fi
    fi
  elif [[ "$encode_ok" -ne 1 ]]; then
    echo "[QSV  ] No forced-English burn -> HEVC QSV" >&2
    if [[ -n "$VIDEO_BITRATE" ]]; then
      if "$FFMPEG" -y -stats \
          "${TIMING_IN_FLAGS[@]}" \
          -i "$src" \
          "${TIMING_OUT_FLAGS[@]}" \
          -map 0:v:0 \
          "${audio_args[@]}" \
          "${subtitle_args[@]}" \
          "${vf_args[@]}" \
          -c:v hevc_qsv -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -preset "$QSV_PRESET" -tag:v hvc1 \
          "${MP4_OUTPUT_FLAGS[@]}" "$out"; then
        encode_ok=1
      else
        echo "[WARN ] QSV failed -> CPU fallback (x264 with bitrate cap)" >&2
        if "$FFMPEG" -y -stats \
            "${TIMING_IN_FLAGS[@]}" \
            -i "$src" \
            "${TIMING_OUT_FLAGS[@]}" \
            -map 0:v:0 \
            "${audio_args[@]}" \
            "${subtitle_args[@]}" \
            "${vf_args[@]}" \
            -c:v libx264 -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize "${VBV_BUFSIZE}k" -preset "$X264_PRESET" \
            "${x264_extras[@]}" \
            "${MP4_OUTPUT_FLAGS[@]}" "$out"; then
          encode_ok=1
        fi
      fi
    else
      if "$FFMPEG" -y -stats \
          "${TIMING_IN_FLAGS[@]}" \
          -i "$src" \
          "${TIMING_OUT_FLAGS[@]}" \
          -map 0:v:0 \
          "${audio_args[@]}" \
          "${subtitle_args[@]}" \
          "${vf_args[@]}" \
          -c:v hevc_qsv -global_quality "$QSV_GLOBAL_QUALITY" -preset "$QSV_PRESET" -tag:v hvc1 \
          "${MP4_OUTPUT_FLAGS[@]}" "$out"; then
        encode_ok=1
      else
        echo "[WARN ] QSV failed -> CPU fallback (x264)" >&2
        if "$FFMPEG" -y -stats \
            "${TIMING_IN_FLAGS[@]}" \
            -i "$src" \
            "${TIMING_OUT_FLAGS[@]}" \
            -map 0:v:0 \
            "${audio_args[@]}" \
            "${subtitle_args[@]}" \
            "${vf_args[@]}" \
            -c:v libx264 -crf "$X264_CRF" -preset "$X264_PRESET" \
            "${x264_extras[@]}" \
            "${MP4_OUTPUT_FLAGS[@]}" "$out"; then
          encode_ok=1
        fi
      fi
    fi
  fi

  if [[ "$encode_ok" -ne 1 ]]; then
    rm -f "$out"
    return 10
  fi

  if [[ "$subtitle_action" == "extract" ]]; then
    extract_forced_eng_subtitle "$src" "$forced_eng_sub_pos" "$subtitle_codec" "$out" || \
      echo "[WARN ] Failed to extract forced English subtitle sidecar" >&2
  fi

  if [[ -n "$size_cap_bytes" && -n "$VIDEO_BITRATE" ]]; then
    final_size="$(file_size_bytes "$out" 2>/dev/null || echo 0)"
    if [[ -n "$final_size" && "$final_size" -gt "$size_cap_bytes" ]]; then
      echo "[WARN ] Final file exceeds ${size_cap_bytes} bytes: ${final_size} bytes" >&2
    fi
  fi

  return 0
}

copy_omdb_sidecar_for_output() {
  local prejson="$1"
  local outpath="$2"
  [[ -f "$prejson" ]] || return 0
  local target_json="${outpath%.*}.omdb.json"
  [[ "$prejson" == "$target_json" ]] && return 0
  cp -f "$prejson" "$target_json" 2>/dev/null || true
}

ffmpeg_subtitles_filter_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//:/\\:}"
  s="${s//\'/\\\'}"
  s="${s//[/\\[}"
  s="${s//]/\\]}"
  s="${s//,/\\,}"
  s="${s//;/\\;}"
  printf "%s" "$s"
}

############################################
# OMDb logging and tagging (uses pre-fetched .omdb.json if present)
############################################
ensure_omdb_log_header() {
  if [[ ! -f "$OMDB_LOG" ]]; then
    echo "file,matched,type,title,year,imdbID,season,episode,poster_url,notes" > "$OMDB_LOG"
  fi
}

append_omdb_log_line() {
  local line="$1"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 9
      ensure_omdb_log_header
      printf "%s\n" "$line" >> "$OMDB_LOG"
    ) 9>>"$OMDB_LOG_LOCK"
  else
    ensure_omdb_log_header
    printf "%s\n" "$line" >> "$OMDB_LOG"
  fi
}

log_omdb() {
  local file="$1" matched="$2" type="$3" title="$4" year="$5" imdbid="$6" season="$7" episode="$8" poster="$9" notes="${10:-}"
  local line
  printf -v line "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s" \
    "$(esc_csv "$file")" "$(esc_csv "$matched")" "$(esc_csv "$type")" "$(esc_csv "$title")" "$(esc_csv "$year")" "$(esc_csv "$imdbid")" \
    "$(esc_csv "$season")" "$(esc_csv "$episode")" "$(esc_csv "$poster")" "$(esc_csv "$notes")"

  append_omdb_log_line "$line"
}

ffmpeg_embed_cover_and_basic_tags() {
  local mp4="$1"
  local cover_jpg="$2"
  local title="$3"
  local desc="$4"
  local year="$5"
  local tmp="${mp4%.mp4}.tagtmp.mp4"
  "$FFMPEG" -y -v warning \
    -i "$mp4" -i "$cover_jpg" \
    -map 0 -map 1:0 \
    -c copy \
    -disposition:v:1 attached_pic \
    -metadata title="$title" \
    -metadata comment="$desc" \
    -metadata date="$year" \
    "${MP4_OUTPUT_FLAGS[@]}" \
    "$tmp" && mv -f "$tmp" "$mp4"
}

tag_plex_omdb_always() {
  local mp4="$1"
  local base="$(basename "$mp4" .mp4)"
  local prejson="${mp4%.*}.omdb.json"
  local json=""
  if [[ -f "$prejson" ]]; then
    json="$(cat "$prejson" 2>/dev/null || true)"
  else
    json="$(omdb_lookup "$base" 2>/dev/null || true)"
  fi

  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    log_omdb "$mp4" "no" "" "" "" "" "" "" "" "curl/jq missing; skipped lookup/tagging"
    return 0
  fi

  local ok
  ok="$(echo "$json" | jq -r '.Response // "False"' 2>/dev/null || echo "False")"
  if [[ "$ok" != "True" ]]; then
    log_omdb "$mp4" "no" "" "" "" "" "" "" "" "OMDb no match"
    return 0
  fi

  local title plot poster year omdb_type imdbid season episode series_name
  title="$(echo "$json" | jq -r '.Title // ""')"
  plot="$(echo "$json" | jq -r '.Plot // ""')"
  poster="$(echo "$json" | jq -r '.Poster // ""')"
  year="$(echo "$json" | jq -r '.Year // ""')"
  omdb_type="$(echo "$json" | jq -r '.Type // ""')"
  imdbid="$(echo "$json" | jq -r '.imdbID // ""')"
  season="$(echo "$json" | jq -r '.Season // ""')"
  episode="$(echo "$json" | jq -r '.Episode // ""')"
  series_name="$(echo "$json" | jq -r '.Series // ""')"

  [[ "$title" == "N/A" ]] && title=""
  [[ "$plot" == "N/A" ]] && plot=""
  [[ "$poster" == "N/A" ]] && poster=""
  [[ "$year" == "N/A" ]] && year=""
  [[ "$imdbid" == "N/A" ]] && imdbid=""
  [[ "$season" == "N/A" ]] && season=""
  [[ "$episode" == "N/A" ]] && episode=""
  [[ "$series_name" == "N/A" ]] && series_name=""

  local desc="$plot"
  [[ -n "$year" ]] && desc="${desc}\n\nYear: ${year}"
  [[ -n "$imdbid" ]] && desc="${desc}\nIMDb: ${imdbid}"

  local art=""
  if [[ -n "$poster" ]]; then
    art="$(mktemp /tmp/omdb_artXXXX.jpg)"
    if ! download_poster "$poster" "$art"; then
      rm -f "$art"
      art=""
    fi
  fi

  log_omdb "$mp4" "yes" "$omdb_type" "$title" "$year" "$imdbid" "$season" "$episode" "$poster" "matched"

  if command -v AtomicParsley >/dev/null 2>&1; then
    if [[ "$omdb_type" == "episode" ]]; then
      if [[ -n "$art" ]]; then
        AtomicParsley "$mp4" \
          --title "$title" \
          --description "$desc" \
          --TVShowName "$series_name" \
          --TVSeasonNum "$season" \
          --TVEpisodeNum "$episode" \
          --stik "TV Show" \
          --artwork "$art" \
          --overWrite >/dev/null 2>&1 || true
      else
        AtomicParsley "$mp4" \
          --title "$title" \
          --description "$desc" \
          --TVShowName "$series_name" \
          --TVSeasonNum "$season" \
          --TVEpisodeNum "$episode" \
          --stik "TV Show" \
          --overWrite >/dev/null 2>&1 || true
      fi
    else
      if [[ -n "$art" ]]; then
        AtomicParsley "$mp4" \
          --title "$title" \
          --description "$desc" \
          --year "$year" \
          --stik "Movie" \
          --artwork "$art" \
          --overWrite >/dev/null 2>&1 || true
      else
        AtomicParsley "$mp4" \
          --title "$title" \
          --description "$desc" \
          --year "$year" \
          --stik "Movie" \
          --overWrite >/dev/null 2>&1 || true
      fi
    fi
  else
    if [[ -n "$art" ]]; then
      ffmpeg_embed_cover_and_basic_tags "$mp4" "$art" "$title" "$desc" "$year" || true
    fi
  fi

  [[ -n "$art" ]] && rm -f "$art" || true
}

download_poster() {
  local url="$1"
  local outjpg="$2"
  command -v curl >/dev/null 2>&1 || return 1
  [[ -z "$url" || "$url" == "N/A" ]] && return 1
  curl -sL "$url" -o "$outjpg" || return 1
  [[ -s "$outjpg" ]] || return 1
  return 0
}

############################################
# Pre-flight checks
############################################
if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "[ERROR] ffmpeg not found: $FFMPEG (set FFMPEG=ffmpeg or install ffmpeg-git)" >&2
  exit 1
fi
if ! command -v "$FFPROBE" >/dev/null 2>&1; then
  echo "[ERROR] ffprobe not found: $FFPROBE (set FFPROBE=ffprobe or install ffprobe-git)" >&2
  exit 1
fi

############################################
# Mode: subtitle scan only
############################################
if [[ "${MODE}" == "subs_only" ]]; then
  echo "========================================" >&2
  echo "Forced subtitle scan (English forced flag)" >&2
  echo "Found ${#FILES[@]} MKV file(s) in $(pwd)" >&2
  echo "========================================" >&2
  for f in "${FILES[@]}"; do
    if has_forced_eng_subs "$f"; then
      echo "$(basename "$f"): Forced English Subtitles = True" >&2
    else
      echo "$(basename "$f"): Forced English Subtitles = False" >&2
    fi
  done
  exit 0
fi

############################################
# Pre-fetch / interactive OMDb verification (runs in main thread)
############################################
for f in "${FILES[@]}"; do
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    omdb_interactive_verify_and_save "$f"
  else
    echo "[OMDb] curl or jq missing; skipping interactive metadata lookup for ${f}" >&2
    echo "{}" > "${f%.*}.omdb.json"
  fi
done

############################################
# Worker: process_one (per-file tracing controlled here)
############################################
process_one() {
  # Enable per-file tracing if requested
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    echo "[VERBOSE] Enabling trace for this file" >&2
    set -x
  fi

  local in="$1"
  local orig_base="${in%.*}"
  local repaired="${orig_base}.repaired.mkv"
  local out="${orig_base}.mp4"
  local source_for_convert="$in"
  local used_repaired=0
  local convert_rc=0

  echo "[START] $in" >&2

  print_forced_sub_status "$in"

  if [[ -e "$out" ]]; then
    out="$(unique_path "$out")"
    echo "[WARN ] Output exists; using $(basename "$out") instead" >&2
  fi

  local filename_only
  filename_only="$(basename "$in")"
  IFS='|' read -r detected_type _ _ _ _ < <(detect_type_and_query "${filename_only%.*}")

  # If OMDb JSON exists and has a confirmed match, compute a new output filename
  local prejson="${in%.*}.omdb.json"
  if [[ -f "$prejson" && -s "$prejson" && -n "$(command -v jq 2>/dev/null)" ]]; then
    local ok
    ok="$(jq -r '.Response // "False"' "$prejson" 2>/dev/null || echo "False")"
    if [[ "$ok" == "True" ]]; then
      local omdb_type title year imdbid season episode series_name
      omdb_type="$(jq -r '.Type // ""' "$prejson" 2>/dev/null || echo "")"
      title="$(jq -r '.Title // ""' "$prejson" 2>/dev/null || echo "")"
      year="$(jq -r '.Year // ""' "$prejson" 2>/dev/null || echo "")"
      imdbid="$(jq -r '.imdbID // ""' "$prejson" 2>/dev/null || echo "")"
      season="$(jq -r '.Season // ""' "$prejson" 2>/dev/null || echo "")"
      episode="$(jq -r '.Episode // ""' "$prejson" 2>/dev/null || echo "")"
      series_name="$(jq -r '.Series // ""' "$prejson" 2>/dev/null || echo "")"

      local target_name=""
      if [[ "$omdb_type" == "episode" || "$detected_type" == "tv" ]]; then
        if [[ -z "$series_name" ]]; then
          IFS='|' read -r _ _ series2 season2 episode2 _ < <(detect_type_and_query "${filename_only%.*}")
          series_name="$series2"
          [[ -z "$season" ]] && season="$season2"
          [[ -z "$episode" ]] && episode="$episode2"
        fi
        if [[ -n "$season" ]]; then
          season="$(printf "%02d" "$season")"
        else
          season="01"
        fi
        if [[ -n "$episode" ]]; then
          episode="$(printf "%02d" "$episode")"
        else
          episode="01"
        fi
        if [[ -n "$title" ]]; then
          target_name="${series_name} - S${season}E${episode} - ${title}.mp4"
        else
          target_name="${series_name} - S${season}E${episode}.mp4"
        fi
      else
        if [[ -n "$title" && -n "$year" ]]; then
          target_name="${title} (${year}).mp4"
        elif [[ -n "$title" ]]; then
          target_name="${title}.mp4"
        else
          target_name="$(basename "$in")"
          target_name="${target_name%.*}.mp4"
        fi
      fi

      local dir
      dir="$(dirname "$in")"
      target_name="$(sanitize_filename "$target_name")"
      local target_path="${dir}/${target_name}"
      target_path="$(unique_path "$target_path")"

      if [[ "$target_path" != "$out" ]]; then
        out="$target_path"
        echo "[RENAME] Will encode to: $(basename "$out")" >&2
      fi
    fi
  fi

  copy_omdb_sidecar_for_output "$prejson" "$out"

  case "$REPAIR_MODE" in
    always)
      if ! repair_mkv "$in" "$repaired"; then
        echo "[FAIL ] repair: $in" >&2
        [[ "${VERBOSE:-0}" == "1" ]] && set +x
        return 1
      fi
      source_for_convert="$repaired"
      used_repaired=1
      convert_from_source "$source_for_convert" "$out" "$detected_type" "$in"
      convert_rc=$?
      ;;
    auto)
      convert_from_source "$source_for_convert" "$out" "$detected_type" "$in"
      convert_rc=$?
      if [[ "$convert_rc" -eq 10 || "$convert_rc" -eq 11 ]]; then
        if [[ "$convert_rc" -eq 11 ]]; then
          echo "[RETRY] Fast copy hit non-monotonic DTS; retrying with repaired MKV" >&2
        else
          echo "[RETRY] Conversion failed; retrying with repaired MKV" >&2
        fi
        if repair_mkv "$in" "$repaired"; then
          source_for_convert="$repaired"
          used_repaired=1
          convert_from_source "$source_for_convert" "$out" "$detected_type" "$in"
          convert_rc=$?
        else
          echo "[FAIL ] repair: $in" >&2
        fi
      fi
      ;;
    never)
      convert_from_source "$source_for_convert" "$out" "$detected_type" "$in"
      convert_rc=$?
      ;;
  esac

  [[ "$used_repaired" == "1" ]] && rm -f "$repaired"

  if [[ "$convert_rc" -ne 0 ]]; then
    rm -f "$out"
    if [[ "$convert_rc" -ne 20 ]]; then
      echo "[FAIL ] encode: $in" >&2
    fi
    [[ "${VERBOSE:-0}" == "1" ]] && set +x
    return 1
  fi

  if [[ -s "$out" ]]; then
    tag_plex_omdb_always "$out" || true
  fi

  echo "[DONE ] $in -> $(basename "$out")" >&2

  # Disable tracing for this file if it was enabled
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    set +x
  fi

  return 0
}

############################################
# Run (parallel or foreground when JOBS=1)
############################################
FAILURES=0
for f in "${FILES[@]}"; do
  if [[ "${JOBS:-1}" -le 1 ]]; then
    # Foreground mode: do not background; output visible in terminal
    if ! process_one "$f"; then
      FAILURES=$((FAILURES + 1))
    fi
  else
    process_one "$f" &
    while (( $(jobs -rp | wc -l) >= JOBS )); do
      if ! wait -n; then
        FAILURES=$((FAILURES + 1))
      fi
    done
  fi
done
while (( $(jobs -rp | wc -l) > 0 )); do
  if ! wait -n; then
    FAILURES=$((FAILURES + 1))
  fi
done

echo "[ALL DONE]" >&2
echo "[OMDb] log: ${OMDB_LOG}" >&2
if (( FAILURES > 0 )); then
  echo "[WARN ] ${FAILURES} file(s) failed." >&2
  exit 1
fi
