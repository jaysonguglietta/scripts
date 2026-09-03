#!/usr/bin/env bash
# Sourced-module state and the mocked AtomicParsley function are consumed dynamically.
# shellcheck disable=SC1091,SC2034,SC2317,SC2329
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
MOCK_BIN="${TEST_DIR}/mocks"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/media-conversion-tests.XXXXXX")"
export MEDIA_STATE_DIR="${TEST_ROOT}/state"
PASS_COUNT=0
FAIL_COUNT=0
TEST_FAILED=0

cleanup_tests() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_tests EXIT

# shellcheck source=../convert.sh
source "${PROJECT_DIR}/convert.sh"

assert_equal() {
  local expected="$1" actual="$2" message="${3:-values differ}"
  if [[ "$expected" != "$actual" ]]; then
    printf 'ASSERT: %s (expected=%s actual=%s)\n' "$message" "$expected" "$actual" >&2
    TEST_FAILED=1
    return 1
  fi
}

assert_file_exists() {
  [[ -f "$1" ]] || { printf 'ASSERT: file does not exist: %s\n' "$1" >&2; TEST_FAILED=1; return 1; }
}

assert_file_missing() {
  [[ ! -e "$1" ]] || { printf 'ASSERT: file should not exist: %s\n' "$1" >&2; TEST_FAILED=1; return 1; }
}

run_test() {
  local name="$1"
  shift
  if ( TEST_FAILED=0; "$@"; status=$?; (( status == 0 && TEST_FAILED == 0 )) ); then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok - %s\n' "$name"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'not ok - %s\n' "$name"
  fi
}

test_size_parser() {
  assert_equal 1610612736 "$(parse_size_to_bytes 1.5GB)" '1.5GB parsing'
  ! parse_size_to_bytes nonsense >/dev/null 2>&1
}

test_language_helpers() {
  language_is_english eng
  language_is_english en-US
  language_is_english en_GB
  language_is_untagged ''
  language_is_untagged und
  ! language_is_english fra
}

test_log_and_filename_sanitizing() {
  local long_name sanitized bytes
  assert_equal '\e[31mboom' "$(safe_log_text $'\033[31mboom\a')" 'terminal controls are escaped or removed' || return 1
  assert_equal 'untitled.mp4' "$(sanitize_filename ---.mp4)" 'empty filename stem gets a safe fallback' || return 1
  long_name="$(printf '%0240d' 0).mp4"
  sanitized="$(sanitize_filename "$long_name")"
  bytes="$(LC_ALL=C printf '%s' "$sanitized" | wc -c | tr -d '[:space:]')"
  (( bytes <= 220 )) || return 1
}

test_atomic_output_reservation() {
  local directory first second first_path first_lock second_path second_lock
  directory="${TEST_ROOT}/reservations"
  mkdir -p "$directory"
  first="$(reserve_output_path "${directory}/Movie.mp4")"
  second="$(reserve_output_path "${directory}/Movie.mp4")"
  IFS='|' read -r first_path first_lock <<< "$first"
  IFS='|' read -r second_path second_lock <<< "$second"
  [[ "$first_path" != "$second_path" ]] || return 1
  assert_equal "${directory}/Movie.mp4" "$first_path"
  assert_equal "${directory}/Movie (1).mp4" "$second_path"
  release_output_reservation "$first_lock"
  release_output_reservation "$second_lock"
}

test_no_clobber_publication() {
  local directory="${TEST_ROOT}/no-clobber" source destination
  mkdir -p "$directory"
  source="${directory}/source.mp4"
  destination="${directory}/destination.mp4"
  printf source > "$source"
  printf existing > "$destination"
  ! move_file_no_clobber "$source" "$destination" || return 1
  assert_equal existing "$(cat "$destination")" 'existing output is preserved' || return 1
  assert_file_exists "$source" || return 1
  rm -f "$destination"
  move_file_no_clobber "$source" "$destination" || return 1
  assert_file_missing "$source" || return 1
  assert_equal source "$(cat "$destination")" 'new output is published'
}

test_reservation_creation_failure_is_bounded() {
  local directory="${TEST_ROOT}/reservation-failure"
  mkdir -p "$directory"
  mkdir() { return 1; }
  ! reserve_output_path "${directory}/Movie.mp4" >/dev/null 2>&1
}

test_both_dts_warning_spellings() {
  local old_log="${TEST_ROOT}/old.log" new_log="${TEST_ROOT}/new.log"
  printf '%s\n' 'Non-monotonous DTS in output stream' > "$old_log"
  printf '%s\n' 'Non-monotonic DTS; previous: 10' > "$new_log"
  log_has_non_monotonic_dts "$old_log"
  log_has_non_monotonic_dts "$new_log"
}

test_subtitle_language_variants() {
  FFPROBE="${MOCK_BIN}/ffprobe"
  FORCED_SUBTITLE_STREAM=auto
  ALLOW_FORCED_TITLE_FALLBACK=1
  assert_equal 0 "$(pick_forced_eng_sub_pos "${TEST_ROOT}/en-sub.mkv")" 'en subtitle tag'
  assert_equal 0 "$(pick_forced_eng_sub_pos "${TEST_ROOT}/title-sub.mkv")" 'forced title fallback'
}

test_audio_ranking_and_und_fallback() {
  FFPROBE="${MOCK_BIN}/ffprobe"
  AUDIO_STREAM_INDEX=auto
  AUDIO_TRACK_POSITION=auto
  ALLOW_UNTAGGED_AUDIO_FALLBACK=1
  assert_equal '2|english' "$(pick_audio_stream_index "${TEST_ROOT}/commentary.mkv")" 'main audio beats commentary'
  assert_equal '1|untagged' "$(pick_audio_stream_index "${TEST_ROOT}/und-audio.mkv")" 'und audio fallback'
}

test_commentary_and_manual_language_policy() {
  FFPROBE="${MOCK_BIN}/ffprobe"
  AUDIO_STREAM_INDEX=auto
  AUDIO_TRACK_POSITION=auto
  ALLOW_UNTAGGED_AUDIO_FALLBACK=1
  ALLOW_COMMENTARY_AUDIO_FALLBACK=0
  FORCE_SELECTED_AUDIO_AS_ENGLISH=0
  ! pick_audio_stream_index "${TEST_ROOT}/commentary-only.mkv" >/dev/null || return 1
  ! selected_audio_language_allowed fra manual || return 1
  FORCE_SELECTED_AUDIO_AS_ENGLISH=1
  selected_audio_language_allowed fra manual
}

test_missing_eligible_audio_fails_closed() {
  FFPROBE="${MOCK_BIN}/ffprobe"
  AUDIO_STREAM_INDEX=auto
  AUDIO_TRACK_POSITION=auto
  ALLOW_UNTAGGED_AUDIO_FALLBACK=1
  ! pick_audio_stream_index "${TEST_ROOT}/no-audio.mkv" >/dev/null
}

test_stale_repair_inputs_are_ignored() {
  local directory="${TEST_ROOT}/discovery"
  mkdir -p "$directory"
  printf input > "${directory}/Movie.mkv"
  printf stale > "${directory}/Movie.repaired.mkv"
  printf stale > "${directory}/Movie.part.mkv"
  ln -s Movie.mkv "${directory}/Link.mkv"
  (
    cd "$directory" || exit 1
    discover_input_files
    assert_equal 1 "${#FILES[@]}" 'discovered input count' || return 1
    assert_equal ./Movie.mkv "${FILES[0]}" 'only real source is discovered'
  )
}

test_manual_subtitle_must_be_forced_english() {
  FFPROBE="${MOCK_BIN}/ffprobe"
  FORCED_SUBTITLE_STREAM=0
  ALLOW_FORCED_TITLE_FALLBACK=1
  FORCE_SELECTED_SUBTITLE_AS_ENGLISH=0
  ! pick_forced_eng_sub_pos "${TEST_ROOT}/manual-french-sub.mkv" >/dev/null 2>&1 || return 1
  FORCE_SELECTED_SUBTITLE_AS_ENGLISH=1
  assert_equal 0 "$(pick_forced_eng_sub_pos "${TEST_ROOT}/manual-french-sub.mkv")" 'explicit subtitle override' || return 1
}

test_invalid_configuration_is_rejected() {
  JOBS=0
  load_defaults
  ! validate_config >/dev/null 2>&1
}

test_config_is_data_only_private_and_not_exported() {
  local directory="${TEST_ROOT}/config" config sentinel
  directory="${TEST_ROOT}/config"
  config="${directory}/media-conversion.env"
  sentinel="${directory}/executed"
  mkdir -p "$directory"
  printf 'OMDB_API_KEY=$(touch %s)\nJOBS=2\n' "$sentinel" > "$config"
  chmod 600 "$config"
  unset OMDB_API_KEY JOBS
  load_config_file "$config" >/dev/null || return 1
  assert_file_missing "$sentinel" || return 1
  [[ "$OMDB_API_KEY" == *'$(touch '* ]] || return 1
  ! env | grep -q '^OMDB_API_KEY=' || return 1

  chmod 644 "$config"
  ! load_config_file "$config" >/dev/null 2>&1 || return 1
  chmod 600 "$config"
  printf '%s\n' 'UNSUPPORTED_SETTING=1' >> "$config"
  ! load_config_file "$config" >/dev/null 2>&1
}

test_state_rejects_public_custom_log() {
  local directory="${TEST_ROOT}/state-permissions" log
  directory="${TEST_ROOT}/state-permissions"
  log="${directory}/metadata.csv"
  mkdir -p "$directory"
  chmod 700 "$directory"
  printf header > "$log"
  chmod 644 "$log"
  MEDIA_STATE_DIR="$directory"
  OMDB_LOG="$log"
  OMDB_LOG_LOCK="${log}.lock"
  OMDB_LOG_IS_PER_RUN=0
  ! initialize_state_directory >/dev/null 2>&1 || return 1
  chmod 600 "$log"
  initialize_state_directory >/dev/null
}

test_sidecars_are_regular_and_bounded() {
  command -v jq >/dev/null 2>&1 || return 0
  local directory="${TEST_ROOT}/sidecar-bounds" valid oversized linked
  mkdir -p "$directory"
  valid="${directory}/valid.json"
  oversized="${directory}/oversized.json"
  linked="${directory}/linked.json"
  printf '%s\n' '{"Response":"True","Title":"Movie","Type":"movie","imdbID":"tt123"}' > "$valid"
  cp "$valid" "$oversized"
  printf '%0200d' 0 >> "$oversized"
  ln -s "$valid" "$linked"
  OMDB_RESPONSE_MAX_BYTES=128
  json_is_confirmed_match "$valid" || return 1
  ! json_is_valid "$oversized" || return 1
  ! json_is_valid "$linked"
}

test_metadata_type_controls_episode_size_policy() {
  command -v jq >/dev/null 2>&1 || return 0
  local directory="${TEST_ROOT}/metadata-type" input sidecar
  mkdir -p "$directory"
  input="${directory}/Pilot.mkv"
  sidecar="${input%.*}.omdb.json"
  printf x > "$input"
  printf '%s\n' '{"Response":"True","Title":"Pilot","Type":"episode","imdbID":"tt123","Series":"Example","Season":"1","Episode":"1"}' > "$sidecar"
  OMDB_RESPONSE_MAX_BYTES=1048576
  assert_equal tv "$(determine_media_type "$input")" 'episode metadata selects TV policy'
}

test_rejected_omdb_match_is_not_saved() {
  command -v jq >/dev/null 2>&1 || return 0
  local directory="${TEST_ROOT}/rejected" input sidecar
  mkdir -p "$directory"
  input="${directory}/Wrong.Match.2020.mkv"
  sidecar="${input%.*}.omdb.json"
  printf x > "$input"
  OMDB_REFRESH=1
  OMDB_ENABLED=1
  OMDB_INTERACTIVE=1
  omdb_lookup() { printf '%s' '{"Response":"True","Title":"Wrong","Year":"2020","Type":"movie","imdbID":"tt1"}'; }
  omdb_search() { printf '%s' '{"Response":"False","totalResults":"0"}'; }
  omdb_prompt_available() { return 0; }
  omdb_prompt_read() {
    case "$1" in
      'Accept this match?'*) printf -v "$2" '%s' n ;;
      'Search OMDb for'*) printf -v "$2" '%s' 0 ;;
      *) return 1 ;;
    esac
  }
  omdb_interactive_verify_and_save "$input" >/dev/null
  assert_file_exists "$sidecar"
  assert_equal False "$(jq -r '.Response // "False"' "$sidecar")" 'rejected match should be empty'
}

test_lookup_failure_preserves_sidecar() {
  command -v jq >/dev/null 2>&1 || return 0
  local directory="${TEST_ROOT}/preserve" input sidecar
  mkdir -p "$directory"
  input="${directory}/Movie.2020.mkv"
  sidecar="${input%.*}.omdb.json"
  printf x > "$input"
  printf '%s\n' '{"Response":"True","Title":"Confirmed","Type":"movie","imdbID":"tt1234567"}' > "$sidecar"
  OMDB_REFRESH=1
  OMDB_ENABLED=1
  OMDB_INTERACTIVE=0
  omdb_lookup() { return 1; }
  omdb_interactive_verify_and_save "$input" >/dev/null
  assert_equal Confirmed "$(jq -r .Title "$sidecar")" 'confirmed sidecar must survive outage'
}

test_cached_metadata_is_confirmed_by_default() {
  command -v jq >/dev/null 2>&1 || return 0
  local directory="${TEST_ROOT}/cached-confirmation" input sidecar prompt_count=0
  mkdir -p "$directory"
  input="${directory}/Movie.mkv"
  sidecar="${input%.*}.omdb.json"
  printf x > "$input"
  printf '%s\n' '{"Response":"True","Title":"Movie","Year":"2024","Type":"movie","imdbID":"tt123"}' > "$sidecar"
  OMDB_RESPONSE_MAX_BYTES=1048576
  OMDB_REFRESH=0
  OMDB_INTERACTIVE=1
  OMDB_CONFIRM_CACHED=1
  OMDB_ENABLED=0
  omdb_prompt_available() { return 0; }
  omdb_prompt_read() {
    prompt_count=$((prompt_count + 1))
    printf -v "$2" '%s' y
  }
  omdb_interactive_verify_and_save "$input" >/dev/null || return 1
  assert_equal 1 "$prompt_count" 'cached match prompt count'
}

test_search_result_count_cannot_reach_arithmetic() {
  command -v jq >/dev/null 2>&1 || return 0
  local directory="${TEST_ROOT}/search-count" output sentinel
  mkdir -p "$directory"
  output="${directory}/result.json"
  sentinel="${directory}/executed"
  STRICT_METADATA=0
  OMDB_RESPONSE_MAX_BYTES=1048576
  omdb_search() {
    printf '{"Search":[{"Title":"Movie","Year":"2024","imdbID":"tt123","Type":"movie"}],"totalResults":"x[$(touch %s)]"}' "$sentinel"
  }
  omdb_prompt_read() { printf -v "$2" '%s' 0; }
  omdb_search_and_select "${directory}/Movie.mkv" "$output" Movie >/dev/null || return 1
  assert_file_missing "$sentinel" || return 1
  assert_equal '{}' "$(jq -c . "$output")" 'skip metadata output'
}

test_omdb_key_uses_standard_input() {
  local directory="${TEST_ROOT}/api-key" response
  mkdir -p "$directory"
  OMDB_API_KEY='test-secret-key'
  OMDB_URL='https://example.invalid'
  OMDB_CONNECT_TIMEOUT=1
  OMDB_MAX_TIME=1
  OMDB_RETRIES=0
  OMDB_RESPONSE_MAX_BYTES=1048576
  curl() {
    printf '%s\n' "$*" > "${directory}/arguments"
    cat > "${directory}/stdin"
    printf '%s' '{}'
  }

  response="$(omdb_api_request 't=Movie')" || return 1
  assert_equal '{}' "$response" 'mock API response'
  grep -q 'apikey@-' "${directory}/arguments"
  ! grep -q 'test-secret-key' "${directory}/arguments"
  assert_equal 'test-secret-key' "$(cat "${directory}/stdin")" 'key arrives on stdin'
}

test_poster_mime_controls_extension() {
  local directory="${TEST_ROOT}/poster" path
  mkdir -p "$directory"
  OMDB_CONNECT_TIMEOUT=1
  OMDB_MAX_TIME=1
  OMDB_RETRIES=0
  POSTER_MAX_BYTES=1048576
  POSTER_ALLOWED_HOSTS=example.invalid
  MOCK_POSTER_MIME='image/png'
  curl() {
    local output=""
    while (( $# > 0 )); do
      case "$1" in
        --output) output="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "$MOCK_POSTER_MIME" == image/png ]]; then
      printf '\x89PNG\r\n\x1a\nmock' > "$output"
    else
      printf '<html>not an image</html>' > "$output"
    fi
    printf '%s' "$MOCK_POSTER_MIME"
  }

  path="$(download_poster 'https://example.invalid/poster' "${directory}/poster")" || return 1
  assert_equal "${directory}/poster.png" "$path" 'PNG extension'
  assert_file_exists "$path"

  MOCK_POSTER_MIME='text/html'
  ! download_poster 'https://example.invalid/not-an-image' "${directory}/invalid" >/dev/null
  assert_file_missing "${directory}/invalid.download"

  ! download_poster 'http://example.invalid/poster' "${directory}/http" >/dev/null 2>&1 || return 1
  ! download_poster 'https://example.invalid.evil.test/poster' "${directory}/wrong-host" >/dev/null 2>&1 || return 1
  POSTER_MAX_BYTES=8
  MOCK_POSTER_MIME='image/png'
  ! download_poster 'https://example.invalid/oversized' "${directory}/oversized" >/dev/null 2>&1 || return 1
  assert_file_missing "${directory}/oversized.download"
}

test_duration_and_decode_validation() {
  local directory="${TEST_ROOT}/validation" input output
  mkdir -p "$directory"
  input="${directory}/input.mkv"
  output="${directory}/output.mp4"
  printf input > "$input"
  printf output > "$output"
  DURATION_TOLERANCE_SECONDS=5
  DURATION_TOLERANCE_PERMILLE=1
  durations_are_close 7200 7193 || return 1
  ! durations_are_close 7200 7056 || return 1

  FFPROBE="${MOCK_BIN}/ffprobe"
  FFMPEG="${MOCK_BIN}/ffmpeg"
  VALIDATION_MODE=decode
  export MOCK_AUDIO_LANGUAGE=eng
  export MOCK_DECODE_FAIL=0
  validate_media_output "$output" "$input" || return 1
  export MOCK_AUDIO_LANGUAGE=fra
  ! validate_media_output "$output" "$input" >/dev/null 2>&1 || return 1
  export MOCK_AUDIO_LANGUAGE=eng
  export MOCK_DECODE_FAIL=1
  ! validate_media_output "$output" "$input" >/dev/null 2>&1
}

test_metadata_only_tagging() {
  command -v jq >/dev/null 2>&1 || return 0
  local directory="${TEST_ROOT}/tagging" mp4 sidecar
  directory="${TEST_ROOT}/tagging"
  mkdir -p "$directory"
  mp4="${directory}/Movie.mp4"
  sidecar="${directory}/Movie.omdb.json"
  printf payload > "$mp4"
  printf '%s\n' '{"Response":"True","Title":"Movie","Year":"2024","Type":"movie","imdbID":"tt1234567","Poster":"N/A"}' > "$sidecar"
  FFMPEG="${MOCK_BIN}/ffmpeg"
  FFPROBE="${MOCK_BIN}/ffprobe"
  MP4_OUTPUT_FLAGS=(-movflags +faststart)
  OMDB_LOG="${directory}/metadata.csv"
  OMDB_LOG_LOCK="${directory}/metadata.lock"
  OMDB_CONNECT_TIMEOUT=1
  OMDB_MAX_TIME=1
  OMDB_RETRIES=0
  PATH="${MOCK_BIN}:${PATH}"
  tag_media_from_omdb "$mp4" "$directory"
  assert_file_exists "$mp4"
  grep -q '"yes","yes"' "$OMDB_LOG"
}

test_parallel_failures_are_reported() {
  local directory="${TEST_ROOT}/parallel" log_file status
  mkdir -p "$directory"
  printf input > "${directory}/ok.mkv"
  printf input > "${directory}/fail.mkv"
  log_file="${directory}/run.log"
  (
    cd "$directory" || exit 1
    PATH="${MOCK_BIN}:${PATH}" \
    FFMPEG=ffmpeg FFPROBE=ffprobe JOBS=3 FAST_VIDEO_COPY=0 REPAIR_MODE=never \
    MP4_TAG_HEADROOM_BYTES=0 OMDB_API_KEY='' STRICT_DISK_CHECK=0 \
      "${PROJECT_DIR}/convert.sh" --jobs 3 >"$log_file" 2>&1
  )
  status=$?
  assert_equal 1 "$status" 'batch exit status'
  assert_file_exists "${directory}/ok.mp4"
  assert_file_missing "${directory}/fail.mp4"
  grep -q 'failures=1' "$log_file"
}

test_image_subtitle_is_burned() {
  local directory="${TEST_ROOT}/image-subtitle" log_file command_log
  mkdir -p "$directory"
  printf input > "${directory}/image-sub.mkv"
  log_file="${directory}/run.log"
  command_log="${directory}/commands.log"
  (
    cd "$directory" || exit 1
    PATH="${MOCK_BIN}:${PATH}" MOCK_FFMPEG_LOG="$command_log" QSV_MODE=force \
    FFMPEG=ffmpeg FFPROBE=ffprobe JOBS=1 FAST_VIDEO_COPY=1 REPAIR_MODE=never \
    SUBTITLE_MODE=burn MP4_TAG_HEADROOM_BYTES=0 OMDB_API_KEY='' STRICT_DISK_CHECK=0 \
      "${PROJECT_DIR}/convert.sh" >"$log_file" 2>&1
  ) || return 1
  assert_file_exists "${directory}/image-sub.mp4"
  assert_file_missing "${directory}/image-sub.en.forced.mks"
  grep -q -- '-filter_complex \[0:v:0\]\[0:s:0\]overlay=eof_action=pass:repeatlast=0\[vout\]' "$command_log"
  grep -q 'Burning bitmap forced subtitle' "$log_file"
}

test_av1_10bit_can_use_qsv_with_p010() {
  FFPROBE="${MOCK_BIN}/ffprobe"
  QSV_AVAILABLE=1
  ! qsv_skip_reason "${TEST_ROOT}/av1-10bit.mkv" >/dev/null || return 1
  assert_equal p010le "$(qsv_pixel_format "${TEST_ROOT}/av1-10bit.mkv")" '10-bit QSV pixel format'
}

test_qsv_failure_falls_back_to_x264() {
  local directory="${TEST_ROOT}/qsv-fallback" log_file command_log
  mkdir -p "$directory"
  printf input > "${directory}/qsv.mkv"
  log_file="${directory}/run.log"
  command_log="${directory}/commands.log"
  (
    cd "$directory" || exit 1
    PATH="${MOCK_BIN}:${PATH}" \
    MOCK_QSV_FAIL=1 MOCK_FFMPEG_LOG="$command_log" QSV_MODE=force \
    FFMPEG=ffmpeg FFPROBE=ffprobe JOBS=1 FAST_VIDEO_COPY=0 REPAIR_MODE=never \
    MP4_TAG_HEADROOM_BYTES=0 OMDB_API_KEY='' STRICT_DISK_CHECK=0 \
      "${PROJECT_DIR}/convert.sh" >"$log_file" 2>&1
  ) || return 1
  assert_file_exists "${directory}/qsv.mp4"
  grep -q 'hevc_qsv' "$command_log"
  grep -q -- '-low_power 0' "$command_log"
  grep -q 'libx264' "$command_log"
  grep -q -- '-fflags +genpts -i ./qsv.mkv -avoid_negative_ts make_zero -fps_mode vfr' "$command_log"
  grep -q 'QSV failed; falling back' "$log_file"
}

test_oversized_fast_copy_retries_with_encoding() {
  local directory="${TEST_ROOT}/fast-copy-size" log_file command_log
  mkdir -p "$directory"
  printf x > "${directory}/small.mkv"
  log_file="${directory}/run.log"
  command_log="${directory}/commands.log"
  (
    cd "$directory" || exit 1
    PATH="${MOCK_BIN}:${PATH}" \
    MOCK_FFMPEG_LOG="$command_log" QSV_MODE=force \
    FFMPEG=ffmpeg FFPROBE=ffprobe JOBS=1 FAST_VIDEO_COPY=1 REPAIR_MODE=never \
    MP4_TAG_HEADROOM_BYTES=0 OMDB_API_KEY='' STRICT_DISK_CHECK=0 SIZE_RETRY_ATTEMPTS=0 \
      "${PROJECT_DIR}/convert.sh" --target-size 5B >"$log_file" 2>&1
  ) || return 1
  assert_file_exists "${directory}/small.mp4"
  grep -q -- '-c:v copy' "$command_log"
  grep -q 'hevc_qsv' "$command_log"
  grep -q 'Fast-copy output exceeded its target' "$log_file"
}

test_tagging_failure_preserves_original() {
  command -v jq >/dev/null 2>&1 || return 0
  local directory="${TEST_ROOT}/tag-failure" mp4 sidecar original
  directory="${TEST_ROOT}/tag-failure"
  mkdir -p "$directory"
  mp4="${directory}/Movie.mp4"
  sidecar="${directory}/Movie.omdb.json"
  original='original-media-payload'
  printf '%s' "$original" > "$mp4"
  printf '%s\n' '{"Response":"True","Title":"Movie","Year":"2024","Type":"movie","imdbID":"tt1234567","Poster":"N/A"}' > "$sidecar"
  FFMPEG="${MOCK_BIN}/ffmpeg"
  FFPROBE="${MOCK_BIN}/ffprobe"
  MP4_OUTPUT_FLAGS=(-movflags +faststart)
  OMDB_LOG="${directory}/metadata.csv"
  OMDB_LOG_LOCK="${directory}/metadata.lock"
  OMDB_CONNECT_TIMEOUT=1
  OMDB_MAX_TIME=1
  OMDB_RETRIES=0
  PATH="${MOCK_BIN}:${PATH}"
  export MOCK_TAG_FAIL=1
  AtomicParsley() { return 1; }

  ! tag_media_from_omdb "$mp4" "$directory"
  assert_equal "$original" "$(cat "$mp4")" 'failed taggers must not replace original'
  grep -q '"yes","no"' "$OMDB_LOG"
}

test_strict_tagging_failure_is_not_published() {
  command -v jq >/dev/null 2>&1 || return 0
  local directory="${TEST_ROOT}/strict-tagging" log_file status
  mkdir -p "$directory"
  printf input > "${directory}/Movie.mkv"
  printf '%s\n' '{"Response":"True","Title":"Movie","Year":"2024","Type":"movie","imdbID":"tt123","Poster":"N/A"}' > "${directory}/Movie.omdb.json"
  log_file="${directory}/run.log"
  (
    cd "$directory" || exit 1
    PATH="${MOCK_BIN}:${PATH}" MOCK_TAG_FAIL=1 QSV_MODE=off \
    FFMPEG=ffmpeg FFPROBE=ffprobe JOBS=1 FAST_VIDEO_COPY=0 REPAIR_MODE=never \
    OMDB_INTERACTIVE=0 STRICT_TAGGING=1 MP4_TAG_HEADROOM_BYTES=0 OMDB_API_KEY='' STRICT_DISK_CHECK=0 \
      "${PROJECT_DIR}/convert.sh" >"$log_file" 2>&1
  )
  status=$?
  assert_equal 1 "$status" 'strict tagging batch status' || return 1
  assert_file_missing "${directory}/Movie (2024).mp4" || return 1
  assert_file_exists "${directory}/Movie.omdb.json"
}

test_strict_size_failure_is_not_published() {
  local directory="${TEST_ROOT}/strict-size" log_file status
  mkdir -p "$directory"
  printf input > "${directory}/strict-size.mkv"
  log_file="${directory}/run.log"
  (
    cd "$directory" || exit 1
    PATH="${MOCK_BIN}:${PATH}" QSV_MODE=off \
    FFMPEG=ffmpeg FFPROBE=ffprobe JOBS=1 FAST_VIDEO_COPY=0 REPAIR_MODE=never \
    OMDB_INTERACTIVE=0 MP4_TAG_HEADROOM_BYTES=0 OMDB_API_KEY='' STRICT_DISK_CHECK=0 SIZE_RETRY_ATTEMPTS=0 \
      "${PROJECT_DIR}/convert.sh" --target-size 5B --strict-size >"$log_file" 2>&1
  )
  status=$?
  assert_equal 1 "$status" 'strict size batch status' || return 1
  assert_file_missing "${directory}/strict-size.mp4"
}

test_interrupt_cleans_workers_and_locks() {
  local directory="${TEST_ROOT}/interrupt" log_file converter_pid result
  directory="${TEST_ROOT}/interrupt"
  mkdir -p "$directory"
  printf input > "${directory}/slow.mkv"
  log_file="${directory}/run.log"
  (
    cd "$directory" || exit 1
    PATH="${MOCK_BIN}:${PATH}" QSV_MODE=off \
    MOCK_FFMPEG_SLEEP=5 FFMPEG=ffmpeg FFPROBE=ffprobe JOBS=1 FAST_VIDEO_COPY=0 \
    REPAIR_MODE=never MP4_TAG_HEADROOM_BYTES=0 OMDB_API_KEY='' STRICT_DISK_CHECK=0 \
      "${PROJECT_DIR}/convert.sh" >"$log_file" 2>&1 &
    converter_pid=$!
    sleep 0.5
    kill -TERM "$converter_pid"
    wait "$converter_pid"
    result=$?
    assert_equal 130 "$result" 'interrupt exit status'
  ) || return 1
  [[ -z "$(find "$directory" -maxdepth 1 \( -name '.media-conversion.*.lock' -o -name '.media-conversion.*' \) -print)" ]]
  assert_file_missing "${directory}/slow.mp4"
  grep -q 'stopping active conversion workers' "$log_file"
}

run_test 'size parser' test_size_parser
run_test 'language helpers' test_language_helpers
run_test 'log and filename sanitizing' test_log_and_filename_sanitizing
run_test 'atomic output reservation' test_atomic_output_reservation
run_test 'no-clobber publication' test_no_clobber_publication
run_test 'reservation creation failure is bounded' test_reservation_creation_failure_is_bounded
run_test 'both DTS warning spellings' test_both_dts_warning_spellings
run_test 'subtitle language variants' test_subtitle_language_variants
run_test 'manual subtitle must be forced English' test_manual_subtitle_must_be_forced_english
run_test 'audio ranking and und fallback' test_audio_ranking_and_und_fallback
run_test 'commentary and manual language policy' test_commentary_and_manual_language_policy
run_test 'missing eligible audio fails closed' test_missing_eligible_audio_fails_closed
run_test 'stale repair inputs are ignored' test_stale_repair_inputs_are_ignored
run_test 'invalid configuration is rejected' test_invalid_configuration_is_rejected
run_test 'config is data-only, private, and not exported' test_config_is_data_only_private_and_not_exported
run_test 'state rejects public custom log' test_state_rejects_public_custom_log
run_test 'sidecars are regular and bounded' test_sidecars_are_regular_and_bounded
run_test 'metadata type controls episode size policy' test_metadata_type_controls_episode_size_policy
run_test 'rejected OMDb match is discarded' test_rejected_omdb_match_is_not_saved
run_test 'lookup failure preserves sidecar' test_lookup_failure_preserves_sidecar
run_test 'cached metadata is confirmed by default' test_cached_metadata_is_confirmed_by_default
run_test 'search result count cannot reach arithmetic' test_search_result_count_cannot_reach_arithmetic
run_test 'OMDb key uses standard input' test_omdb_key_uses_standard_input
run_test 'poster MIME controls extension' test_poster_mime_controls_extension
run_test 'duration and decode validation' test_duration_and_decode_validation
run_test 'metadata-only tagging' test_metadata_only_tagging
run_test 'parallel failures are reported' test_parallel_failures_are_reported
run_test 'image subtitle is burned' test_image_subtitle_is_burned
run_test 'AV1 10-bit can use QSV with p010' test_av1_10bit_can_use_qsv_with_p010
run_test 'QSV failure falls back to x264' test_qsv_failure_falls_back_to_x264
run_test 'oversized fast copy retries with encoding' test_oversized_fast_copy_retries_with_encoding
run_test 'tagging failure preserves original' test_tagging_failure_preserves_original
run_test 'strict tagging failure is not published' test_strict_tagging_failure_is_not_published
run_test 'strict size failure is not published' test_strict_size_failure_is_not_published
run_test 'interrupt cleans workers and locks' test_interrupt_cleans_workers_and_locks

printf '\nTests: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
(( FAIL_COUNT == 0 ))
