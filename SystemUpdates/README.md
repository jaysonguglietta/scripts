# SystemUpdates

`updates.sh` is a Bash maintenance script for Fedora and Debian-family servers. It updates system packages, writes a timestamped log, checks whether a reboot is recommended, and can also refresh local AI components such as Ollama, installed Ollama models, and an Open WebUI Podman container.

## What it does

- Detects `dnf5`, `dnf`, or `apt-get` automatically.
- Refreshes package metadata and installs available updates.
- Removes unneeded packages and cleans caches after a real run.
- Writes a timestamped log file for each run.
- Supports a verbose mode with system details, pending updates, and before/after disk usage.
- Reports whether a reboot is recommended when the platform exposes that signal.
- Updates Ollama when it is installed.
- Re-pulls installed Ollama model tags so local models stay current.
- Pulls the current Open WebUI image and recreates the `open-webui` Podman container when the image changed.
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

```bash
./updates.sh --skip-ai
```

Run only the operating system package updates and reboot check.

```bash
./updates.sh --skip-models
```

Update Ollama and Open WebUI, but do not re-pull installed Ollama models.

```bash
./updates.sh --skip-open-webui
```

Update packages, Ollama, and installed Ollama models without touching the Open WebUI container.

```bash
OPEN_WEBUI_CONTAINER=my-open-webui ./updates.sh
```

Use a custom Podman container name for the Open WebUI update.

## Notes

- On Fedora, reboot detection uses `needs-restarting -r` when that command is installed.
- On Debian and Ubuntu, reboot detection uses `/var/run/reboot-required`.
- `apt-get update` still refreshes package metadata during `--dry-run` so the preview uses current repository data.
- `--dry-run` previews package, Ollama, model, and Open WebUI actions without applying AI component updates.
- Ollama is restarted after an RPM-managed package update or a downloaded installer run when `systemctl` can restart it.
- Open WebUI updates require `podman`; the script looks first for a root-owned container and then for a rootless container owned by the original `sudo` user.
- Before recreating Open WebUI, the script saves the existing container inspection JSON beside the run log.
- You can also enable the same extra output with `VERBOSE=1 ./updates.sh`.
