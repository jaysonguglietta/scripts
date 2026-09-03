# Changelog

## 2026-09-03

### Security And Trust Boundaries

- Replaced executable config sourcing with a data-only variable allowlist, enforced owner-only config permissions, and stopped exporting the OMDb key to child processes.
- Added trusted path checks for the script, libraries, state directory, logs, and configs; root executions now use a fixed system `PATH`.
- Bounded and schema-validated OMDb responses and local sidecars, sanitized terminal/CSV output, and neutralized spreadsheet formulas.
- Restricted poster downloads to HTTPS allowlisted hosts, disabled redirects, capped response size, and verified JPEG/PNG signatures.
- Rejected symlinked/unreadable/control-character inputs and bounded output-name collision attempts.

### Transactional Reliability

- Moved tagging and post-tag validation ahead of final MP4 publication, and added atomic no-clobber publication so strict failures or late filename races cannot overwrite or leave a successful-looking output.
- Added optional full-decode validation and proportional duration tolerance for long media.
- Moved per-run audit logs and locks into a private state directory, removed unlocked fallback writes, and protected shared custom lock files from cross-run cleanup races.
- Added `--existing unique|skip`, `--inspect`, and `--dry-run` workflows.
- Improved parallel scheduling with `wait -n` on modern Bash while retaining compatibility fallback behavior.

### Media Policies And Performance

- Excluded commentary and accessibility audio by default and enforced language checks on manual audio selections.
- Enforced forced-English checks on manual subtitle selections, while retaining explicit opt-in overrides for incorrectly tagged media.
- Added bitmap subtitle burning, PGS `.sup` extraction, safer text-filter path escaping, and overlay end-of-stream handling.
- Added QSV startup preflight, `auto|off|force` control, a compatibility-first low-power setting, 10-bit `p010le` support, AV1 software-decode/QSV encode support, and clean software fallback.
- Added HDR preservation through 10-bit software HEVC fallback, optional HDR rejection, one-worker/automatic-thread performance defaults, and quieter FFmpeg logging.
- Used confirmed episode metadata for TV size policy even when the source filename lacks an `SxxExx` pattern.

### Verification And Documentation

- Expanded deterministic regression coverage from 20 to 35 tests, including adversarial config, metadata, artwork, selection, validation, and strict-publication scenarios.
- Updated installation, operation, security, cleanup, metadata, stream-selection, QSV/HDR, and troubleshooting documentation.

## 2026-08-07

### Metadata Matching

- Made interactive OMDb confirmation strict by default: conversion now stops if confirmation cannot be completed while `OMDB_INTERACTIVE=1`.
- Added a richer OMDb selection flow so operators can accept the first match, browse alternatives, run a manual search, or skip metadata before conversion starts.
- Documented how to force a fresh metadata prompt with `--refresh-metadata` or `OMDB_REFRESH=1`.

### Audio And Encoding

- Added `--track N` and `AUDIO_TRACK_POSITION` to select the Nth audio track when the preferred English stream is not the first audio stream.
- Preflight Intel QSV eligibility and skip it cleanly for AV1 or unsupported pixel formats before falling back to CPU x264.

### Documentation

- Updated the operator guide and sample config to reflect the new metadata-confirmation default, audio-track override, and encoder fallback behavior.

## 2026-07-13

### Safety And Reliability

- Reworked conversion around reserved output names, isolated adjacent worker directories, partial files, cleanup traps, and atomic publication.
- Added per-worker status tracking, reliable batch failure counts, recursive signal cleanup, and nonzero exit statuses.
- Added startup configuration validation, dependency discovery, disk-space estimation, and final ffprobe validation.
- Excluded stale `.repaired.mkv` and `.part.mkv` files from input discovery.
- Added best-effort size safety margins, encoded-output retries, strict size mode, fast-copy oversize fallback, and final post-tag size checks.

### Streams And Encoding

- Expanded English and regional language matching and added optional title-based forced-subtitle detection.
- Added manual audio and subtitle stream overrides.
- Added untagged and `und` audio fallback while penalizing commentary and accessibility tracks.
- Added text subtitle copy/burn handling and bitmap forced-subtitle sidecar extraction.
- Added safe H.264/HEVC fast copy, both FFmpeg DTS-warning spellings, repair retry isolation, QSV fallback, and optional software x265.

### Metadata And Security

- Removed the embedded OMDb key and required runtime configuration for new lookups.
- Enforced HTTPS, request failures, timeouts, retries, bounded alternatives, atomic JSON writes, and poster MIME validation.
- Preserved confirmed sidecars through API outages and discarded explicitly rejected matches.
- Added synchronized CSV logging with separate matched and tagged status.
- Added metadata-only FFmpeg tagging, AtomicParsley fallback, staged validation, and original-file preservation on tag failure.

### Maintenance

- Split the script into focused `common`, `media`, and `metadata` modules.
- Added deterministic Bash regression tests and GitHub Actions syntax, ShellCheck, and test jobs.
- Added operator, configuration, troubleshooting, security, and test documentation.
