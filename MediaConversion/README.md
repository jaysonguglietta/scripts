# MediaConversion

`convert.sh` is a Bash batch converter for Fedora/Linux media servers that converts `.mkv` files to Plex-friendly `.mp4` files with Apple TV 4K-oriented defaults.

## What it does

- Keeps English audio only, preferring the highest-channel track.
- Can fall back to a default or untagged audio track when a file is missing English language tags.
- Keeps a 5.1-compatible track when possible and adds an AAC stereo fallback.
- Keeps only forced English subtitles and always drops non-English subtitles.
- Supports `burn`, `copy`, and `extract` modes for forced English subtitles.
- Uses a fast video-copy path for compatible H.264/HEVC sources when burn-in is not needed.
- Detects problematic non-monotonic DTS warnings on the fast copy path and retries with a repaired source or falls back to encode when needed.
- Retries with a repaired MKV only when needed in `REPAIR_MODE=auto`.
- Uses Intel QSV HEVC when forced subtitle burn-in is not needed, with CPU fallback.
- Looks up OMDb metadata, downloads poster art, and tags the finished MP4.
- Renames output files from confirmed OMDb matches.
- Avoids silently overwriting an existing MP4 by picking a unique output name.
- Reserves MP4 metadata headroom so later tagging tools can update metadata in place.
- Returns a non-zero exit code if one or more files fail.

## Dependencies

Required:

- `bash`
- `ffmpeg`
- `ffprobe`

Recommended:

- `curl`
- `jq`
- `flock`

Optional:

- `mkvmerge`
- `AtomicParsley`

## Basic usage

```bash
./convert.sh
```

Convert all MKV files in the current directory.

```bash
./convert.sh --print-subs-only
```

Only scan the current directory and report whether each file has forced English subtitles.

## Useful environment overrides

```bash
FFMPEG=ffmpeg
FFPROBE=ffprobe
JOBS=3
VERBOSE=0
OMDB_API_KEY=your_key_here
OMDB_INTERACTIVE=1
TV_MAX_BYTES=1073741824
REPAIR_MODE=auto
SUBTITLE_MODE=burn
FAST_VIDEO_COPY=1
ALLOW_UNTAGGED_AUDIO_FALLBACK=1
MP4_TAG_HEADROOM_BYTES=16777216
```

Example:

```bash
OMDB_API_KEY=your_key_here JOBS=2 ./convert.sh
```

Faster example that keeps forced English subtitles as sidecars instead of burning them:

```bash
OMDB_API_KEY=your_key_here REPAIR_MODE=auto SUBTITLE_MODE=extract JOBS=2 ./convert.sh
```

Example for files that often arrive without proper audio language tags:

```bash
ALLOW_UNTAGGED_AUDIO_FALLBACK=1 ./convert.sh
```

## Notes

- The script works on the current directory only.
- Parallel OMDb log writes are synchronized when `flock` is available.
- If a QSV encode fails, the script falls back to CPU x264 encoding.
- Forced English subtitle burn-in uses CPU encoding because subtitles are rendered into the video stream.
- `SUBTITLE_MODE=copy` keeps only forced English text subtitles inside the MP4; image-based forced subtitles fall back to sidecar extraction.
- `ALLOW_UNTAGGED_AUDIO_FALLBACK=1` is useful for files with English audio that is missing a language tag; set it to `0` if you want the script to fail closed instead.
- `FAST_VIDEO_COPY=1` is fastest, but files with messy timestamps may be retried through the repair path or full encode path to avoid keeping a bad MP4.
- `MP4_TAG_HEADROOM_BYTES` controls how much front-loaded MP4 metadata space is reserved for later retagging; set it to `0` to use normal `faststart` output instead.
