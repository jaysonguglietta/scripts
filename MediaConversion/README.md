# MediaConversion

`convert.sh` is a Bash batch converter for Fedora/Linux media servers that converts `.mkv` files to Plex-friendly `.mp4` files with Apple TV 4K-oriented defaults.

## What it does

- Repairs MKV inputs before encoding.
- Preserves English audio, preferring the highest-channel track.
- Keeps a 5.1-compatible track when possible and adds an AAC stereo fallback.
- Burns forced subtitles into the video when they exist.
- Uses Intel QSV HEVC when forced subtitle burn-in is not needed, with CPU fallback.
- Looks up OMDb metadata, downloads poster art, and tags the finished MP4.
- Renames output files from confirmed OMDb matches.
- Avoids silently overwriting an existing MP4 by picking a unique output name.
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
```

Example:

```bash
OMDB_API_KEY=your_key_here JOBS=2 ./convert.sh
```

## Notes

- The script works on the current directory only.
- Parallel OMDb log writes are synchronized when `flock` is available.
- If a QSV encode fails, the script falls back to CPU x264 encoding.
- Forced subtitle burn-in uses CPU encoding because subtitles are rendered into the video stream.
