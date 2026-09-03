#!/usr/bin/env bash

# OMDb lookup, output naming, CSV logging, artwork, and MP4 tagging helpers.

esc_csv() {
  local value="${1:-}"
  value="$(safe_log_text "$value")"
  case "$value" in
    [=+@-]*) value="'${value}" ;;
  esac
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

clean_title() {
  local value="$1"
  value="${value//$'\033'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\t'/ }"
  value="${value//|/ }"
  value="$(LC_ALL=C printf '%s' "$value" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
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

trim_whitespace() {
  printf '%s' "${1:-}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
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

determine_media_type() {
  local input="$1" detected_type sidecar omdb_type
  IFS='|' read -r detected_type _ _ _ _ _ _ < <(detect_type_and_query "$(basename "${input%.*}")")
  sidecar="${input%.*}.omdb.json"
  if json_is_confirmed_match "$sidecar"; then
    omdb_type="$(json_file_string_field "$sidecar" Type 16)"
    case "$omdb_type" in
      episode) detected_type=tv ;;
      movie) detected_type=movie ;;
    esac
  fi
  printf '%s' "$detected_type"
}

json_is_valid() {
  local path="$1" size
  command -v jq >/dev/null 2>&1 || return 1
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || return 1
  size="$(file_size_bytes "$path" 2>/dev/null || true)"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  (( size <= ${OMDB_RESPONSE_MAX_BYTES:-1048576} )) || return 1
  jq -e . "$path" >/dev/null 2>&1
}

json_file_string_field() {
  local path="$1" field="$2" maximum="$3"
  jq -r --arg field "$field" --argjson maximum "$maximum" '
    .[$field] | if type == "string" then .[0:$maximum] else "" end
  ' "$path" 2>/dev/null
}

json_string_field() {
  local json="$1" field="$2" maximum="$3"
  printf '%s' "$json" | jq -r --arg field "$field" --argjson maximum "$maximum" '
    .[$field] | if type == "string" then .[0:$maximum] else "" end
  ' 2>/dev/null
}

json_is_confirmed_match() {
  local path="$1"
  json_is_valid "$path" || return 1
  jq -e '
    .Response == "True" and
    (.Title | type == "string" and length > 0 and length <= 512) and
    (.imdbID | type == "string" and test("^tt[0-9]+$")) and
    (.Type | type == "string" and (. == "movie" or . == "series" or . == "episode"))
  ' "$path" >/dev/null 2>&1
}

json_string_is_confirmed_match() {
  local json="$1"
  (( ${#json} <= ${OMDB_RESPONSE_MAX_BYTES:-1048576} )) || return 1
  printf '%s' "$json" | jq -e '
    .Response == "True" and
    (.Title | type == "string" and length > 0 and length <= 512) and
    (.imdbID | type == "string" and test("^tt[0-9]+$")) and
    (.Type | type == "string" and (. == "movie" or . == "series" or . == "episode"))
  ' >/dev/null 2>&1
}

write_json_atomically() {
  local output="$1" json="$2" temporary
  command -v jq >/dev/null 2>&1 || return 1
  if (( ${#json} > ${OMDB_RESPONSE_MAX_BYTES:-1048576} )); then
    log_warn "Refusing oversized OMDb JSON for $(basename "$output")."
    return 1
  fi
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
    --max-filesize "${OMDB_RESPONSE_MAX_BYTES:-1048576}"
    --proto '=https'
  )
  while (( $# )); do
    arguments+=(--data-urlencode "$1")
    shift
  done
  # Read the key from stdin so it is not exposed in curl's process arguments.
  printf '%s' "$OMDB_API_KEY" |
    curl "${arguments[@]}" --data-urlencode 'apikey@-' -- "$endpoint"
}

omdb_lookup() {
  local base="$1" type cleaned series season episode title_query year json
  IFS='|' read -r type cleaned series season episode title_query year < <(detect_type_and_query "$base")

  if [[ "$type" == "tv" ]]; then
    json="$(omdb_api_request "t=${series}" "Season=${season}" "Episode=${episode}")" || return $?
    if json_string_is_confirmed_match "$json"; then
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
  (( ${#json} <= ${OMDB_RESPONSE_MAX_BYTES:-1048576} )) || return 1
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

omdb_prompt_available() {
  [[ -t 0 ]] || [[ -r /dev/tty && -w /dev/tty ]]
}

save_metadata_skip() {
  local output="$1"
  if [[ "${STRICT_METADATA:-0}" == "1" ]]; then
    log_error 'Metadata is required; skipping a match stops this file.'
    return 1
  fi
  write_json_atomically "$output" '{}'
}

omdb_search_and_select() {
  local filepath="$1" output="$2" initial_query="$3"
  local search_query="$initial_query" search_json result_count shown choice selected_id selected_json
  local row display_index

  while :; do
    if [[ -z "$search_query" ]]; then
      if ! omdb_prompt_read 'Search OMDb for (enter 0 to skip): ' search_query; then
        log_error "OMDb confirmation requires a terminal for ${filepath}. Re-run interactively or set OMDB_INTERACTIVE=0."
        return 1
      fi
      search_query="$(trim_whitespace "$search_query")"
      if [[ "$search_query" == "0" ]]; then
        save_metadata_skip "$output"
        return $?
      fi
      if [[ -z "$search_query" ]]; then
        printf 'Please enter a search query or 0 to skip.\n'
        continue
      fi
    fi

    log_info "Searching OMDb for ${search_query}"
    if ! search_json="$(omdb_search "$search_query")"; then
      log_warn "OMDb search failed for ${search_query}."
      search_query=""
      continue
    fi

    if ! search_json="$(printf '%s' "$search_json" | jq -ce '
        if (.Search | type) != "array" then {Search: []}
        else {
          Search: [
            .Search[:64][] |
            select(type == "object") |
            select(.Title | type == "string" and length > 0 and length <= 512) |
            select(.Year | type == "string" and length <= 32) |
            select(.imdbID | type == "string" and test("^tt[0-9]+$")) |
            select(.Type | type == "string" and (. == "movie" or . == "series" or . == "episode"))
          ]
        } end
      ' 2>/dev/null)"; then
      log_warn 'OMDb returned a malformed search response.'
      search_query=""
      continue
    fi

    if ! result_count="$(printf '%s' "$search_json" | jq -er 'if (.Search | type) == "array" then (.Search | length) else 0 end' 2>/dev/null)" || \
        [[ ! "$result_count" =~ ^[0-9]+$ ]]; then
      log_warn 'OMDb returned a malformed search response.'
      search_query=""
      continue
    fi
    if [[ "$result_count" == "0" ]]; then
      printf '\nNo OMDb results for: %s\n\n' "$(safe_log_text "$search_query")"
      search_query=""
      continue
    fi

    shown=$((10#$result_count))
    (( shown > 8 )) && shown=8
    printf '\nAlternatives for "%s":\n----------------------------------------\n' "$(safe_log_text "$search_query")"
    display_index=0
    while IFS= read -r row; do
      display_index=$((display_index + 1))
      printf '%2d. %s\n' "$display_index" "$(safe_log_text "$row")"
    done < <(printf '%s' "$search_json" | jq -r --argjson shown "$shown" \
      '.Search[:$shown][] | [.Title, .Year, .imdbID, .Type] | @tsv')
    printf '%s\n' '----------------------------------------'

    while :; do
      if ! omdb_prompt_read "Choice [1-${shown}], (m)anual search, or 0 to skip: " choice; then
        log_error "OMDb confirmation requires a terminal for ${filepath}. Re-run interactively or set OMDB_INTERACTIVE=0."
        return 1
      fi
      case "$(lowercase "$choice")" in
        0)
          save_metadata_skip "$output"
          return $?
          ;;
        m|manual)
          search_query=""
          break
          ;;
        *)
          if [[ "$choice" =~ ^[1-9][0-9]*$ && ${#choice} -le 2 ]] && (( 10#$choice <= shown )); then
            selected_id="$(printf '%s' "$search_json" | jq -r ".Search[$((10#$choice - 1))].imdbID // empty")"
            if [[ -z "$selected_id" ]]; then
              printf 'Could not read that selection. Choose another result, press m, or enter 0.\n'
              continue
            fi
            if selected_json="$(omdb_fetch_by_id "$selected_id")" && \
                json_string_is_confirmed_match "$selected_json" && \
                write_json_atomically "$output" "$selected_json"; then
              return 0
            fi
            printf 'Could not fetch or validate that selection. Choose another result, press m, or enter 0.\n'
          else
            printf 'Choose a displayed number, m, or 0.\n'
          fi
          ;;
      esac
    done
  done
}

save_empty_metadata_if_missing() {
  local output="$1"
  [[ -e "$output" ]] && return 0
  write_json_atomically "$output" '{}'
}

omdb_automatic_lookup_and_save() {
  local base="$1" output="$2" json
  log_info "Fetching OMDb metadata for ${base}"
  if ! json="$(omdb_lookup "$base")"; then
    log_warn "OMDb lookup failed; preserving existing metadata for ${base}."
    [[ "${STRICT_METADATA:-0}" == "1" ]] && return 1
    save_empty_metadata_if_missing "$output"
    return 0
  fi
  if ! write_json_atomically "$output" "$json"; then
    log_warn "OMDb returned invalid JSON; preserving existing metadata for ${base}."
    return 0
  fi
  if json_string_is_confirmed_match "$json"; then
    log_info "Saved OMDb match to $(basename "$output")"
  else
    log_info "OMDb returned no confirmed match for ${base}"
    [[ "${STRICT_METADATA:-0}" == "1" ]] && return 1
  fi
}

omdb_interactive_verify_and_save() {
  local filepath="$1" base output_json json="" response answer search_query using_cached=0
  local match_title match_year match_type match_id
  base="$(basename "$filepath")"
  base="${base%.*}"
  output_json="${filepath%.*}.omdb.json"

  if [[ "$OMDB_REFRESH" != "1" ]] && json_is_confirmed_match "$output_json"; then
    if [[ "$OMDB_INTERACTIVE" != "1" || "$OMDB_CONFIRM_CACHED" != "1" ]]; then
      log_info "Reusing confirmed OMDb metadata: ${output_json}"
      return 0
    fi
    json="$(<"$output_json")"
    using_cached=1
  fi

  if [[ "$using_cached" == "0" && "$OMDB_ENABLED" != "1" ]]; then
    log_info "OMDb lookup skipped for ${base}; OMDb is disabled."
    if [[ "$STRICT_METADATA" == "1" ]]; then
      log_error "Confirmed metadata is required for ${filepath}."
      return 1
    fi
    if command -v jq >/dev/null 2>&1; then
      save_empty_metadata_if_missing "$output_json"
      return $?
    fi
    return 0
  fi

  if [[ "$using_cached" == "0" && "$OMDB_INTERACTIVE" != "1" ]]; then
    log_info "Using automatic OMDb lookup for ${base}"
    omdb_automatic_lookup_and_save "$base" "$output_json"
    return $?
  fi

  if ! omdb_prompt_available; then
    log_error "OMDb confirmation requires a terminal for ${filepath}. Re-run interactively or set OMDB_INTERACTIVE=0."
    return 1
  fi

  if [[ "$using_cached" == "1" ]]; then
    log_info "Confirming cached OMDb metadata: ${output_json}"
  else
    log_info "Fetching OMDb metadata for ${base}"
    if ! json="$(omdb_lookup "$base")"; then
      log_warn "OMDb lookup failed; preserving existing metadata for ${filepath}."
      if [[ "$STRICT_METADATA" == "1" ]]; then
        return 1
      fi
      save_empty_metadata_if_missing "$output_json"
      return $?
    fi
  fi
  if json_string_is_confirmed_match "$json"; then
    response=True
  else
    response=False
  fi

  if [[ "$response" == "True" ]]; then
    match_title="$(json_string_field "$json" Title 512)"
    match_year="$(json_string_field "$json" Year 32)"
    match_type="$(json_string_field "$json" Type 16)"
    match_id="$(json_string_field "$json" imdbID 32)"
    printf '\nOMDb matched: %s (%s) [%s] imdb:%s\n\n' \
      "$(safe_log_text "$match_title")" "$(safe_log_text "$match_year")" \
      "$(safe_log_text "$match_type")" "$(safe_log_text "$match_id")"
    while :; do
      if ! omdb_prompt_read 'Accept this match? (y)es / (n)o, show alternatives / (m)anual search / (k)skip: ' answer; then
        log_error "OMDb confirmation requires a terminal for ${filepath}. Re-run interactively or set OMDB_INTERACTIVE=0."
        return 1
      fi
      case "$(lowercase "$answer")" in
        y|yes)
          write_json_atomically "$output_json" "$json"
          return 0
          ;;
        n|no|s)
          if [[ "$OMDB_ENABLED" != "1" ]]; then
            log_error 'A live OMDb connection is required to search for another match.'
            return 1
          fi
          search_query="$(clean_title "$base")"
          break
          ;;
        m|manual)
          if [[ "$OMDB_ENABLED" != "1" ]]; then
            log_error 'A live OMDb connection is required for manual search.'
            return 1
          fi
          search_query=""
          break
          ;;
        k|skip)
          save_metadata_skip "$output_json"
          return $?
          ;;
        *) printf 'Please answer y, n, m, or k.\n' ;;
      esac
    done
  else
    if [[ "$OMDB_ENABLED" != "1" ]]; then
      log_error "No confirmed cached metadata is available for ${filepath}."
      return 1
    fi
    log_info "No direct OMDb match confirmed for ${base}; choose a result or skip."
    search_query="$(clean_title "$base")"
  fi

  omdb_search_and_select "$filepath" "$output_json" "$search_query"
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
  omdb_type="$(json_file_string_field "$prejson" Type 16)"
  title="$(json_file_string_field "$prejson" Title 512)"
  year="$(json_file_string_field "$prejson" Year 32)"
  season="$(json_file_string_field "$prejson" Season 16)"
  episode="$(json_file_string_field "$prejson" Episode 16)"
  series_name="$(json_file_string_field "$prejson" Series 512)"

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
  if cp -p "$input_sidecar" "$temporary" && move_file_no_clobber "$temporary" "$target_sidecar"; then
    return 0
  fi
  rm -f -- "$temporary"
  return 1
}

cleanup_omdb_file_artifacts() {
  local input="$1" output="$2" tagging_succeeded="${3:-0}" confirmed_match="${4:-0}"
  local preserve_source="${5:-0}"
  local source_sidecar="${input%.*}.omdb.json"
  local output_sidecar="${output%.*}.omdb.json"

  if [[ "$source_sidecar" == "$output_sidecar" ]]; then
    if [[ "$KEEP_OMDB_SOURCE_SIDECAR" == "1" || "$KEEP_OMDB_OUTPUT_SIDECAR" == "1" ]]; then
      return 0
    fi
    if [[ "$preserve_source" != "1" && -f "$source_sidecar" && ( "$tagging_succeeded" == "1" || "$confirmed_match" != "1" ) ]]; then
      rm -f -- "$source_sidecar" || return 1
      log_info "Removed OMDb sidecar: $(basename "$source_sidecar")"
    fi
    return 0
  fi

  if [[ "$KEEP_OMDB_OUTPUT_SIDECAR" != "1" && -f "$output_sidecar" ]]; then
    rm -f -- "$output_sidecar" || return 1
    log_info "Removed output OMDb sidecar: $(basename "$output_sidecar")"
  fi

  if [[ "$preserve_source" != "1" && "$KEEP_OMDB_SOURCE_SIDECAR" != "1" && -f "$source_sidecar" && ( "$tagging_succeeded" == "1" || "$confirmed_match" != "1" ) ]]; then
    rm -f -- "$source_sidecar" || return 1
    log_info "Removed source OMDb sidecar: $(basename "$source_sidecar")"
  fi
}

cleanup_omdb_run_artifacts() {
  local failures="${1:-0}"
  local removed_log=0

  if [[ "$KEEP_OMDB_LOG" != "1" && "$failures" == "0" && "${OMDB_LOG_IS_PER_RUN:-0}" == "1" && -f "$OMDB_LOG" ]]; then
    rm -f -- "$OMDB_LOG" || return 1
    removed_log=1
  fi

  if [[ "${OMDB_LOG_IS_PER_RUN:-0}" == "1" && -f "$OMDB_LOG_LOCK" && ! -L "$OMDB_LOG_LOCK" ]]; then
    rm -f -- "$OMDB_LOG_LOCK" || return 1
  fi
  if [[ "${OMDB_LOG_IS_PER_RUN:-0}" == "1" && -d "${OMDB_LOG_LOCK}.d" ]]; then
    rmdir -- "${OMDB_LOG_LOCK}.d" 2>/dev/null || true
  fi

  if (( removed_log == 1 )); then
    log_info "Removed OMDb metadata log: ${OMDB_LOG}"
  fi
}

ensure_omdb_log_header() {
  [[ ! -L "$OMDB_LOG" ]] || { log_error 'Refusing symlinked OMDb log path.'; return 1; }
  if [[ ! -f "$OMDB_LOG" ]]; then
    (umask 077; printf '%s\n' 'file,matched,tagged,type,title,year,imdbID,season,episode,poster_url,notes' > "$OMDB_LOG")
  fi
}

append_omdb_log_line() {
  local line="$1"
  [[ ! -L "$OMDB_LOG" && ! -L "$OMDB_LOG_LOCK" ]] || {
    log_error 'Refusing symlinked OMDb log path.'
    return 1
  }
  if command -v flock >/dev/null 2>&1; then
    (
      umask 077
      exec 9>>"$OMDB_LOG_LOCK" || exit 1
      flock -w 10 -x 9 || exit 1
      ensure_omdb_log_header || exit 1
      printf '%s\n' "$line" >> "$OMDB_LOG"
    )
    return
  fi

  (
    local lock_directory="${OMDB_LOG_LOCK}.d" attempt=0 acquired=0
    # shellcheck disable=SC2317,SC2329 # Invoked indirectly by the EXIT trap.
    cleanup_log_lock() {
      if (( acquired == 1 )); then
        rmdir "$lock_directory" 2>/dev/null || true
      fi
    }
    trap cleanup_log_lock EXIT
    trap 'exit 130' INT TERM

    while ! mkdir -m 700 "$lock_directory" 2>/dev/null; do
      attempt=$((attempt + 1))
      if (( attempt >= 200 )); then
        log_error 'Could not acquire the metadata log lock; refusing an unsynchronized write.'
        exit 1
      fi
      sleep 0.05
    done
    acquired=1
    ensure_omdb_log_header || exit 1
    printf '%s\n' "$line" >> "$OMDB_LOG" || exit 1
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

poster_url_is_allowed() {
  local url="$1" authority host allowed
  local -a allowed_hosts=()
  [[ "$url" == https://* ]] || return 1
  authority="${url#https://}"
  authority="${authority%%/*}"
  [[ -n "$authority" && "$authority" != *@* && "$authority" != \[* ]] || return 1
  host="$(lowercase "${authority%%:*}")"
  IFS=',' read -r -a allowed_hosts <<< "${POSTER_ALLOWED_HOSTS:-}"
  for allowed in "${allowed_hosts[@]+"${allowed_hosts[@]}"}"; do
    allowed="$(lowercase "$(trim_whitespace "$allowed")")"
    [[ -n "$allowed" ]] || continue
    if [[ "$host" == "$allowed" || "$host" == *."$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

poster_extension_from_magic() {
  local path="$1" header
  header="$(od -An -tx1 -N12 "$path" 2>/dev/null | tr -d '[:space:]')"
  case "$header" in
    ffd8ff*) printf jpg ;;
    89504e470d0a1a0a*) printf png ;;
    *) return 1 ;;
  esac
}

download_poster() {
  local url="$1" output_base="$2" content_type extension temporary output actual_size
  command -v curl >/dev/null 2>&1 || return 1
  [[ -n "$url" && "$url" != "N/A" ]] || return 1
  if ! poster_url_is_allowed "$url"; then
    log_warn 'Poster URL was rejected by the HTTPS host allowlist.'
    return 1
  fi
  temporary="${output_base}.download"
  if ! content_type="$(curl --silent --show-error --fail \
      --connect-timeout "$OMDB_CONNECT_TIMEOUT" --max-time "$OMDB_MAX_TIME" \
      --retry "$OMDB_RETRIES" --retry-delay 1 \
      --max-filesize "$POSTER_MAX_BYTES" --proto '=https' \
      --output "$temporary" --write-out '%{content_type}' -- "$url")"; then
    rm -f -- "$temporary"
    return 1
  fi
  if [[ ! -s "$temporary" ]]; then
    rm -f -- "$temporary"
    return 1
  fi
  actual_size="$(file_size_bytes "$temporary" 2>/dev/null || printf 0)"
  if [[ ! "$actual_size" =~ ^[0-9]+$ ]] || (( actual_size > POSTER_MAX_BYTES )); then
    rm -f -- "$temporary"
    log_warn 'Poster response exceeded the configured size limit.'
    return 1
  fi
  if ! extension="$(poster_extension_from_magic "$temporary")"; then
    rm -f -- "$temporary"
    log_warn "Poster response was not a supported JPEG or PNG image: ${content_type:-unknown}"
    return 1
  fi
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
    print_sanitized_file_excerpt "$log_file" 120 || true
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
    "$FFMPEG" -y -v warning -nostdin \
      "${inputs[@]}" "${maps[@]}" -c copy \
      "${artwork_arguments[@]}" \
      "${metadata[@]}" "${MP4_OUTPUT_FLAGS[@]}" "$temporary"
    tag_status=$?
  else
    "$FFMPEG" -y -v warning -nostdin \
      "${inputs[@]}" "${maps[@]}" -c copy \
      "${metadata[@]}" "${MP4_OUTPUT_FLAGS[@]}" "$temporary"
    tag_status=$?
  fi
  if [[ "$tag_status" -ne 0 ]]; then
    log_warn "FFmpeg metadata tagging failed for $(basename "$mp4")."
    return 1
  fi
  validate_media_output "$temporary" "$mp4" probe || return 1
  mv -f -- "$temporary" "$mp4"
}

tag_media_from_omdb() {
  local mp4="$1" work_directory="$2" sidecar="${3:-${1%.*}.omdb.json}" display_path="${4:-$1}" json staged_mp4
  if ! json_is_confirmed_match "$sidecar"; then
    log_info "Skipping MP4 metadata tagging for $(basename "$display_path"); no confirmed OMDb sidecar."
    log_omdb "$display_path" no no '' '' '' '' '' '' '' 'OMDb no match' || \
      log_warn 'Could not append the OMDb audit log.'
    [[ "${STRICT_METADATA:-0}" != "1" ]]
    return $?
  fi
  json="$(cat "$sidecar")"
  staged_mp4="${work_directory}/tag-source.mp4"
  if ! cp -p "$mp4" "$staged_mp4"; then
    log_warn "Could not stage MP4 for metadata tagging: ${mp4}"
    return 1
  fi

  local title plot poster year type imdb_id season episode series description artwork="" tagged=no notes
  title="$(json_string_field "$json" Title 512)"
  plot="$(json_string_field "$json" Plot 10000)"
  poster="$(json_string_field "$json" Poster 2048)"
  year="$(json_string_field "$json" Year 32)"
  type="$(json_string_field "$json" Type 16)"
  imdb_id="$(json_string_field "$json" imdbID 32)"
  season="$(json_string_field "$json" Season 16)"
  episode="$(json_string_field "$json" Episode 16)"
  series="$(json_string_field "$json" Series 512)"

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
    if validate_media_output "$staged_mp4" "$mp4" probe; then
      mv -f "$staged_mp4" "$mp4"
    else
      tagged=no
      notes="${notes}; staged output failed validation"
      rm -f "$staged_mp4"
    fi
  else
    rm -f "$staged_mp4"
  fi

  log_omdb "$display_path" yes "$tagged" "$type" "$title" "$year" "$imdb_id" "$season" "$episode" "$poster" "$notes" || \
    log_warn 'Could not append the OMDb audit log.'
  if [[ "$tagged" == yes ]]; then
    log_info "Tagged MP4 metadata for $(basename "$display_path")"
  else
    log_warn "OMDb metadata was found for $(basename "$display_path"), but tagging did not complete."
  fi
  [[ "$tagged" == yes ]]
}
