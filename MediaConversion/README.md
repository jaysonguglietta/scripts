# MediaConversion

`convert.sh` is a transactional Bash batch converter for Fedora/Linux media servers. It converts MKV files in the current directory to Plex-friendly MP4 files, preserves the source files, and validates every completed output before publishing it.

## Highlights

- Shows normal progress, selected streams, encoder decisions, retries, and FFmpeg statistics.
- Uses isolated temporary directories and atomically moves validated outputs into place.
- Reserves output names across parallel workers and concurrent script runs.
- Never overwrites an existing MP4; duplicate names receive ` (1)`, ` (2)`, and so on.
- Returns a nonzero batch status when any file fails.
- Cleans worker files and reservations on normal exit, `Ctrl-C`, or termination.
- Selects English audio while penalizing commentary and accessibility tracks.
- Optionally falls back to untagged or `und` audio when English tags are missing.
- Detects forced English subtitles from language tags and titles.
- Copies text subtitles, extracts bitmap subtitles, or burns compatible text subtitles.
- Uses compatible H.264/HEVC video without re-encoding when the fast-copy path is safe.
- Detects both common FFmpeg spellings of non-monotonic DTS warnings.
- Tries Intel QSV HEVC, then falls back to CPU x264 if QSV is unavailable or fails.
- Supports software x265, downscaling, audio policies, and output size targets.
- Retries oversized encoded output at a reduced bitrate.
- Reuses confirmed OMDb sidecars and writes new sidecars atomically.
- Tags metadata without replacing the finished MP4 unless the tagged copy validates.

## Safety Model

The script does not delete or modify input MKV files. A worker writes into a hidden directory beside its intended output, validates the temporary MP4 with `ffprobe`, and only then moves it to the reserved final name.

Temporary-looking source names ending in `.repaired.mkv` or `.part.mkv` are ignored. Worker directories use `.<name>.convert.XXXXXX`, and reservations use `<name>.mp4.convert.lock`.

A failed batch can still contain valid outputs from successful workers. The batch exits `1` so automation can detect that at least one file needs attention.

## Install On Fedora

Required commands:

- Bash
- FFmpeg and `ffprobe`

Required for new OMDb lookups:

- `curl`
- `jq`

Recommended or optional commands:

- `flock` for metadata log locking; a portable directory lock is used otherwise
- `mkvmerge` for the preferred repair path; FFmpeg remuxing is the fallback
- `AtomicParsley` for richer Apple-style MP4 tags; FFmpeg is the fallback
- `pgrep` for recursive worker cleanup during interruption

Install the matching packages from your enabled Fedora repositories, then confirm the important tools:

```bash
bash --version
ffmpeg -version
ffprobe -version
jq --version
curl --version
```

The script automatically tries `ffmpeg-git` before `ffmpeg`, and `ffprobe-git` before `ffprobe`. Set `FFMPEG` and `FFPROBE` when different command names are needed.

## Clone From `/etc`

Because the converter now loads its `lib/` modules, clone the repository rather than downloading only `convert.sh`:

```bash
cd /etc
sudo git clone https://github.com/jaysonguglietta/scripts.git scripts
sudo chmod +x /etc/scripts/MediaConversion/convert.sh
```

The repository is public, so HTTPS does not require a deploy key. If the server already has an authorized GitHub SSH key, the SSH URL also works:

```bash
cd /etc
sudo git clone git@github.com:jaysonguglietta/scripts.git scripts
```

Be aware that `sudo git clone` uses root's SSH configuration, not the current user's. HTTPS is usually simpler for a public repository.

Pull future updates with:

```bash
sudo git -C /etc/scripts pull --ff-only
```

## Basic Usage

Run the script from the directory containing the MKV files:

```bash
cd /path/to/media
/etc/scripts/MediaConversion/convert.sh
```

Scan subtitle status without converting:

```bash
/etc/scripts/MediaConversion/convert.sh --print-subs-only
```

Use one worker and full Bash command tracing when troubleshooting:

```bash
VERBOSE=1 /etc/scripts/MediaConversion/convert.sh --jobs 1
```

Normal mode already prints the startup configuration, per-file start and completion lines, stream choices, subtitle actions, encoder paths, retries, FFmpeg statistics, warnings, and a final failure count. `VERBOSE=1` adds `set -x` tracing inside each worker and is intentionally much noisier.

## Common Recipes

Fast conversion with compatible video copied when possible:

```bash
SUBTITLE_MODE=extract ./convert.sh --jobs 2
```

Aim for a 2 GiB movie with 720p stereo output:

```bash
./convert.sh --target-size 2GB --max-height 720 --audio stereo
```

Use software HEVC for better compression at a constrained size:

```bash
./convert.sh --target-size 2GB --max-height 720 --audio stereo \
  --quality-encode --x265-preset fast
```

Fail the file if retries cannot meet the target within the configured tolerance:

```bash
./convert.sh --target-size 2GB --strict-size
```

Override incorrectly tagged streams:

```bash
./convert.sh --audio-stream 2 --forced-subtitle-stream 0
```

`--audio-stream` is an absolute FFmpeg stream index. `--forced-subtitle-stream` is a zero-based position among subtitle streams.

## CLI Reference

| Option | Meaning |
| --- | --- |
| `--target-size SIZE` | Best-effort final size cap such as `2GB`, `1.5GiB`, `700MB`, or raw bytes. |
| `--max-height HEIGHT` | Downscale to at most this pixel height while preserving aspect ratio. `0` disables scaling. |
| `--audio MODE` | `surround+stereo`, `surround`, or `stereo`. |
| `--audio-stream INDEX` | Select an absolute audio stream index instead of automatic ranking. |
| `--forced-subtitle-stream N` | Select a zero-based subtitle position instead of automatic forced-English detection. |
| `--quality-encode` | Use software `libx265` before the standard encoder path. |
| `--x265-preset PRESET` | Set the x265 speed/quality preset. |
| `--jobs COUNT` | Set the maximum number of simultaneous workers. |
| `--refresh-metadata` | Request fresh OMDb data instead of reusing a confirmed sidecar. |
| `--strict-size` | Fail outputs that remain above the target and tolerance after retries. |
| `--print-subs-only` | Report forced-English subtitle detection without metadata lookup or conversion. |
| `-h`, `--help` | Print built-in help. |

Options support both `--name value` and `--name=value` forms where a value is required.

## Configuration

### Runtime

| Variable | Default | Meaning |
| --- | --- | --- |
| `FFMPEG` | auto | FFmpeg command or path. |
| `FFPROBE` | auto | ffprobe command or path. |
| `JOBS` | `3` | Maximum concurrent workers. |
| `VERBOSE` | `0` | Set to `1` for per-worker Bash tracing. |
| `REPAIR_MODE` | `auto` | `auto`, `always`, or `never`. |
| `FIX_TIMESTAMPS` | `1` | Generate timestamps and normalize negative timestamps. |
| `FAST_VIDEO_COPY` | `1` | Copy compatible H.264/HEVC video when no filter or quality encode is required. |
| `STRICT_DISK_CHECK` | `0` | Set to `1` to stop when estimated free space is insufficient. |

### Audio And Subtitles

| Variable | Default | Meaning |
| --- | --- | --- |
| `AUDIO_MODE` | `surround+stereo` | Output `surround+stereo`, `surround`, or `stereo`. |
| `AUDIO_STREAM_INDEX` | `auto` | Automatic selection or an absolute stream index. |
| `ALLOW_UNTAGGED_AUDIO_FALLBACK` | `1` | Allow blank, `und`, or `unknown` audio language tags. |
| `AAC_STEREO_BR` | `192k` | AAC stereo bitrate. |
| `AC3_51_BR` | `640k` | AC-3 5.1 bitrate. |
| `SUBTITLE_MODE` | `burn` | `burn`, `copy`, or `extract`. |
| `FORCED_SUBTITLE_STREAM` | `auto` | Automatic selection or a subtitle-relative position. |
| `ALLOW_FORCED_TITLE_FALLBACK` | `1` | Use English/forced title text when tags are incomplete. |

Text subtitle codecs can be burned or converted to MP4 `mov_text`. Bitmap codecs such as PGS cannot use the text filter and are extracted to `.mks` sidecars. Only the selected forced-English subtitle is retained.

### Encoders And Size

| Variable | Default | Meaning |
| --- | --- | --- |
| `QSV_GLOBAL_QUALITY` | `22` | Intel QSV quality value. |
| `QSV_PRESET` | `medium` | Intel QSV preset. |
| `X264_CRF` | `20` | CPU x264 CRF when no size bitrate is active. |
| `X264_PRESET` | `veryfast` | CPU x264 preset. |
| `X264_THREADS` | `6` | x264 thread count; `0` lets FFmpeg decide. |
| `X265_CRF` | `23` | Software x265 CRF when no size bitrate is active. |
| `X265_PRESET` | `medium` | Software x265 preset. |
| `USE_VBV` | `1` | Apply x264 VBV limits. |
| `VBV_MAXRATE` | `25000` | VBV maximum rate in kbit/s. |
| `VBV_BUFSIZE` | `30000` | VBV buffer size in kbit/s. |
| `TV_MAX_BYTES` | `1073741824` | Default final cap for detected TV episodes. |
| `MP4_TAG_HEADROOM_BYTES` | `16777216` | Front-loaded MP4 metadata space reserved by FFmpeg. |
| `SIZE_SAFETY_PERCENT` | `97` | Payload percentage used for bitrate calculation. |
| `SIZE_RETRY_ATTEMPTS` | `1` | Number of lower-bitrate retries after an oversized encode. |
| `SIZE_TOLERANCE_PERCENT` | `2` | Allowed percentage above the requested cap. |
| `STRICT_SIZE_CAP` | `0` | Environment equivalent of `--strict-size`. |
| `QUALITY_ENCODE` | `0` | Environment equivalent of `--quality-encode`. |
| `MAX_HEIGHT` | `0` | Environment equivalent of `--max-height`. |

When any size cap is active, audio is transcoded so its bitrate can be budgeted. A fast-copy result that unexpectedly exceeds the target is retried with video encoding. The script checks size before publication and again after metadata tagging.

### OMDb And Tagging

| Variable | Default | Meaning |
| --- | --- | --- |
| `OMDB_API_KEY` | empty | Required for new OMDb requests. No key is embedded. |
| `OMDB_URL` | `https://www.omdbapi.com` | API endpoint. HTTPS is required when a key is set. |
| `OMDB_INTERACTIVE` | `1` | Confirm matches when a terminal is available. |
| `OMDB_REFRESH` | `0` | Set to `1` to refresh confirmed sidecars. |
| `OMDB_CONNECT_TIMEOUT` | `5` | Connection timeout in seconds. |
| `OMDB_MAX_TIME` | `20` | Maximum request time in seconds. |
| `OMDB_RETRIES` | `2` | Retry count for API and poster requests. |
| `OMDB_LOG` | `omdb_tagging_log.csv` | Metadata result log. |
| `OMDB_LOG_LOCK` | `<log>.lock` | Lock file used for parallel log writes. |
| `STRICT_TAGGING` | `0` | Set to `1` to count metadata-tagging failure as file failure. |

Store the API key outside the repository in a protected environment file:

```bash
mkdir -p "$HOME/.config"
install -m 600 /dev/null "$HOME/.config/media-conversion.env"
${EDITOR:-vi} "$HOME/.config/media-conversion.env"
```

Example file content:

```bash
OMDB_API_KEY=replace_with_your_key
OMDB_INTERACTIVE=0
```

Load it before running:

```bash
set -a
source "$HOME/.config/media-conversion.env"
set +a
/etc/scripts/MediaConversion/convert.sh
```

The key is sent through standard input to `curl`, so it is not included in `curl` process arguments. Do not enable shell tracing while manually exporting secrets.

Confirmed `<input>.omdb.json` sidecars are reused unless refresh is requested. Network failures preserve valid existing metadata. Rejected matches are replaced with an empty sidecar and are not silently reused. Search choices are limited to the displayed results.

Tagging is staged on a copy. AtomicParsley is preferred; if it fails, the original staged file is restored and FFmpeg is tried. A tagged file must pass stream and duration validation before it can replace the untagged MP4.

## Output Validation

A final output must:

- Exist and be nonempty.
- Be readable by `ffprobe`.
- Contain at least one video stream and one audio stream.
- Have a positive duration.
- Stay within two percent or five seconds of the source duration, whichever tolerance is larger.

Exit statuses are `0` for complete success, `1` when configuration or one or more files fail, and `130` after interruption.

## Troubleshooting

Use `VERBOSE=1 --jobs 1` to make a single worker's shell commands easy to follow. Repair and fast-copy diagnostics are also printed when those paths fail.

If no audio is selected, inspect stream indexes and language tags:

```bash
ffprobe -v error -select_streams a \
  -show_entries stream=index,codec_name,channels:stream_tags=language,title \
  -of compact=p=0:nk=0 input.mkv
```

Then use `--audio-stream INDEX` or enable `ALLOW_UNTAGGED_AUDIO_FALLBACK=1` if the intended track is untagged.

If subtitle detection is wrong, run `--print-subs-only`, inspect the subtitle streams, and use `--forced-subtitle-stream N` when needed.

If QSV is unavailable, the script logs the failure and uses x264. Set `QUALITY_ENCODE=1` or `--quality-encode` to intentionally use software x265 instead.

If an output is too large, combine `--target-size`, `--max-height`, and `--audio stereo`. Increase `SIZE_RETRY_ATTEMPTS` for another bitrate correction, or add `--strict-size` for automation that must reject an oversized result.

If a previous process was killed with `SIGKILL`, an old `.convert.lock` directory may remain. Verify no converter owns it before removing that specific stale directory. Normal interruption cleans reservations automatically.

## Tests And CI

The test suite uses deterministic FFmpeg and ffprobe mocks; it does not require sample media:

```bash
cd /etc/scripts
bash MediaConversion/tests/run.sh
```

Run the static checks used by GitHub Actions when ShellCheck is installed:

```bash
bash -n MediaConversion/convert.sh MediaConversion/lib/*.sh \
  MediaConversion/tests/run.sh MediaConversion/tests/mocks/*
shellcheck -x MediaConversion/convert.sh MediaConversion/lib/*.sh \
  MediaConversion/tests/run.sh MediaConversion/tests/mocks/*
```

CI runs syntax validation, ShellCheck, and the mock regression suite for MediaConversion changes.

## Project Layout

```text
MediaConversion/
|-- convert.sh
|-- lib/
|   |-- common.sh
|   |-- media.sh
|   `-- metadata.sh
|-- tests/
|   |-- mocks/
|   `-- run.sh
|-- CHANGELOG.md
|-- README.md
`-- SECURITY.md
```

See `SECURITY.md` before configuring an OMDb key, especially if an older revision of this public repository was used.
