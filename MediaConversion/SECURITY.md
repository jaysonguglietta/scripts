# Security

## Credential Status

`convert.sh` does not contain a default OMDb API key. Configure `OMDB_API_KEY` in an ignored local config file and never commit that file.

An OMDb key was embedded in older revisions of this public repository. Removing it from the current branch does not remove it from Git history, forks, caches, or existing clones. That exposed key must be revoked and replaced through the OMDb account that issued it. A code change cannot complete this rotation.

Protect the replacement config:

```bash
chmod 600 /etc/scripts/MediaConversion/media-conversion.local.env
```

The converter rejects config files that are symlinks, have an unexpected owner, are group/world writable, or are group/world readable. Config is parsed as data from an allowlist of documented variables; shell substitutions and commands are not executed. Environment values override file values.

The key is removed from the exported environment before media tools start and is provided to `curl` on standard input instead of in its process arguments. Do not run the converter with `bash -x`, place the key directly in shell history, or include it in service unit text, logs, issue reports, or screenshots.

## Trusted Installation

Install executable code in a protected location such as `/etc/scripts/MediaConversion`, owned by the operator or `root` and not writable by group or others. The converter rejects symlinked or group/world-writable script, library, and state paths by default. Do not execute a copy stored in a shared downloads directory, especially as `root`.

Run conversions as a dedicated unprivileged account with access only to the intended media and state directories. When invoked as `root`, the script resets `PATH` to trusted system directories, but running as `root` is still discouraged because FFmpeg, subtitle parsers, image decoders, and media containers process attacker-controlled binary data.

`MEDIA_CONVERSION_ALLOW_UNSAFE_PATHS=1` disables bootstrap path checks. It exists only for exceptional compatibility cases and should not be used in a hostile or multi-user environment.

## Untrusted Media

Treat every MKV, embedded stream, subtitle, metadata tag, and local OMDb sidecar as untrusted. The converter:

- Ignores symlinked, unreadable, temporary-looking, and control-character input names.
- Selects only eligible English audio and forced-English subtitles unless an explicit force override is enabled.
- Excludes commentary and accessibility audio by default.
- Bounds and validates local/API JSON before use.
- Sanitizes converter-generated terminal and CSV output.
- Uses argument arrays rather than evaluating media-derived shell text.
- Writes into private random worker directories and atomically publishes only validated outputs.
- Never deletes or modifies source MKV files.

These controls do not make media codecs memory-safe. Keep Fedora, FFmpeg, libass, image libraries, Intel media drivers, `jq`, `curl`, and AtomicParsley patched. For higher-risk ingestion, run the service in a sandbox/container with CPU, memory, process, file-size, and wall-clock limits and no unnecessary network or filesystem access.

## Network And Metadata

OMDb requests require HTTPS, have connection/runtime/retry limits, and cap response size. Artwork downloads require HTTPS, do not follow redirects, must match `POSTER_ALLOWED_HOSTS`, are size-bounded, and must have JPEG or PNG magic bytes. Keep the default allowlist unless another trusted artwork host is intentionally required.

`OMDB_URL` is administrator-controlled and receives the API key. Pointing it at another HTTPS origin intentionally discloses the key to that origin, so protect config write access and review endpoint changes.

Use `--strict-metadata` when an untagged or incorrectly tagged file must not be published. Interactive confirmation is enabled by default, including confirmation of cached matches. Unattended `OMDB_INTERACTIVE=0` mode trusts OMDb's direct match and should be used only when that tradeoff is acceptable.

## Files, Logs, And Recovery

Output names are reserved across workers and script instances. Existing MP4s are never overwritten. Encoding, tagging, size enforcement, and post-tag validation all complete before atomic publication.

Per-run metadata logs and locks default to a private `MEDIA_STATE_DIR`. Successful runs remove generated sidecars and per-run audit artifacts unless keep options are enabled; failed runs retain diagnostic evidence. Logs can reveal filenames, paths, titles, and external artwork URLs, so do not expose the state directory or publish raw logs.

Normal `INT`/`TERM` handling terminates tracked worker process trees and cleans workers and reservations. `SIGKILL`, power loss, and system crashes cannot run cleanup. Before removing a stale `.media-conversion.*` directory, verify that no active converter owns it.

## History Rewriting

Purging the old key from Git history is separate from rotating it. A history rewrite requires a force-push, changes commit IDs, disrupts existing clones and open work, and cannot remove copies already fetched by others. Coordinate it explicitly before using a tool such as `git filter-repo`. Credential rotation is still required afterward.

## Reporting

Do not open a public issue containing credentials, private media names, full logs with sensitive paths, or exploit details. Contact the repository owner privately or use GitHub private vulnerability reporting if it is enabled.
