# MediaConversion

`convert.sh` is a transactional Bash batch converter for Fedora/Linux media servers. It converts MKV files in the current directory to Plex-friendly MP4 files, preserves the source files, and validates every completed output before publishing it.

## Highlights

- Shows normal progress, selected streams, encoder decisions, retries, and FFmpeg statistics.
- Uses isolated temporary directories and atomically moves validated outputs into place.
- Reserves output names across parallel workers and concurrent script runs.
- Never overwrites an existing MP4; duplicate names receive ` (1)`, ` (2)`, and so on.
- Returns a nonzero batch status when any file fails.
- Cleans worker files and reservations on normal exit, `Ctrl-C`, or termination.
- Refuses symlinked inputs and untrusted script, library, config, state, and log paths.
- Selects English audio while excluding commentary and accessibility tracks by default.
- Optionally falls back to untagged or `und` audio when English tags are missing.
- Detects forced English subtitles from language tags and titles.
- Copies or burns text subtitles and can burn PGS/other bitmap forced subtitles.
- Uses compatible H.264/HEVC video without re-encoding when the fast-copy path is safe.
- Detects both common FFmpeg spellings of non-monotonic DTS warnings.
- Preflights Intel QSV HEVC, accepts supported 8/10-bit sources including AV1 decode, and falls back safely.
- Supports HDR-preserving software x265 fallback, SDR x264, downscaling, audio policies, and output size targets.
- Retries oversized encoded output at a reduced bitrate.
- Confirms new and cached OMDb matches by default and writes bounded sidecars atomically.
- Restricts artwork downloads to HTTPS allowlisted hosts, validated JPEG/PNG content, and bounded sizes.
- Tags and validates metadata before the MP4 is published, so strict failures never leave a final output.
- Stores audit logs in a private state directory and cleans logs, locks, and sidecars after successful runs by default.
- Provides stream inspection, conversion dry runs, strict metadata, strict size, and existing-output policies.

## Safety Model

The script does not delete or modify input MKV files. A worker writes into a hidden directory beside its intended output, validates the temporary MP4 with `ffprobe`, and only then moves it to the reserved final name.

Temporary-looking source names ending in `.repaired.mkv` or `.part.mkv` are ignored, as are symlinks, unreadable files, and names containing terminal control characters. Worker directories use `.media-conversion.XXXXXX`; reservations use short `.media-conversion.<hash>.lock` directories.

Encoding, size checks, OMDb tagging, and post-tag validation all finish inside the worker directory. The MP4 is published only after every required step succeeds. Existing MP4s are either skipped or assigned a collision-safe numbered name; they are never overwritten.

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

The script automatically tries `ffmpeg-git` before `ffmpeg`, and `ffprobe-git` before `ffprobe`. Set `FFMPEG` and `FFPROBE` when different command names are needed. Run conversion as an unprivileged service account, not as `root`.

## Clone From `/etc`

Because the converter now loads its `lib/` modules, clone the repository rather than downloading only `convert.sh`:

```bash
cd /etc
sudo git clone https://github.com/jaysonguglietta/scripts.git scripts
sudo chmod +x /etc/scripts/MediaConversion/convert.sh
sudo chown -R root:root /etc/scripts/MediaConversion
sudo chmod 755 /etc/scripts/MediaConversion /etc/scripts/MediaConversion/lib
sudo chmod 755 /etc/scripts/MediaConversion/convert.sh
sudo chmod 644 /etc/scripts/MediaConversion/lib/*.sh
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

If Git is unavailable, download the public branch archive and extract the complete modular converter without deleting the local config:

```bash
archive="$(mktemp)"
curl -fsSL -o "$archive" \
  https://github.com/jaysonguglietta/scripts/archive/refs/heads/main.tar.gz
sudo install -d -m 755 /etc/scripts/MediaConversion
sudo tar -xzf "$archive" -C /etc/scripts/MediaConversion \
  --strip-components=2 scripts-main/MediaConversion
rm -f "$archive"
```

Do not download only `convert.sh`; `lib/common.sh`, `lib/media.sh`, and `lib/metadata.sh` are required at runtime.

The converter rejects symlinked or group/world-writable code by default. Keep executable code under a protected directory such as `/etc/scripts`; do not install it into a shared download directory. `MEDIA_CONVERSION_ALLOW_UNSAFE_PATHS=1` is an emergency compatibility bypass and should not be used in normal operation.

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

Inspect all streams or preview the decisions without writing files:

```bash
/etc/scripts/MediaConversion/convert.sh --inspect
/etc/scripts/MediaConversion/convert.sh --dry-run
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

Require a confirmed metadata match and successful MP4 tagging:

```bash
./convert.sh --strict-metadata
```

Skip a file instead of creating a numbered name when its intended MP4 already exists:

```bash
./convert.sh --existing skip
```

Disable QSV for predictable CPU encoding, or force an attempt while diagnosing the driver:

```bash
./convert.sh --qsv off
./convert.sh --qsv force --jobs 1
```

Select the second audio track after checking it with `--inspect`:

```bash
./convert.sh --track 2
```

Or use the absolute FFmpeg stream index when you already know it:

```bash
./convert.sh --audio-stream 2 --forced-subtitle-stream 0
```

`--track` is the 1-based audio track number among audio streams. `--audio-stream` is an absolute FFmpeg stream index. `--forced-subtitle-stream` is a zero-based position among subtitle streams. Manual selections must still be detected as English; the explicit force variables documented below are required for incorrectly tagged streams.

## CLI Reference

| Option | Meaning |
| --- | --- |
| `--target-size SIZE` | Best-effort final size cap such as `2GB`, `1.5GiB`, `700MB`, or raw bytes. |
| `--max-height HEIGHT` | Downscale to at most this pixel height while preserving aspect ratio. `0` disables scaling. |
| `--audio MODE` | `surround+stereo`, `surround`, or `stereo`. |
| `--track N` | Select the Nth audio track, where `1` is the first audio stream. |
| `--audio-stream INDEX` | Select an absolute audio stream index instead of automatic ranking. |
| `--forced-subtitle-stream N` | Select a zero-based subtitle position instead of automatic forced-English detection. |
| `--quality-encode` | Use software `libx265` before the standard encoder path. |
| `--x265-preset PRESET` | Set the x265 speed/quality preset. |
| `--jobs COUNT` | Set the maximum number of simultaneous workers. |
| `--refresh-metadata` | Request fresh OMDb data instead of reusing a confirmed sidecar. |
| `--strict-metadata` | Require confirmed OMDb metadata and successful tagging before publication. |
| `--strict-size` | Fail outputs that remain above the target and tolerance after retries. |
| `--existing POLICY` | Use `unique` for a numbered output or `skip` when the intended output exists. |
| `--qsv MODE` | Use `auto`, `off`, or `force` for Intel QSV. |
| `--validation MODE` | Use normal `probe` validation or a complete `decode` validation pass. |
| `--inspect` | Print stream metadata for each MKV and exit without lookup or conversion. |
| `--dry-run` | Print output, stream, subtitle, HDR, and encoder decisions without writing files. |
| `--print-subs-only` | Report forced-English subtitle detection without metadata lookup or conversion. |
| `-h`, `--help` | Print built-in help. |

Options support both `--name value` and `--name=value` forms where a value is required.

## Configuration

### Runtime

| Variable | Default | Meaning |
| --- | --- | --- |
| `FFMPEG` | auto | FFmpeg command or path. |
| `FFPROBE` | auto | ffprobe command or path. |
| `JOBS` | `1` | Maximum concurrent workers. Increase deliberately after measuring CPU, disk, and QSV capacity. |
| `VERBOSE` | `0` | Set to `1` for per-worker Bash tracing. |
| `FFMPEG_LOG_LEVEL` | `warning` | FFmpeg log level; progress statistics still display. |
| `REPAIR_MODE` | `auto` | `auto`, `always`, or `never`. |
| `FIX_TIMESTAMPS` | `1` | Generate timestamps and normalize negative timestamps. |
| `FAST_VIDEO_COPY` | `1` | Copy compatible H.264/HEVC video when no filter or quality encode is required. |
| `EXISTING_POLICY` | `unique` | Create a numbered name or `skip` an existing intended output. |
| `MEDIA_STATE_DIR` | XDG state, home state, or private per-UID temp fallback | Private metadata logs and locks. Must be absolute. |
| `VALIDATION_MODE` | `probe` | `probe` stream/duration checks or a full `decode` pass. |
| `DURATION_TOLERANCE_SECONDS` | `5` | Fixed source/output duration allowance in seconds. |
| `DURATION_TOLERANCE_PERMILLE` | `1` | Proportional tolerance in thousandths; `1` is 0.1 percent. |
| `STRICT_DISK_CHECK` | `0` | Set to `1` to stop when estimated free space is insufficient. |
| `MAX_RESERVATION_ATTEMPTS` | `10000` | Bound on collision-safe output-name attempts. |

### Audio And Subtitles

| Variable | Default | Meaning |
| --- | --- | --- |
| `AUDIO_MODE` | `surround+stereo` | Output `surround+stereo`, `surround`, or `stereo`. |
| `AUDIO_STREAM_INDEX` | `auto` | Automatic selection or an absolute stream index. |
| `AUDIO_TRACK_POSITION` | `auto` | Automatic selection or a 1-based audio track number. |
| `ALLOW_UNTAGGED_AUDIO_FALLBACK` | `1` | Allow blank, `und`, or `unknown` audio language tags. |
| `ALLOW_COMMENTARY_AUDIO_FALLBACK` | `0` | Allow commentary/accessibility audio only when no main track is suitable. |
| `FORCE_SELECTED_AUDIO_AS_ENGLISH` | `0` | Permit an explicitly selected, incorrectly tagged audio stream. Use only after inspection. |
| `AAC_STEREO_BR` | `192k` | AAC stereo bitrate. |
| `AC3_51_BR` | `640k` | AC-3 5.1 bitrate. |
| `SUBTITLE_MODE` | `burn` | `burn`, `copy`, or `extract`. |
| `FORCED_SUBTITLE_STREAM` | `auto` | Automatic selection or a subtitle-relative position. |
| `ALLOW_FORCED_TITLE_FALLBACK` | `1` | Use English/forced title text when tags are incomplete. |
| `FORCE_SELECTED_SUBTITLE_AS_ENGLISH` | `0` | Permit an explicitly selected subtitle that is not detected as forced English. |

Only the selected forced-English subtitle is retained; all other subtitle streams are dropped. Text codecs can be burned or converted to MP4 `mov_text`. With `SUBTITLE_MODE=burn`, bitmap codecs such as PGS are decoded and overlaid into the video. With `copy`, unsupported bitmap codecs are extracted (`.sup` for PGS, otherwise `.mks`) because MP4 cannot carry them as `mov_text`.

### Encoders And Size

| Variable | Default | Meaning |
| --- | --- | --- |
| `QSV_GLOBAL_QUALITY` | `22` | Intel QSV quality value. |
| `QSV_PRESET` | `medium` | Intel QSV preset. |
| `QSV_MODE` | `auto` | Preflight QSV automatically, disable it, or `force` an attempt. |
| `QSV_LOW_POWER` | `0` | Keep low-power mode off by default for broader Intel runtime compatibility. |
| `X264_CRF` | `20` | CPU x264 CRF when no size bitrate is active. |
| `X264_PRESET` | `veryfast` | CPU x264 preset. |
| `X264_THREADS` | `0` | x264 thread count; `0` lets FFmpeg use an automatic thread count. |
| `X265_CRF` | `23` | Software x265 CRF when no size bitrate is active. |
| `X265_PRESET` | `medium` | Software x265 preset. |
| `X265_THREADS` | `0` | x265 thread count; `0` lets FFmpeg decide. |
| `HDR_MODE` | `preserve` | Preserve HDR through 10-bit HEVC fallback or `reject` HDR inputs. |
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
| `MEDIA_CONVERSION_CONFIG` | auto | Optional config file path. When unset, the script auto-loads `media-conversion.local.env` beside `convert.sh`, then `$HOME/.config/media-conversion.env`. |
| `OMDB_URL` | `https://www.omdbapi.com` | API endpoint. HTTPS is required when a key is set. |
| `OMDB_INTERACTIVE` | `1` | Require a terminal confirmation before conversion, or set to `0` for automatic matches. |
| `OMDB_REFRESH` | `0` | Set to `1` to refresh confirmed sidecars. |
| `OMDB_CONFIRM_CACHED` | `1` | Re-confirm cached matches in interactive mode; set to `0` to reuse them silently. |
| `OMDB_CONNECT_TIMEOUT` | `5` | Connection timeout in seconds. |
| `OMDB_MAX_TIME` | `20` | Maximum request time in seconds. |
| `OMDB_RETRIES` | `2` | Retry count for API and poster requests. |
| `OMDB_RESPONSE_MAX_BYTES` | `1048576` | Maximum API response or accepted local sidecar size. |
| `POSTER_MAX_BYTES` | `10485760` | Maximum downloaded artwork size. |
| `POSTER_ALLOWED_HOSTS` | IMDb/Amazon media hosts | Comma-separated HTTPS artwork host allowlist. |
| `OMDB_LOG` | per-run file in `MEDIA_STATE_DIR` | Private metadata result log. Relative custom names are placed in the state directory. |
| `OMDB_LOG_LOCK` | `<log>.lock` | Synchronized log lock. Shared custom log locks persist to avoid cross-run races. |
| `KEEP_OMDB_SOURCE_SIDECAR` | `0` | Keep `<input>.omdb.json` after conversion. Successful tagged runs remove it by default. |
| `KEEP_OMDB_OUTPUT_SIDECAR` | `0` | Keep `<output>.omdb.json` after conversion. Duplicate output sidecars are removed by default. |
| `KEEP_OMDB_LOG` | `0` | Keep the default per-run log after success. Failed or explicitly configured shared logs always persist. |
| `STRICT_TAGGING` | `0` | Set to `1` to count metadata-tagging failure as file failure. |
| `STRICT_METADATA` | `0` | Require both a confirmed match and successful tagging; equivalent to `--strict-metadata`. |

Store the API key in a local config file that is not committed:

```bash
sudo install -o "$USER" -g "$(id -gn)" -m 600 \
  /etc/scripts/MediaConversion/media-conversion.local.env.example \
  /etc/scripts/MediaConversion/media-conversion.local.env
${EDITOR:-vi} /etc/scripts/MediaConversion/media-conversion.local.env
```

Example file content:

```bash
OMDB_API_KEY=replace_with_your_key
OMDB_INTERACTIVE=1
```

The config file must be a regular, non-symlink file owned by the current user or root and accessible only to its owner (`chmod 600`). Its parser accepts only documented `NAME=value` entries (with optional matching single or double quotes); it does not execute shell syntax, substitutions, or commands. Environment variables override config values, and CLI options override both.

The script loads that file automatically on startup, so you can just run:

```bash
/etc/scripts/MediaConversion/convert.sh
```

If you prefer a different location, point the script at it explicitly:

```bash
MEDIA_CONVERSION_CONFIG=/secure/path/media-conversion.env \
  /etc/scripts/MediaConversion/convert.sh
```

The key is removed from the exported environment before media tools start and sent through standard input to `curl`, so it is not included in child environments or process arguments. Do not launch the script with `bash -x`, which can expose config values while they are parsed.

Interactive mode confirms every direct or cached match before conversion. It lets you accept the match, choose from up to eight validated alternatives, enter a manual search, or skip tagging. It stops safely if no terminal is available. Set `OMDB_INTERACTIVE=0` for unattended automatic matching, or `OMDB_CONFIRM_CACHED=0` to keep interactive confirmation for new matches while reusing cached ones.

Use `--refresh-metadata` or `OMDB_REFRESH=1` to fetch a new direct match instead of starting with the cached response. Network failures preserve valid existing metadata. Rejected matches are replaced with an empty sidecar and are not silently reused.

Tagging is staged on a copy. AtomicParsley is preferred; if it fails, the original staged file is restored and FFmpeg is tried. A tagged file must pass stream and duration validation before it can replace the untagged MP4.

If you prefer a persistent metadata cache and audit trail, set:

```bash
KEEP_OMDB_SOURCE_SIDECAR=1
KEEP_OMDB_OUTPUT_SIDECAR=1
KEEP_OMDB_LOG=1
```

By default, successful runs remove generated input/output JSON, the per-run CSV, and its lock. Failed runs preserve the private CSV and confirmed source sidecar for diagnosis. Sidecars live beside the media file; `MEDIA_STATE_DIR` keeps logs and locks outside that directory.

## Output Validation

A final output must:

- Exist and be nonempty.
- Be readable by `ffprobe`.
- Contain at least one video stream and one audio stream.
- Contain no audio stream that is missing an English language tag.
- Have a positive duration.
- Stay within 0.1 percent or five seconds of the source duration, whichever tolerance is larger by default.
- Fully decode its first video and audio stream when `VALIDATION_MODE=decode` is selected.

Exit statuses are `0` for complete success, `1` when configuration or one or more files fail, and `130` after interruption.

## Troubleshooting

Use `VERBOSE=1 --jobs 1` to make a single worker's shell commands easy to follow. Repair and fast-copy diagnostics are also printed when those paths fail.

If no audio is selected, inspect stream indexes and language tags:

```bash
ffprobe -v error -select_streams a \
  -show_entries stream=index,codec_name,channels:stream_tags=language,title \
  -of compact=p=0:nk=0 input.mkv
```

Then use `--track N`, `--audio-stream INDEX`, or enable `ALLOW_UNTAGGED_AUDIO_FALLBACK=1` if the intended track is untagged. Known non-English tracks are rejected even when manually selected unless `FORCE_SELECTED_AUDIO_AS_ENGLISH=1` is deliberately set.

If subtitle detection is wrong, run `--inspect` or `--print-subs-only`, then use `--forced-subtitle-stream N`. A manual selection must still look forced and English unless `FORCE_SELECTED_SUBTITLE_AS_ENGLISH=1` is deliberately set.

If QSV is unavailable, fails its startup preflight, or the source uses an incompatible pixel format such as 4:2:2 or 4:4:4, the script logs the reason and uses software encoding. AV1 can be software-decoded and sent to QSV when its output pixel format is supported. Ten-bit input uses `p010le`; a failed QSV attempt is removed before fallback. Use `--qsv off` to bypass hardware encoding or `--quality-encode` to intentionally use software x265.

HDR inputs use a 10-bit x265 fallback rather than silently converting through 8-bit x264. Set `HDR_MODE=reject` if the workflow should stop instead. This script does not tone-map HDR to SDR.

If an output is too large, combine `--target-size`, `--max-height`, and `--audio stereo`. Increase `SIZE_RETRY_ATTEMPTS` for another bitrate correction, or add `--strict-size` for automation that must reject an oversized result.

If a previous process was killed with `SIGKILL`, an old `.media-conversion.<hash>.lock` directory or `.media-conversion.XXXXXX` worker directory may remain beside the intended output. Verify no converter owns it before removing that specific stale artifact. Normal interruption cleans reservations automatically.

Informational `libass` initialization messages are hidden at the default `FFMPEG_LOG_LEVEL=warning`; encoding warnings and progress statistics remain visible. Increase the level to `info` only while diagnosing a problem.

## Tests And CI

The test suite uses deterministic FFmpeg and ffprobe mocks; it does not require sample media:

```bash
cd /etc/scripts
bash MediaConversion/tests/run.sh
```

Run the static checks used by GitHub Actions when ShellCheck is installed:

```bash
bash -n MediaConversion/convert.sh MediaConversion/lib/*.sh \
  MediaConversion/tests/*.sh MediaConversion/tests/mocks/*
shellcheck -x MediaConversion/convert.sh MediaConversion/lib/*.sh \
  MediaConversion/tests/*.sh MediaConversion/tests/mocks/*
bash MediaConversion/tests/integration.sh
```

The integration test requires real `ffmpeg`, `ffprobe`, and `jq`; it builds a two-audio-track MKV and verifies English-only output, forced subtitle retention, full-decode validation, and artifact cleanup. CI pins third-party actions by commit and runs syntax validation, ShellCheck, the mock regression suite, and this real-media test.

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
|   |-- integration.sh
|   `-- run.sh
|-- CHANGELOG.md
|-- README.md
`-- SECURITY.md
```

See `SECURITY.md` before configuring an OMDb key, especially if an older revision of this public repository was used.
