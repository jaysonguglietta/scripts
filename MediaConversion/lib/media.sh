#!/usr/bin/env bash

# Stream probing, repair, encoding, subtitle extraction, and size-control helpers.

pick_forced_eng_sub_pos() {
  local file="$1"
  if [[ "$FORCED_SUBTITLE_STREAM" != "auto" ]]; then
    printf '%s' "$FORCED_SUBTITLE_STREAM"
    return 0
  fi

  "$FFPROBE" -v error -select_streams s \
    -show_entries stream_disposition=forced:stream_tags=language,title \
    -of csv=p=0:s='|' "$file" | awk -F'|' -v title_fallback="$ALLOW_FORCED_TITLE_FALLBACK" '
      BEGIN { position=0; best=-1 }
      {
        forced=$1+0
        language=tolower($2)
        title=tolower($3)
        gsub(/_/, "-", language)
        english=(language=="eng" || language=="en" || language=="english" || language ~ /^eng-/ || language ~ /^en-/)
        title_forced=(title ~ /(^|[^[:alpha:]])forced([^[:alpha:]]|$)/)
        title_english=(title ~ /(^|[^[:alpha:]])english([^[:alpha:]]|$)/ || title ~ /(^|[^[:alpha:]])eng([^[:alpha:]]|$)/)
        if (!english && (language=="" || language=="und" || language=="unknown") && title_english) english=1
        if (english && (forced==1 || (title_fallback==1 && title_forced)) && best==-1) best=position
        position++
      }
      END { if (best!=-1) print best }
    '
}

has_forced_eng_subs() {
  [[ -n "$(pick_forced_eng_sub_pos "$1")" ]]
}

print_forced_sub_status() {
  local file="$1"
  if has_forced_eng_subs "$file"; then
    log_info 'Forced English Subtitles = True'
  else
    log_info 'Forced English Subtitles = False'
  fi
}

get_subtitle_codec_by_pos() {
  local file="$1" position="$2"
  "$FFPROBE" -v error -select_streams s \
    -show_entries stream=codec_name -of csv=p=0 "$file" |
    awk -v position="$position" 'NR-1==position { print; exit }'
}

subtitle_codec_supports_mov_text() {
  case "$1" in
    mov_text|subrip|ass|ssa|webvtt) return 0 ;;
    *) return 1 ;;
  esac
}

pick_best_eng_audio_stream_index() {
  "$FFPROBE" -v error -select_streams a \
    -show_entries stream=index,codec_name,channels:stream_disposition=default,comment,hearing_impaired,visual_impaired,descriptions:stream_tags=language,title \
    -of csv=p=0:s='|' "$1" | awk -F'|' '
      BEGIN { best_stream=""; best_score=-100000 }
      {
        stream_id=$1
        channels=$3+0
        is_default=$4+0
        is_comment=$5+0
        hearing=$6+0
        visual=$7+0
        descriptions=$8+0
        language=tolower($9)
        title=tolower($10)
        gsub(/_/, "-", language)
        english=(language=="eng" || language=="en" || language=="english" || language ~ /^eng-/ || language ~ /^en-/)
        if (!english) next

        score=(channels * 10) + (is_default * 100)
        if (is_comment || hearing || visual || descriptions) score-=1000
        if (title ~ /commentary|audio description|descriptive|director|cast commentary|isolated score/) score-=1000
        if (score > best_score) { best_score=score; best_stream=stream_id }
      }
      END { if (best_stream!="") print best_stream }
    '
}

pick_best_untagged_audio_stream_index() {
  "$FFPROBE" -v error -select_streams a \
    -show_entries stream=index,codec_name,channels:stream_disposition=default,comment,hearing_impaired,visual_impaired,descriptions:stream_tags=language,title \
    -of csv=p=0:s='|' "$1" | awk -F'|' '
      BEGIN { best_stream=""; best_score=-100000 }
      {
        stream_id=$1
        channels=$3+0
        is_default=$4+0
        is_comment=$5+0
        hearing=$6+0
        visual=$7+0
        descriptions=$8+0
        language=tolower($9)
        title=tolower($10)
        if (!(language=="" || language=="und" || language=="unknown")) next

        score=(channels * 10) + (is_default * 100)
        if (is_comment || hearing || visual || descriptions) score-=1000
        if (title ~ /commentary|audio description|descriptive|director|cast commentary|isolated score/) score-=1000
        if (score > best_score) { best_score=score; best_stream=stream_id }
      }
      END { if (best_stream!="") print best_stream }
    '
}

pick_audio_stream_index() {
  local file="$1" index=""
  if [[ "$AUDIO_STREAM_INDEX" != "auto" ]]; then
    printf '%s|manual' "$AUDIO_STREAM_INDEX"
    return 0
  fi

  index="$(pick_best_eng_audio_stream_index "$file")"
  if [[ -n "$index" ]]; then
    printf '%s|english' "$index"
    return 0
  fi

  if [[ "$ALLOW_UNTAGGED_AUDIO_FALLBACK" == "1" ]]; then
    index="$(pick_best_untagged_audio_stream_index "$file")"
    if [[ -n "$index" ]]; then
      printf '%s|untagged' "$index"
      return 0
    fi
  fi
  return 1
}

get_audio_stream_language() {
  local file="$1" stream_index="$2"
  "$FFPROBE" -v error -select_streams a \
    -show_entries stream=index:stream_tags=language -of csv=p=0 "$file" |
    awk -F',' -v stream_id="$stream_index" '$1==stream_id { print tolower($2); exit }'
}

get_audio_codec_and_channels() {
  local file="$1" stream_index="$2"
  "$FFPROBE" -v error -select_streams a \
    -show_entries stream=index,codec_name,channels -of csv=p=0 "$file" |
    awk -F',' -v stream_id="$stream_index" '$1==stream_id { print $2 "," $3; exit }'
}

build_audio_args() {
  local stream_index="$1" codec="$2" channels="$3" size_cap_bytes="${4:-}"
  local -a arguments=(-map "0:${stream_index}")
  local may_copy=0
  if [[ -z "$size_cap_bytes" && ( "$codec" == "eac3" || "$codec" == "ac3" ) ]]; then
    may_copy=1
  fi

  if [[ "$AUDIO_MODE" == "stereo" || "$channels" -lt 6 ]]; then
    arguments+=(
      -c:a:0 aac -b:a:0 "$AAC_STEREO_BR" -ac:a:0 2
      -disposition:a:0 default
      -metadata:s:a:0 'title=English Stereo'
      -metadata:s:a:0 language=eng
    )
  elif [[ "$AUDIO_MODE" == "surround" ]]; then
    if (( may_copy == 1 )); then
      arguments+=(-c:a:0 copy)
    else
      arguments+=(-c:a:0 ac3 -b:a:0 "$AC3_51_BR" -ac:a:0 6 -channel_layout:a:0 5.1)
    fi
    arguments+=(
      -disposition:a:0 default
      -metadata:s:a:0 'title=English 5.1'
      -metadata:s:a:0 language=eng
    )
  else
    if (( may_copy == 1 )); then
      arguments+=(-c:a:0 copy)
    else
      arguments+=(-c:a:0 ac3 -b:a:0 "$AC3_51_BR" -ac:a:0 6 -channel_layout:a:0 5.1)
    fi
    arguments+=(
      -map "0:${stream_index}"
      -c:a:1 aac -b:a:1 "$AAC_STEREO_BR" -ac:a:1 2
      -disposition:a:0 default -disposition:a:1 0
      -metadata:s:a:0 'title=English 5.1'
      -metadata:s:a:1 'title=English Stereo'
      -metadata:s:a:0 language=eng
      -metadata:s:a:1 language=eng
    )
  fi
  printf '%s\n' "${arguments[@]}"
}

audio_total_kbps_for_budget() {
  local channels="$1" ac3_kbps aac_kbps
  ac3_kbps="${AC3_51_BR%k}"
  aac_kbps="${AAC_STEREO_BR%k}"
  if [[ "$AUDIO_MODE" == "stereo" || "$channels" -lt 6 ]]; then
    printf '%s' "$aac_kbps"
  elif [[ "$AUDIO_MODE" == "surround" ]]; then
    printf '%s' "$ac3_kbps"
  else
    printf '%s' $((ac3_kbps + aac_kbps))
  fi
}

x264_extra_args() {
  local -a arguments=()
  [[ "$X264_THREADS" != "0" ]] && arguments+=(-threads "$X264_THREADS")
  [[ "$USE_VBV" == "1" ]] && arguments+=(-x264-params "vbv-maxrate=${VBV_MAXRATE}:vbv-bufsize=${VBV_BUFSIZE}")
  (( ${#arguments[@]} > 0 )) && printf '%s\n' "${arguments[@]}"
}

get_video_codec_name() {
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$1" | head -n 1
}

video_codec_can_copy_to_mp4() {
  [[ "$1" == "h264" || "$1" == "hevc" ]]
}

repair_mkv() {
  local input="$1" output="$2" log_file="$3"
  if command -v mkvmerge >/dev/null 2>&1; then
    if mkvmerge -o "$output" "$input" >"$log_file" 2>&1; then
      return 0
    fi
    log_warn 'mkvmerge repair failed; trying FFmpeg remux repair.'
  fi
  "$FFMPEG" -y -fflags +discardcorrupt -err_detect ignore_err \
    -i "$input" -map 0 -c copy "$output" >"$log_file" 2>&1
}

target_payload_budget_bytes() {
  local budget="$1"
  if (( MP4_TAG_HEADROOM_BYTES > 0 )); then
    budget=$((budget - MP4_TAG_HEADROOM_BYTES))
  fi
  # Keep a small allowance for muxing variance and metadata growth.
  budget=$((budget * SIZE_SAFETY_PERCENT / 100))
  printf '%s' "$budget"
}

target_max_bytes_for_type() {
  local detected_type="$1"
  if [[ -n "$TARGET_SIZE_BYTES" ]]; then
    printf '%s' "$TARGET_SIZE_BYTES"
  elif [[ "$detected_type" == "tv" ]]; then
    printf '%s' "$TV_MAX_BYTES"
  fi
}

build_video_filter_arg() {
  local source="$1" subtitle_action="$2" forced_position="$3"
  local -a filters=()
  if (( MAX_HEIGHT > 0 )); then
    filters+=("scale=-2:'min(${MAX_HEIGHT},ih)'")
  fi
  if [[ "$subtitle_action" == "burn" ]]; then
    local escaped_source
    escaped_source="$(ffmpeg_subtitles_filter_escape "$source")"
    filters+=("subtitles='${escaped_source}':si=${forced_position}")
  fi
  local IFS=,
  printf '%s' "${filters[*]-}"
}

ffmpeg_subtitles_filter_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//:/\\:}"
  value="${value//\'/\\\'}"
  value="${value//[/\\[}"
  value="${value//]/\\]}"
  value="${value//,/\\,}"
  value="${value//;/\\;}"
  printf '%s' "$value"
}

can_use_fast_video_copy() {
  local file="$1" detected_type="$2" codec="$3" subtitle_action="$4"
  [[ "$FAST_VIDEO_COPY" == "1" ]] || return 1
  [[ "$subtitle_action" != "burn" ]] || return 1
  [[ "$QUALITY_ENCODE" != "1" ]] || return 1
  (( MAX_HEIGHT == 0 )) || return 1
  video_codec_can_copy_to_mp4 "$codec" || return 1

  local target_max source_size payload_budget
  target_max="$(target_max_bytes_for_type "$detected_type")"
  if [[ -n "$target_max" ]]; then
    source_size="$(file_size_bytes "$file" 2>/dev/null || true)"
    payload_budget="$(target_payload_budget_bytes "$target_max")"
    [[ -n "$source_size" && "$source_size" -le "$payload_budget" ]] || return 1
  fi
}

extract_forced_eng_subtitle() {
  local file="$1" position="$2" codec="$3" output_base="$4"
  [[ -n "$position" ]] || return 0
  local extension codec_argument output
  case "$codec" in
    mov_text|subrip) extension=srt; codec_argument=srt ;;
    webvtt) extension=vtt; codec_argument=webvtt ;;
    ass|ssa) extension=ass; codec_argument=ass ;;
    *) extension=mks; codec_argument=copy ;;
  esac
  output="${output_base}.${extension}"
  log_info "Extracting forced English subtitle to $(basename "$output")"
  if [[ "$codec_argument" == "copy" ]]; then
    "$FFMPEG" -y -v warning -i "$file" -map "0:s:${position}" -map_metadata -1 -c:s copy "$output"
  else
    "$FFMPEG" -y -v warning -i "$file" -map "0:s:${position}" -map_metadata -1 -c:s "$codec_argument" "$output"
  fi
  LAST_EXTRACTED_SUBTITLE="$output"
}

calculate_video_bitrate_kbps() {
  local source="$1" size_cap_bytes="$2" channels="$3" override="${4:-}"
  if [[ -n "$override" ]]; then
    printf '%s' "$override"
    return 0
  fi

  local duration payload_bytes target_bps audio_kbps video_bps video_kbps
  duration="$(ffprobe_duration "$source")"
  [[ -n "$duration" ]] && awk -v value="$duration" 'BEGIN { exit !(value > 0) }' || return 1
  payload_bytes="$(target_payload_budget_bytes "$size_cap_bytes")"
  target_bps="$(awk -v bytes="$payload_bytes" -v duration="$duration" 'BEGIN { printf "%.0f", (bytes * 8) / duration }')"
  audio_kbps="$(audio_total_kbps_for_budget "$channels")"
  video_bps="$(awk -v target="$target_bps" -v audio="$audio_kbps" 'BEGIN { value=target-(audio*1000); if (value<200000) value=200000; printf "%.0f", value }')"
  video_kbps=$(((video_bps + 500) / 1000))
  printf '%s' "$video_kbps"
}

run_standard_encode() {
  local source="$1" output="$2" subtitle_action="$3" video_bitrate="$4"
  shift 4
  local audio_count="$1"
  shift
  local -a audio_arguments=("${@:1:audio_count}")
  shift "$audio_count"
  local subtitle_count="$1"
  shift
  local -a subtitle_arguments=("${@:1:subtitle_count}")
  shift "$subtitle_count"
  local filter_count="$1"
  shift
  local -a filter_arguments=("${@:1:filter_count}")
  local -a x264_arguments=()
  local argument
  while IFS= read -r argument; do
    [[ -n "$argument" ]] && x264_arguments+=("$argument")
  done < <(x264_extra_args)

  if [[ "$QUALITY_ENCODE" == "1" ]]; then
    log_info "Quality encode using software HEVC (${X265_PRESET})."
    local -a x265_rate=(-crf "$X265_CRF")
    [[ -n "$video_bitrate" ]] && x265_rate=(-b:v "${video_bitrate}k" -maxrate "${video_bitrate}k" -bufsize "${VBV_BUFSIZE}k")
    if "$FFMPEG" -y -stats "${TIMING_IN_FLAGS[@]+"${TIMING_IN_FLAGS[@]}"}" -i "$source" \
        "${TIMING_OUT_FLAGS[@]+"${TIMING_OUT_FLAGS[@]}"}" \
        -map 0:v:0 "${audio_arguments[@]}" \
        "${subtitle_arguments[@]+"${subtitle_arguments[@]}"}" \
        "${filter_arguments[@]+"${filter_arguments[@]}"}" \
        -c:v libx265 "${x265_rate[@]}" -preset "$X265_PRESET" -tag:v hvc1 \
        "${MP4_OUTPUT_FLAGS[@]}" "$output"; then
      return 0
    fi
    log_warn 'Software HEVC failed; trying the standard encoder path.'
  fi

  if [[ "$subtitle_action" == "burn" ]]; then
    log_info 'Burning forced English subtitles with x264.'
    local -a x264_rate=(-crf "$X264_CRF")
    [[ -n "$video_bitrate" ]] && x264_rate=(-b:v "${video_bitrate}k" -maxrate "${video_bitrate}k" -bufsize "${VBV_BUFSIZE}k")
    "$FFMPEG" -y -stats "${TIMING_IN_FLAGS[@]+"${TIMING_IN_FLAGS[@]}"}" -i "$source" \
      "${TIMING_OUT_FLAGS[@]+"${TIMING_OUT_FLAGS[@]}"}" \
      -map 0:v:0 "${audio_arguments[@]}" \
      "${filter_arguments[@]+"${filter_arguments[@]}"}" \
      -c:v libx264 "${x264_rate[@]}" -preset "$X264_PRESET" \
      "${x264_arguments[@]+"${x264_arguments[@]}"}" \
      "${MP4_OUTPUT_FLAGS[@]}" "$output"
    return $?
  fi

  log_info 'Trying Intel QSV HEVC.'
  local -a qsv_rate=(-global_quality "$QSV_GLOBAL_QUALITY")
  [[ -n "$video_bitrate" ]] && qsv_rate=(-b:v "${video_bitrate}k" -maxrate "${video_bitrate}k")
  if "$FFMPEG" -y -stats "${TIMING_IN_FLAGS[@]+"${TIMING_IN_FLAGS[@]}"}" -i "$source" \
      "${TIMING_OUT_FLAGS[@]+"${TIMING_OUT_FLAGS[@]}"}" \
      -map 0:v:0 "${audio_arguments[@]}" \
      "${subtitle_arguments[@]+"${subtitle_arguments[@]}"}" \
      "${filter_arguments[@]+"${filter_arguments[@]}"}" \
      -c:v hevc_qsv "${qsv_rate[@]}" -preset "$QSV_PRESET" -tag:v hvc1 \
      "${MP4_OUTPUT_FLAGS[@]}" "$output"; then
    return 0
  fi

  log_warn 'QSV failed; falling back to CPU x264.'
  local -a fallback_rate=(-crf "$X264_CRF")
  [[ -n "$video_bitrate" ]] && fallback_rate=(-b:v "${video_bitrate}k" -maxrate "${video_bitrate}k" -bufsize "${VBV_BUFSIZE}k")
  "$FFMPEG" -y -stats "${TIMING_IN_FLAGS[@]+"${TIMING_IN_FLAGS[@]}"}" -i "$source" \
    "${TIMING_OUT_FLAGS[@]+"${TIMING_OUT_FLAGS[@]}"}" \
    -map 0:v:0 "${audio_arguments[@]}" \
    "${subtitle_arguments[@]+"${subtitle_arguments[@]}"}" \
    "${filter_arguments[@]+"${filter_arguments[@]}"}" \
    -c:v libx264 "${fallback_rate[@]}" -preset "$X264_PRESET" \
    "${x264_arguments[@]+"${x264_arguments[@]}"}" \
    "${MP4_OUTPUT_FLAGS[@]}" "$output"
}

convert_from_source() {
  local source="$1" output="$2" detected_type="$3" original_input="$4" work_directory="$5"
  local bitrate_override="${6:-}" force_video_encode="${7:-0}"
  local audio_index selected_audio_kind codec channels audio_language video_codec
  local forced_position="" subtitle_codec="" subtitle_action=none video_filter=""
  local size_cap_bytes video_bitrate="" fast_copy_log
  local -a audio_arguments=() subtitle_arguments=() filter_arguments=() video_copy_arguments=(-c:v copy)

  # shellcheck disable=SC2034 # Read by the worker after this function returns.
  LAST_EXTRACTED_SUBTITLE=""
  LAST_VIDEO_BITRATE_KBPS=""
  LAST_SIZE_CAP_BYTES=""
  LAST_USED_FAST_COPY=0

  IFS='|' read -r audio_index selected_audio_kind <<< "$(pick_audio_stream_index "$source" || true)"
  if [[ -z "$audio_index" ]]; then
    log_error "No eligible English or untagged audio stream: ${original_input}"
    return 20
  fi
  IFS=',' read -r codec channels <<< "$(get_audio_codec_and_channels "$source" "$audio_index")"
  [[ -n "$codec" && "$channels" =~ ^[0-9]+$ ]] || { log_error "Could not inspect audio stream ${audio_index}."; return 20; }
  audio_language="$(get_audio_stream_language "$source" "$audio_index" || true)"
  video_codec="$(get_video_codec_name "$source")"
  size_cap_bytes="$(target_max_bytes_for_type "$detected_type")"
  # shellcheck disable=SC2034 # Read by the worker after this function returns.
  LAST_SIZE_CAP_BYTES="$size_cap_bytes"
  local argument
  while IFS= read -r argument; do
    [[ -n "$argument" ]] && audio_arguments+=("$argument")
  done < <(build_audio_args "$audio_index" "$codec" "$channels" "$size_cap_bytes")

  if [[ "$selected_audio_kind" == "untagged" ]]; then
    log_warn "Using untagged/undetermined audio stream 0:${audio_index}."
  elif [[ "$selected_audio_kind" == "manual" ]]; then
    log_info "Using manually selected audio stream 0:${audio_index}."
  fi
  log_info "Audio mode=${AUDIO_MODE} stream=0:${audio_index} codec=${codec} channels=${channels} language=${audio_language:-untagged}"
  log_info "Source video codec=${video_codec:-unknown}"

  forced_position="$(pick_forced_eng_sub_pos "$source" || true)"
  if [[ -n "$forced_position" ]]; then
    subtitle_codec="$(get_subtitle_codec_by_pos "$source" "$forced_position")"
    case "$SUBTITLE_MODE" in
      burn)
        if subtitle_codec_supports_mov_text "$subtitle_codec"; then
          subtitle_action=burn
        else
          subtitle_action=extract
          log_warn "Subtitle codec ${subtitle_codec:-unknown} cannot use the text burn-in filter; extracting a sidecar."
        fi
        ;;
      copy)
        if subtitle_codec_supports_mov_text "$subtitle_codec"; then
          subtitle_action=copy
          subtitle_arguments=(-map "0:s:${forced_position}" -c:s mov_text -metadata:s:s:0 language=eng -disposition:s:0 forced)
        else
          subtitle_action=extract
          log_warn "Subtitle codec ${subtitle_codec:-unknown} cannot be stored as MP4 text; extracting a sidecar."
        fi
        ;;
      extract) subtitle_action=extract ;;
    esac
  fi
  log_info "Subtitle action=${subtitle_action}"

  video_filter="$(build_video_filter_arg "$source" "$subtitle_action" "$forced_position")"
  [[ -n "$video_filter" ]] && filter_arguments=(-vf "$video_filter")

  if [[ "$force_video_encode" != "1" ]] && \
      can_use_fast_video_copy "$source" "$detected_type" "$video_codec" "$subtitle_action"; then
    log_info "Using fast ${video_codec} video-copy path."
    [[ "$video_codec" == "hevc" ]] && video_copy_arguments+=(-tag:v hvc1)
    fast_copy_log="${work_directory}/fast-copy.log"
    if "$FFMPEG" -y -stats "${TIMING_IN_FLAGS[@]+"${TIMING_IN_FLAGS[@]}"}" -i "$source" \
        "${TIMING_OUT_FLAGS[@]+"${TIMING_OUT_FLAGS[@]}"}" \
        -map 0:v:0 -copytb 1 "${audio_arguments[@]}" \
        "${subtitle_arguments[@]+"${subtitle_arguments[@]}"}" \
        "${video_copy_arguments[@]}" "${MP4_OUTPUT_FLAGS[@]}" "$output" \
        2>&1 | tee "$fast_copy_log" >&2; then
      if ! log_has_non_monotonic_dts "$fast_copy_log"; then
        if [[ "$subtitle_action" == "extract" ]]; then
          extract_forced_eng_subtitle "$source" "$forced_position" "$subtitle_codec" "${work_directory}/forced-subtitle" || return 10
        fi
        # shellcheck disable=SC2034 # Read by the worker after this function returns.
        LAST_USED_FAST_COPY=1
        return 0
      fi
      rm -f "$output"
      if [[ "$REPAIR_MODE" != "never" && "$source" == "$original_input" ]]; then
        return 11
      fi
      log_warn 'Fast copy had non-monotonic timestamps; falling back to encoding.'
    else
      rm -f "$output"
      log_warn 'Fast video copy failed; falling back to encoding.'
    fi
  fi

  if [[ -n "$size_cap_bytes" ]]; then
    if ! video_bitrate="$(calculate_video_bitrate_kbps "$source" "$size_cap_bytes" "$channels" "$bitrate_override")"; then
      log_warn 'Could not calculate a target bitrate; continuing without a size cap.'
      video_bitrate=""
    else
      # shellcheck disable=SC2034 # Read by the worker after this function returns.
      LAST_VIDEO_BITRATE_KBPS="$video_bitrate"
      log_info "Size cap=${size_cap_bytes} bytes; video bitrate=${video_bitrate}k; safety=${SIZE_SAFETY_PERCENT}%"
    fi
  fi

  if ! run_standard_encode "$source" "$output" "$subtitle_action" "$video_bitrate" \
      "${#audio_arguments[@]}" "${audio_arguments[@]}" \
      "${#subtitle_arguments[@]}" "${subtitle_arguments[@]+"${subtitle_arguments[@]}"}" \
      "${#filter_arguments[@]}" "${filter_arguments[@]+"${filter_arguments[@]}"}"; then
    rm -f "$output"
    return 10
  fi

  if [[ "$subtitle_action" == "extract" ]]; then
    extract_forced_eng_subtitle "$source" "$forced_position" "$subtitle_codec" "${work_directory}/forced-subtitle" || return 10
  fi
  return 0
}

calculate_retry_bitrate() {
  local current_kbps="$1" target_bytes="$2" actual_bytes="$3"
  awk -v current="$current_kbps" -v target="$target_bytes" -v actual="$actual_bytes" '
    BEGIN {
      value = current * target / actual * 0.97
      if (value < 200) value = 200
      printf "%.0f\n", value
    }
  '
}
