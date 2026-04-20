# SystemUpdates

`updates.sh` is a Bash maintenance script for Fedora and Debian-family servers.

## What it does

- Detects `dnf5`, `dnf`, or `apt-get` automatically.
- Refreshes package metadata and installs available updates.
- Removes unneeded packages and cleans caches after a real run.
- Writes a timestamped log file for each run.
- Supports a verbose mode with system details, pending updates, and before/after disk usage.
- Reports whether a reboot is recommended when the platform exposes that signal.
- Re-runs itself with `sudo` automatically when needed.

## Usage

```bash
./updates.sh
```

Run a normal update and write a log to `/var/log/system-updates` when possible.

```bash
./updates.sh --dry-run
```

Preview package changes without applying them.

```bash
./updates.sh --verbose
```

Show extra detail before and after the update run.

```bash
LOG_DIR=/path/to/logs ./updates.sh --verbose --no-reboot-check
```

Store logs in a custom location, turn on verbose output, and skip the reboot check.

## Notes

- On Fedora, reboot detection uses `needs-restarting -r` when that command is installed.
- On Debian and Ubuntu, reboot detection uses `/var/run/reboot-required`.
- `apt-get update` still refreshes package metadata during `--dry-run` so the preview uses current repository data.
- You can also enable the same extra output with `VERBOSE=1 ./updates.sh`.
