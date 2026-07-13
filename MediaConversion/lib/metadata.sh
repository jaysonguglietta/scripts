#!/usr/bin/env bash

# OMDb lookup, output naming, CSV logging, artwork, and MP4 tagging helpers.

esc_csv() {
  local value="${1:-}"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

clean_title() {
  local value="$1"
  value="$(printf '%s' "$value" | sed -E 's/[._-]+/ /g')"
  value="$(printf '%s' "$value" | sed -E '
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
  printf '%s' "$value" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+|[[:space:]]+$//g'
}

parse_sxxexx() {
  local value="$1"
  value="$(printf '%s' "$value" | sed -E 's/[._-]+/ /g')"
  if [[ "$value" =~ ^(.*)[[:space:]]+[sS]([0-9]{1,2})[eE]([0-9]{1,2}).*$ ]]; then
    local series="${BASH_REMATCH[1]}"
    local season=$((10#${BASH_REMATCH[2]}))
    local episode=$((10#${BASH_REMATCH[3]}))
    series="$(printf '%s' "$series" | sed -E 's/[[:space:]]+$//')"
    printf '%s|%s|%s' "$series" "$season" "$episode"
    return 0
  fi
  return 1
}

detect_movie_year() {
  local value="$1" normalized year
  normalized="$(printf '%s' "$value" | sed -E 's/[._]+/ /g')"
  year="$(printf '%s' "$normalized" |
    grep -oE '(^|[[:space:]\(\[\{<]|-)[[:space:]]*((19|20)[0-9]{2})[[:space:]]*($|[[:space:]\)\]\}>]|-)' |
    grep -oE '(19|20)[0-9]{2}' |
    tail -n 1 || true)"
  [[ -n "$year" ]] && printf '%s' "$year"
}

strip_year_from_title() {
  local title="$1" year="$2"
  if [[ -z "$year" ]]; then
    printf '%s' "$title"
    return 0
  fi
  title="$(printf '%s' "$title" | sed -E "s/[\(\[\{<][[:space:]]*${year}[[:space:]]*[\)\]\}>]//g")"
  title="$(printf '%s' "$title" | sed -E "s/(^|[[:space:]\-])${year}([[:space:]\-]|$)/ /g")"
  printf '%s' "$title" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+|[[:space:]]+$//g'
}

detect_type_and_query() {
  local base="$1" cleaned parsed series season episode year title_query
  cleaned="$(clean_title "$base")"
  if parsed="$(parse_sxxexx "$cleaned")"; then
    IFS='|' read -r series season episode <<< "$parsed"
    printf 'tv|%s|%s|%s|%s|' "$cleaned" "$series" "$season" "$episode"
    return 0
  fi
  year="$(detect_movie_year "$cleaned" || true)"
  title_query="$(strip_year_from_title "$cleaned" "$year")"
  printf 'movie|%s||||%s|%s' "$cleaned" "$title_query" "$year"
}

json_is_valid() {
  local path="$1"
  command -v jq >/dev/null 2>&1 || return 1
  [[ -s "$path" ]] || return 1
  jq -e . "$path" >/dev/null 2>&1
}

json_is_confirmed_match() {
  local path="$1"
  json_is_valid "$path" || return 1
  [[ "$(jq -r '.Response // "False"' "$path" 2>/dev/null)" == "True" ]]
}

write_json_atomically() {
  local output="$1" json="$2" temporary
  command -v jq >/dev/null 2>&1 || return 1
  temporary="$(mktemp "${output}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$json" > "$temporary" || ! jq -e . "$temporary" >/dev/null 2>&1; then
    rm -f -- "$temporary"
    return 1
  fi
  mv -f -- "$temporary" "$output"
}

omdb_api_request() {
  [[ -n "${OMDB_API_KEY:-}" ]] || return 2
  command -v curl >/dev/null 2>&1 || return 2
  local endpoint="${OMDB_URL%/}/"
  local -a arguments=(
    --silent --show-error --fail --get
    --connect-timeout "$OMDB_CONNECT_TIMEOUT"
    --max-time "$OMDB_MAX_TIME"
    --retry "$OMDB_RETRIES"
    --retry-delay 1
  )
  while (( $# )); do
    arguments+=(--data-urlencode "$1")
    shift
  done
  # Read the key from stdin so it is not exposed in curl's process arguments.
  printf '%s' "$OMDB_API_KEY" |
    curl "${arguments[@]}" --data-urlencode 'apikey@-' "$endpoint"
}

omdb_lookup() {
  local base="$1" type cleaned series season episode title_query year json
  IFS='|' read -r type cleaned series season episode title_query year < <(detect_type_and_query "$base")

  if [[ "$type" == "tv" ]]; then
    json="$(omdb_api_request "t=${series}" "Season=${season}" "Episode=${episode}")" || return $?
    if [[ "$(printf '%s' "$json" | jq -r '.Response // "False"' 2>/dev/null)" == "True" ]]; then
      printf '%s' "$json"
      return 0
    fi
  fi

  if [[ -n "${year:-}" ]]; then
    json="$(omdb_api_request "t=${title_query}" "y=${year}")" || return $?
    if [[ "$(printf '%s' "$json" | jq -r '.Response // "False"' 2>/dev/null)" != "True" ]]; then
      json="$(omdb_api_request "t=${title_query}")" || return $?
    fi
  else
    json="$(omdb_api_request "t=${title_query}")" || return $?
  fi
  printf '%s' "$json"
}

omdb_search() {
  omdb_api_request "s=$1"
}

omdb_fetch_by_id() {
  omdb_api_request "i=$1"
}

omdb_prompt_read() {
  local prompt="$1" variable_name="$2"
  if [[ -t 0 ]]; then
    read -r -p "$prompt" "${variable_name?}"
    return $?
  fi
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '%s' "$prompt" > /dev/tty
    IFS= read -r "${variable_name?}" < /dev/tty
    return $?
  fi
  return 1
}

save_empty_metadata_if_missing() {
  local output="$1"
  [[ -e "$output" ]] && return 0
  write_json_atomically "$output" '{}'
}

omdb_automatic_lookup_and_save() {
  local base="$1" output="$2" json
  if ! json="$(omdb_lookup "$base")"; then
    log_warn "OMDb lookup failed; preserving existing metadata for ${base}."
    save_empty_metadata_if_missing "$output"
    return 0
  fi
  if ! write_json_atomically "$output" "$json"; then
    log_warn "OMDb returned invalid JSON; preserving existing metadata for ${base}."
    return 0
  fi
}

omdb_interactive_verify_and_save() {
  local filepath="$1" base output_json json response answer
  base="$(basename "$filepath")"
  base="${base%.*}"
  output_json="${filepath%.*}.omdb.json"

  if [[ "$OMDB_REFRESH" != "1" ]] && json_is_confirmed_match "$output_json"; then
    log_info "Reusing confirmed OMDb metadata: ${output_json}"
    return 0
  fi

  if [[ "$OMDB_ENABLED" != "1" ]]; then
    save_empty_metadata_if_missing "$output_json"
    return 0
  fi

  if [[ "$OMDB_INTERACTIVE" != "1" || ( ! -t 0 && ! -r /dev/tty ) ]]; then
    omdb_automatic_lookup_and_save "$base" "$output_json"
    return 0
  fi

  if ! json="$(omdb_lookup "$base")"; then
    log_warn "OMDb lookup failed; preserving existing metadata for ${filepath}."
    save_empty_metadata_if_missing "$output_json"
    return 0
  fi
  response="$(printf '%s' "$json" | jq -r '.Response // "False"' 2>/dev/null || printf False)"

  if [[ "$response" == "True" ]]; then
    printf '\nOMDb matched: %s (%s) [%s] imdb:%s\n\n' \
      "$(printf '%s' "$json" | jq -r '.Title // ""')" \
      "$(printf '%s' "$json" | jq -r '.Year // ""')" \
      "$(printf '%s' "$json" | jq -r '.Type // ""')" \
      "$(printf '%s' "$json" | jq -r '.imdbID // ""')"
    while :; do
      if ! omdb_prompt_read 'Is this match correct? (y)es / (n)o / (s)earch alternatives / (k)skip: ' answer; then
        log_warn "Prompt unavailable; preserving the automatic match for ${filepath}."
        write_json_atomically "$output_json" "$json"
        return 0
      fi
      case "$(lowercase "$answer")" in
        y|yes)
          write_json_atomically "$output_json" "$json"
          return 0
          ;;
        n|no|s)
          # The direct match was explicitly rejected and must never be reused.
          json=""
          break
          ;;
        k|skip)
          write_json_atomically "$output_json" '{}'
          return 0
          ;;
        *) printf 'Please answer y, n, s, or k.\n' ;;
      esac
    done
  fi

  local cleaned search_json total shown choice selected_id selected_json
  cleaned="$(clean_title "$base")"
  if ! search_json="$(omdb_search "$cleaned")"; then
    log_warn "OMDb alternative search failed; preserving existing metadata for ${filepath}."
    save_empty_metadata_if_missing "$output_json"
    return 0
  fi
  total="$(printf '%s' "$search_json" | jq -r '.totalResults // 0' 2>/dev/null || printf 0)"
  if [[ "$total" == "0" ]]; then
    log_info "No OMDb alternatives found for ${filepath}."
    write_json_atomically "$output_json" '{}'
    return 0
  fi

  shown="$total"
  (( shown > 8 )) && shown=8
  printf '\nAlternatives:\n----------------------------------------\n'
  printf '%s' "$search_json" | jq -r '.Search[] | "\(.Title) | \(.Year) | \(.imdbID) | \(.Type)"' | nl -w2 -s'. ' | sed -n "1,${shown}p"
  printf '%s\n' '----------------------------------------'

  while :; do
    if ! omdb_prompt_read "Choice [0-${shown}, 0 skips]: " choice; then
      write_json_atomically "$output_json" '{}'
      return 0
    fi
    if [[ "$choice" == "0" ]]; then
      write_json_atomically "$output_json" '{}'
      return 0
    fi
    if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice <= shown )); then
      selected_id="$(printf '%s' "$search_json" | jq -r ".Search[$((choice - 1))].imdbID // empty")"
      if selected_json="$(omdb_fetch_by_id "$selected_id")" && write_json_atomically "$output_json" "$selected_json"; then
        return 0
      fi
      printf 'Could not fetch that selection. Try again or enter 0.\n'
    else
      printf 'Choose a displayed number or 0.\n'
    fi
  done
}

format_episode_number() {
  local value="${1:-}" fallback="$2"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%02d' "$((10#$value))"
  else
    printf '%02d' "$fallback"
  fi
}

suggest_output_path() {
  local input="$1" filename detected_type prejson default_output
  filename="$(basename "$input")"
  default_output="$(dirname "$input")/$(sanitize_filename "${filename%.*}.mp4")"
  IFS='|' read -r detected_type _ _ _ _ _ _ < <(detect_type_and_query "${filename%.*}")
  prejson="${input%.*}.omdb.json"

  if ! json_is_confirmed_match "$prejson"; then
    printf '%s' "$default_output"
    return 0
  fi

  local omdb_type title year season episode series_name target_name directory
  omdb_type="$(jq -r '.Type // ""' "$prejson")"
  title="$(jq -r '.Title // ""' "$prejson")"
  year="$(jq -r '.Year // ""' "$prejson")"
  season="$(jq -r '.Season // ""' "$prejson")"
  episode="$(jq -r '.Episode // ""' "$prejson")"
  series_name="$(jq -r '.Series // ""' "$prejson")"

  [[ "$title" == "N/A" ]] && title=""
  [[ "$year" == "N/A" ]] && year=""
  [[ "$season" == "N/A" ]] && season=""
  [[ "$episode" == "N/A" ]] && episode=""
  [[ "$series_name" == "N/A" ]] && series_name=""

  if [[ "$omdb_type" == "episode" || "$detected_type" == "tv" ]]; then
    local parsed_series parsed_season parsed_episode
    if [[ -z "$series_name" ]]; then
      IFS='|' read -r _ _ parsed_series parsed_season parsed_episode _ _ < <(detect_type_and_query "${filename%.*}")
      series_name="$parsed_series"
      [[ -z "$season" ]] && season="$parsed_season"
      [[ -z "$episode" ]] && episode="$parsed_episode"
    fi
    season="$(format_episode_number "$season" 1)"
    episode="$(format_episode_number "$episode" 1)"
    if [[ -n "$title" ]]; then
      target_name="${series_name} - S${season}E${episode} - ${title}.mp4"
    else
      target_name="${series_name} - S${season}E${episode}.mp4"
    fi
  elif [[ -n "$title" && -n "$year" ]]; then
    target_name="${title} (${year}).mp4"
  elif [[ -n "$title" ]]; then
    target_name="${title}.mp4"
  else
    target_name="$(basename "$default_output")"
  fi

  target_name="$(sanitize_filename "$target_name")"
  directory="$(dirname "$input")"
  printf '%s/%s' "$directory" "$target_name"
}

copy_omdb_sidecar_for_output() {
  local input_sidecar="$1" output_path="$2" target_sidecar temporary
  [[ -f "$input_sidecar" ]] || return 0
  target_sidecar="${output_path%.*}.omdb.json"
  [[ "$input_sidecar" == "$target_sidecar" ]] && return 0
  temporary="$(mktemp "${target_sidecar}.tmp.XXXXXX")" || return 1
  if cp -p "$input_sidecar" "$temporary"; then
    mv -f "$temporary" "$target_sidecar"
  else
    rm -f -- "$temporary"
    return 1
  fi
}

ensure_omdb_log_header() {
  if [[ ! -f "$OMDB_LOG" ]]; then
    printf '%s\n' 'file,matched,tagged,type,title,year,imdbID,season,episode,poster_url,notes' > "$OMDB_LOG"
  fi
}

append_omdb_log_line() {
  local line="$1"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 9
      ensure_omdb_log_header
      printf '%s\n' "$line" >> "$OMDB_LOG"
    ) 9>>"$OMDB_LOG_LOCK"
    return
  fi

  (
    local lock_directory="${OMDB_LOG_LOCK}.d" attempt=0 acquired=0
    # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
    cleanup_log_lock() {
      (( acquired == 1 )) && rmdir "$lock_directory" 2>/dev/null || true
    }
    trap cleanup_log_lock EXIT
    trap 'exit 130' INT TERM

    while ! mkdir "$lock_directory" 2>/dev/null; do
      attempt=$((attempt + 1))
      if (( attempt >= 200 )); then
        log_warn "Could not acquire metadata log lock; writing without a lock."
        ensure_omdb_log_header
        printf '%s\n' "$line" >> "$OMDB_LOG"
        return
      fi
      sleep 0.05
    done
    acquired=1
    ensure_omdb_log_header
    printf '%s\n' "$line" >> "$OMDB_LOG"
  )
}

log_omdb() {
  local file="$1" matched="$2" tagged="$3" type="$4" title="$5" year="$6"
  local imdb_id="$7" season="$8" episode="$9" poster="${10}" notes="${11:-}"
  local line
  printf -v line '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' \
    "$(esc_csv "$file")" "$(esc_csv "$matched")" "$(esc_csv "$tagged")" \
    "$(esc_csv "$type")" "$(esc_csv "$title")" "$(esc_csv "$year")" \
    "$(esc_csv "$imdb_id")" "$(esc_csv "$season")" "$(esc_csv "$episode")" \
    "$(esc_csv "$poster")" "$(esc_csv "$notes")"
  append_omdb_log_line "$line"
}

download_poster() {
  local url="$1" output_base="$2" content_type extension temporary output
  command -v curl >/dev/null 2>&1 || return 1
  [[ -n "$url" && "$url" != "N/A" ]] || return 1
  temporary="${output_base}.download"
  if ! content_type="$(curl --silent --show-error --fail --location \
      --connect-timeout "$OMDB_CONNECT_TIMEOUT" --max-time "$OMDB_MAX_TIME" \
      --retry "$OMDB_RETRIES" --retry-delay 1 \
      --output "$temporary" --write-out '%{content_type}' "$url")"; then
    rm -f -- "$temporary"
    return 1
  fi
  if [[ ! -s "$temporary" ]]; then
    rm -f -- "$temporary"
    return 1
  fi
  case "$(lowercase "$content_type")" in
    image/jpeg*) extension=jpg ;;
    image/png*) extension=png ;;
    image/webp*) extension=webp ;;
    *)
      rm -f -- "$temporary"
      log_warn "Poster response was not an image: ${content_type:-unknown}"
      return 1
      ;;
  esac
  output="${output_base}.${extension}"
  mv -f -- "$temporary" "$output" || return 1
  printf '%s' "$output"
}

atomicparsley_tag() {
  local mp4="$1" artwork="$2" title="$3" description="$4" year="$5"
  local type="$6" series="$7" season="$8" episode="$9" log_file="${10}"
  local -a arguments=("$mp4" --title "$title" --description "$description")

  if [[ "$type" == "episode" ]]; then
    arguments+=(--TVShowName "$series" --TVSeasonNum "$season" --TVEpisodeNum "$episode" --stik 'TV Show')
  else
    [[ -n "$year" ]] && arguments+=(--year "$year")
    arguments+=(--stik Movie)
  fi
  [[ -n "$artwork" ]] && arguments+=(--artwork "$artwork")
  arguments+=(--overWrite)

  if ! AtomicParsley "${arguments[@]}" >"$log_file" 2>&1; then
    log_warn "AtomicParsley tagging failed for $(basename "$mp4")."
    sed -n '1,120p' "$log_file" >&2
    return 1
  fi
}

ffmpeg_tag() {
  local mp4="$1" artwork="$2" title="$3" description="$4" year="$5"
  local type="$6" series="$7" season="$8" episode="$9" work_directory="${10}"
  local temporary="${work_directory}/tagged.mp4"
  local -a inputs=(-i "$mp4") maps=(-map 0) metadata=(
    -metadata "title=${title}"
    -metadata "comment=${description}"
    -metadata "date=${year}"
  )
  local -a artwork_arguments=()

  if [[ "$type" == "episode" ]]; then
    metadata+=(
      -metadata "show=${series}"
      -metadata "season_number=${season}"
      -metadata "episode_id=${episode}"
    )
  fi
  if [[ -n "$artwork" ]]; then
    inputs+=(-i "$artwork")
    maps+=(-map 1:0)
    artwork_arguments=(-disposition:v:1 attached_pic)
  fi

  local tag_status
  if [[ -n "$artwork" ]]; then
    "$FFMPEG" -y -v warning \
      "${inputs[@]}" "${maps[@]}" -c copy \
      "${artwork_arguments[@]}" \
      "${metadata[@]}" "${MP4_OUTPUT_FLAGS[@]}" "$temporary"
    tag_status=$?
  else
    "$FFMPEG" -y -v warning \
      "${inputs[@]}" "${maps[@]}" -c copy \
      "${metadata[@]}" "${MP4_OUTPUT_FLAGS[@]}" "$temporary"
    tag_status=$?
  fi
  if [[ "$tag_status" -ne 0 ]]; then
    log_warn "FFmpeg metadata tagging failed for $(basename "$mp4")."
    return 1
  fi
  validate_media_output "$temporary" "$mp4" || return 1
  mv -f -- "$temporary" "$mp4"
}

tag_media_from_omdb() {
  local mp4="$1" work_directory="$2" sidecar json staged_mp4
  sidecar="${mp4%.*}.omdb.json"
  if ! json_is_confirmed_match "$sidecar"; then
    log_omdb "$mp4" no no '' '' '' '' '' '' '' 'OMDb no match'
    return 0
  fi
  json="$(cat "$sidecar")"
  staged_mp4="${work_directory}/tag-source.mp4"
  if ! cp -p "$mp4" "$staged_mp4"; then
    log_warn "Could not stage MP4 for metadata tagging: ${mp4}"
    return 1
  fi

  local title plot poster year type imdb_id season episode series description artwork="" tagged=no notes
  title="$(printf '%s' "$json" | jq -r '.Title // ""')"
  plot="$(printf '%s' "$json" | jq -r '.Plot // ""')"
  poster="$(printf '%s' "$json" | jq -r '.Poster // ""')"
  year="$(printf '%s' "$json" | jq -r '.Year // ""')"
  type="$(printf '%s' "$json" | jq -r '.Type // ""')"
  imdb_id="$(printf '%s' "$json" | jq -r '.imdbID // ""')"
  season="$(printf '%s' "$json" | jq -r '.Season // ""')"
  episode="$(printf '%s' "$json" | jq -r '.Episode // ""')"
  series="$(printf '%s' "$json" | jq -r '.Series // ""')"

  [[ "$title" == "N/A" ]] && title=""
  [[ "$plot" == "N/A" ]] && plot=""
  [[ "$poster" == "N/A" ]] && poster=""
  [[ "$year" == "N/A" ]] && year=""
  [[ "$imdb_id" == "N/A" ]] && imdb_id=""
  [[ "$season" == "N/A" ]] && season=""
  [[ "$episode" == "N/A" ]] && episode=""
  [[ "$series" == "N/A" ]] && series=""

  description="$plot"
  [[ -n "$year" ]] && description+=$'\n\nYear: '"$year"
  [[ -n "$imdb_id" ]] && description+=$'\nIMDb: '"$imdb_id"

  if [[ -n "$poster" ]]; then
    if ! artwork="$(download_poster "$poster" "${work_directory}/poster")"; then
      artwork=""
      log_warn "Poster download failed; continuing with metadata-only tagging."
    fi
  fi

  if command -v AtomicParsley >/dev/null 2>&1; then
    if atomicparsley_tag "$staged_mp4" "$artwork" "$title" "$description" "$year" \
        "$type" "$series" "$season" "$episode" "${work_directory}/atomicparsley.log"; then
      tagged=yes
      notes='matched and tagged with AtomicParsley'
    else
      log_warn 'AtomicParsley failed; restoring the staged file and trying FFmpeg metadata tagging.'
      if cp -p "$mp4" "$staged_mp4" && ffmpeg_tag "$staged_mp4" "$artwork" "$title" \
          "$description" "$year" "$type" "$series" "$season" "$episode" "$work_directory"; then
        tagged=yes
        notes='matched and tagged with FFmpeg after AtomicParsley failed'
      else
        notes='matched; AtomicParsley and FFmpeg tagging failed'
      fi
    fi
  elif ffmpeg_tag "$staged_mp4" "$artwork" "$title" "$description" "$year" \
      "$type" "$series" "$season" "$episode" "$work_directory"; then
    tagged=yes
    notes='matched and tagged with FFmpeg'
  else
    notes='matched; FFmpeg tagging failed'
  fi

  if [[ "$tagged" == yes ]]; then
    if validate_media_output "$staged_mp4" "$mp4"; then
      mv -f "$staged_mp4" "$mp4"
    else
      tagged=no
      notes="${notes}; staged output failed validation"
      rm -f "$staged_mp4"
    fi
  else
    rm -f "$staged_mp4"
  fi

  log_omdb "$mp4" yes "$tagged" "$type" "$title" "$year" "$imdb_id" "$season" "$episode" "$poster" "$notes"
  [[ "$tagged" == yes ]]
}
