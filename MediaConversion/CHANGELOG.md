# Changelog

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
