#!/usr/bin/env bash
# Real FFmpeg smoke test for stream selection, MP4 muxing, validation, and cleanup.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/media-conversion-integration.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

for command_name in ffmpeg ffprobe jq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing integration-test dependency: %s\n' "$command_name" >&2
    exit 1
  }
done

cat > "${TEST_ROOT}/forced.srt" <<'EOF'
1
00:00:00,250 --> 00:00:01,250
Forced English subtitle
EOF

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=2' \
  -f lavfi -i 'sine=frequency=440:duration=2' \
  -f lavfi -i 'sine=frequency=880:duration=2' \
  -i "${TEST_ROOT}/forced.srt" \
  -map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:s:0 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -c:s srt \
  -metadata:s:a:0 language=fra -metadata:s:a:0 'title=French Main' \
  -metadata:s:a:1 language=eng -metadata:s:a:1 'title=English Main' \
  -disposition:a:0 default -disposition:a:1 0 \
  -metadata:s:s:0 language=eng -metadata:s:s:0 'title=English Forced' \
  -disposition:s:0 forced "${TEST_ROOT}/input.mkv"

(
  cd "$TEST_ROOT"
  MEDIA_STATE_DIR="${TEST_ROOT}/state" \
  FFMPEG=ffmpeg FFPROBE=ffprobe JOBS=1 QSV_MODE=off REPAIR_MODE=never \
  FAST_VIDEO_COPY=1 SUBTITLE_MODE=copy AUDIO_MODE=stereo \
  MP4_TAG_HEADROOM_BYTES=0 OMDB_API_KEY='' OMDB_INTERACTIVE=0 \
  STRICT_DISK_CHECK=1 VALIDATION_MODE=decode \
    "${PROJECT_DIR}/convert.sh"
)

[[ -s "${TEST_ROOT}/input.mp4" ]]
ffprobe -v error -show_streams -of json "${TEST_ROOT}/input.mp4" |
  jq -e '
    ([.streams[] | select(.codec_type == "video")] | length) == 1 and
    ([.streams[] | select(.codec_type == "audio")] | length) == 1 and
    ([.streams[] | select(.codec_type == "audio")][0].tags.language) == "eng" and
    ([.streams[] | select(.codec_type == "subtitle")] | length) == 1 and
    ([.streams[] | select(.codec_type == "subtitle")][0].tags.language) == "eng" and
    ([.streams[] | select(.codec_type == "subtitle")][0].disposition.forced) == 1
  ' >/dev/null

[[ ! -e "${TEST_ROOT}/input.omdb.json" ]]
[[ -z "$(find "$TEST_ROOT" -maxdepth 1 -name '.media-conversion.*' -print)" ]]
[[ -z "$(find "${TEST_ROOT}/state" -mindepth 1 -print 2>/dev/null)" ]]

printf 'Real FFmpeg integration test passed.\n'
