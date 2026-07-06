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
- Supports explicit output size targets such as `--target-size 2GB`.
- Supports quality controls for tight targets: `--max-height`, `--audio`, and `--quality-encode`.
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

```bash
./convert.sh --target-size 2GB
```

Aim to keep each output MP4 under about 2 GiB. This is a best-effort bitrate budget, not a guarantee.

```bash
./convert.sh --target-size 2GB --max-height 720 --audio stereo --quality-encode
```

Recommended when shrinking a large source, such as a 20 GiB movie, down to a very small target. It downscales to 720p, keeps only an AAC stereo track, and uses slower software HEVC for better compression quality than the fast hardware path.

## CLI options

```bash
--target-size SIZE
```

Best-effort output size cap. Accepts values like `2GB`, `1.5GB`, `700MB`, `1536M`, or raw bytes.

```bash
--max-height HEIGHT
```

Downscale video to at most this height while preserving aspect ratio. Use `720` when a strict 2 GiB movie target looks too compressed at 1080p or 4K.

```bash
--audio MODE
```

Audio output mode:

- `surround+stereo`: default; keep 5.1 when possible and add an AAC stereo fallback.
- `surround`: keep only the 5.1-compatible track when possible.
- `stereo`: keep only AAC stereo to save space for video.

```bash
--quality-encode
```

Use slower software HEVC (`libx265`) instead of the fast QSV path. This is useful for small target sizes where compression efficiency matters more than speed.

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
AUDIO_MODE=surround+stereo
QUALITY_ENCODE=0
MAX_HEIGHT=0
X265_CRF=23
X265_PRESET=slow
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
- `--target-size` is best effort. Final size can vary because encoder decisions, audio streams, subtitles, and MP4 metadata overhead are not perfectly predictable.
- Very small targets need tradeoffs. For example, converting a 20 GiB 1080p or 4K movie to 2 GiB will usually look better with `--max-height 720 --audio stereo --quality-encode`.
- Parallel OMDb log writes are synchronized when `flock` is available.
- If a QSV encode fails, the script falls back to CPU x264 encoding.
- `--quality-encode` uses CPU HEVC and is much slower than QSV, but usually looks better at constrained bitrates.
- Forced English subtitle burn-in uses CPU encoding because subtitles are rendered into the video stream.
- `SUBTITLE_MODE=copy` keeps only forced English text subtitles inside the MP4; image-based forced subtitles fall back to sidecar extraction.
- `ALLOW_UNTAGGED_AUDIO_FALLBACK=1` is useful for files with English audio that is missing a language tag; set it to `0` if you want the script to fail closed instead.
- `FAST_VIDEO_COPY=1` is fastest, but files with messy timestamps may be retried through the repair path or full encode path to avoid keeping a bad MP4.
- `MP4_TAG_HEADROOM_BYTES` controls how much front-loaded MP4 metadata space is reserved for later retagging; set it to `0` to use normal `faststart` output instead.
