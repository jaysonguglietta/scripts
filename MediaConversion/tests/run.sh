#!/usr/bin/env bash
# Sourced-module state and the mocked AtomicParsley function are consumed dynamically.
# shellcheck disable=SC2034,SC2329
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
MOCK_BIN="${TEST_DIR}/mocks"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/media-conversion-tests.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0

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
    return 1
  fi
}

assert_file_exists() {
  [[ -f "$1" ]] || { printf 'ASSERT: file does not exist: %s\n' "$1" >&2; return 1; }
}

assert_file_missing() {
  [[ ! -e "$1" ]] || { printf 'ASSERT: file should not exist: %s\n' "$1" >&2; return 1; }
}

run_test() {
  local name="$1"
  shift
  if ( "$@" ); then
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
  ALLOW_UNTAGGED_AUDIO_FALLBACK=1
  assert_equal '2|english' "$(pick_audio_stream_index "${TEST_ROOT}/commentary.mkv")" 'main audio beats commentary'
  assert_equal '1|untagged' "$(pick_audio_stream_index "${TEST_ROOT}/und-audio.mkv")" 'und audio fallback'
}

test_missing_eligible_audio_fails_closed() {
  FFPROBE="${MOCK_BIN}/ffprobe"
  AUDIO_STREAM_INDEX=auto
  ALLOW_UNTAGGED_AUDIO_FALLBACK=1
  ! pick_audio_stream_index "${TEST_ROOT}/no-audio.mkv" >/dev/null
}

test_stale_repair_inputs_are_ignored() {
  local directory="${TEST_ROOT}/discovery"
  mkdir -p "$directory"
  printf input > "${directory}/Movie.mkv"
  printf stale > "${directory}/Movie.repaired.mkv"
  printf stale > "${directory}/Movie.part.mkv"
  (
    cd "$directory" || exit 1
    discover_input_files
    assert_equal 1 "${#FILES[@]}" 'discovered input count'
    assert_equal ./Movie.mkv "${FILES[0]}" 'only real source is discovered'
  )
}

test_invalid_configuration_is_rejected() {
  JOBS=0
  load_defaults
  ! validate_config >/dev/null 2>&1
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
  omdb_prompt_read() { printf -v "$2" '%s' n; }
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
  printf '%s\n' '{"Response":"True","Title":"Confirmed"}' > "$sidecar"
  OMDB_REFRESH=1
  OMDB_ENABLED=1
  OMDB_INTERACTIVE=0
  omdb_lookup() { return 1; }
  omdb_interactive_verify_and_save "$input" >/dev/null
  assert_equal Confirmed "$(jq -r .Title "$sidecar")" 'confirmed sidecar must survive outage'
}

test_omdb_key_uses_standard_input() {
  local directory="${TEST_ROOT}/api-key" response
  mkdir -p "$directory"
  OMDB_API_KEY='test-secret-key'
  OMDB_URL='https://example.invalid'
  OMDB_CONNECT_TIMEOUT=1
  OMDB_MAX_TIME=1
  OMDB_RETRIES=0
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
  MOCK_POSTER_MIME='image/png'
  curl() {
    local output=""
    while (( $# > 0 )); do
      case "$1" in
        --output) output="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf image > "$output"
    printf '%s' "$MOCK_POSTER_MIME"
  }

  path="$(download_poster 'https://example.invalid/poster' "${directory}/poster")" || return 1
  assert_equal "${directory}/poster.png" "$path" 'PNG extension'
  assert_file_exists "$path"

  MOCK_POSTER_MIME='text/html'
  ! download_poster 'https://example.invalid/not-an-image' "${directory}/invalid" >/dev/null
  assert_file_missing "${directory}/invalid.download"
}

test_metadata_only_tagging() {
  command -v jq >/dev/null 2>&1 || return 0
  local directory="${TEST_ROOT}/tagging" mp4 sidecar
  directory="${TEST_ROOT}/tagging"
  mkdir -p "$directory"
  mp4="${directory}/Movie.mp4"
  sidecar="${directory}/Movie.omdb.json"
  printf payload > "$mp4"
  printf '%s\n' '{"Response":"True","Title":"Movie","Year":"2024","Type":"movie","Poster":"N/A"}' > "$sidecar"
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

test_image_subtitle_is_extracted() {
  local directory="${TEST_ROOT}/image-subtitle" log_file
  mkdir -p "$directory"
  printf input > "${directory}/image-sub.mkv"
  log_file="${directory}/run.log"
  (
    cd "$directory" || exit 1
    PATH="${MOCK_BIN}:${PATH}" \
    FFMPEG=ffmpeg FFPROBE=ffprobe JOBS=1 FAST_VIDEO_COPY=1 REPAIR_MODE=never \
    SUBTITLE_MODE=copy MP4_TAG_HEADROOM_BYTES=0 OMDB_API_KEY='' STRICT_DISK_CHECK=0 \
      "${PROJECT_DIR}/convert.sh" >"$log_file" 2>&1
  ) || return 1
  assert_file_exists "${directory}/image-sub.mp4"
  assert_file_exists "${directory}/image-sub.en.forced.mks"
  grep -q 'extracting a sidecar' "$log_file"
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
    MOCK_QSV_FAIL=1 MOCK_FFMPEG_LOG="$command_log" \
    FFMPEG=ffmpeg FFPROBE=ffprobe JOBS=1 FAST_VIDEO_COPY=0 REPAIR_MODE=never \
    MP4_TAG_HEADROOM_BYTES=0 OMDB_API_KEY='' STRICT_DISK_CHECK=0 \
      "${PROJECT_DIR}/convert.sh" >"$log_file" 2>&1
  ) || return 1
  assert_file_exists "${directory}/qsv.mp4"
  grep -q 'hevc_qsv' "$command_log"
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
    MOCK_FFMPEG_LOG="$command_log" \
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
  printf '%s\n' '{"Response":"True","Title":"Movie","Year":"2024","Type":"movie","Poster":"N/A"}' > "$sidecar"
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

test_interrupt_cleans_workers_and_locks() {
  local directory="${TEST_ROOT}/interrupt" log_file converter_pid result
  directory="${TEST_ROOT}/interrupt"
  mkdir -p "$directory"
  printf input > "${directory}/slow.mkv"
  log_file="${directory}/run.log"
  (
    cd "$directory" || exit 1
    PATH="${MOCK_BIN}:${PATH}" \
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
  [[ -z "$(find "$directory" -maxdepth 1 \( -name '*.convert.lock' -o -name '.*.convert.*' \) -print)" ]]
  assert_file_missing "${directory}/slow.mp4"
  grep -q 'stopping active conversion workers' "$log_file"
}

run_test 'size parser' test_size_parser
run_test 'language helpers' test_language_helpers
run_test 'atomic output reservation' test_atomic_output_reservation
run_test 'both DTS warning spellings' test_both_dts_warning_spellings
run_test 'subtitle language variants' test_subtitle_language_variants
run_test 'audio ranking and und fallback' test_audio_ranking_and_und_fallback
run_test 'missing eligible audio fails closed' test_missing_eligible_audio_fails_closed
run_test 'stale repair inputs are ignored' test_stale_repair_inputs_are_ignored
run_test 'invalid configuration is rejected' test_invalid_configuration_is_rejected
run_test 'rejected OMDb match is discarded' test_rejected_omdb_match_is_not_saved
run_test 'lookup failure preserves sidecar' test_lookup_failure_preserves_sidecar
run_test 'OMDb key uses standard input' test_omdb_key_uses_standard_input
run_test 'poster MIME controls extension' test_poster_mime_controls_extension
run_test 'metadata-only tagging' test_metadata_only_tagging
run_test 'parallel failures are reported' test_parallel_failures_are_reported
run_test 'image subtitle is extracted' test_image_subtitle_is_extracted
run_test 'QSV failure falls back to x264' test_qsv_failure_falls_back_to_x264
run_test 'oversized fast copy retries with encoding' test_oversized_fast_copy_retries_with_encoding
run_test 'tagging failure preserves original' test_tagging_failure_preserves_original
run_test 'interrupt cleans workers and locks' test_interrupt_cleans_workers_and_locks

printf '\nTests: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
(( FAIL_COUNT == 0 ))
