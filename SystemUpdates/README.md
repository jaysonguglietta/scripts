# SystemUpdates

`updates.sh` is a daily maintenance script for Fedora/DNF and Debian/APT servers. In addition to operating-system updates, it maintains a local LLM installation based on Ollama, friendly/custom Ollama models, Podman, and Open WebUI.

Current script version: **2.2.1**

## What it updates

A normal run performs these operations in order:

1. Refreshes repositories and applies operating-system package updates.
2. Removes packages that are no longer required.
3. Updates Ollama when it was installed with Ollama's Linux installer, or relies on the package update when Ollama is RPM/DEB managed.
4. Finds every installed Ollama base model and every base model referenced by a custom Modelfile.
5. Runs `ollama pull` for each base model.
6. Skips friendly models during the pull phase so locally created names are not incorrectly requested from the public model registry.
7. Rebuilds every friendly model from `/etc/ollama/modelfiles/*.modelfile`.
8. Pulls the configured Open WebUI image.
9. Restarts Open WebUI only when its image or one of the Ollama model IDs changed.
10. Checks Ollama and Open WebUI health.
11. Reports whether a reboot is recommended.
12. Writes a timestamped log and prints a final summary.

The script does **not** reboot the server, delete Ollama models, remove Podman volumes, or delete Open WebUI application data.

## Supported Open WebUI services

The script automatically detects either of these system services:

```text
container-open-webui.service   # Created by the legacy podman generate systemd command
open-webui.service             # Created from a modern Podman Quadlet
```

The current Fedora installation described in this repository uses:

```text
container-open-webui.service
```

A new installation should generally use a Podman Quadlet.

## Install the script

Clone or update this repository:

```bash
sudo dnf install -y git
sudo mkdir -p /opt
cd /opt
sudo git clone https://github.com/jaysonguglietta/scripts.git
```

If the repository is already cloned:

```bash
cd /opt/scripts
sudo git pull --ff-only
```

Install the script in the system path:

```bash
sudo install \
  -o root \
  -g root \
  -m 0750 \
  /opt/scripts/SystemUpdates/updates.sh \
  /usr/local/sbin/updates.sh
```

Validate it:

```bash
sudo bash -n /usr/local/sbin/updates.sh
sudo /usr/local/sbin/updates.sh --version
```

Expected version:

```text
updates.sh 2.2.1
```

## First test

Preview only the local-AI actions:

```bash
sudo /usr/local/sbin/updates.sh \
  --only-ai \
  --dry-run \
  --verbose
```

Then run the local-AI update for real:

```bash
sudo /usr/local/sbin/updates.sh --only-ai --verbose
```

After that succeeds, run the complete update:

```bash
sudo /usr/local/sbin/updates.sh --verbose
```

## Friendly Ollama models

Friendly models are defined by Modelfiles in:

```text
/etc/ollama/modelfiles/
```

The filename becomes the friendly Ollama model name. For example:

```text
/etc/ollama/modelfiles/general-assistant.modelfile
```

is rebuilt with:

```bash
ollama create general-assistant \
  -f /etc/ollama/modelfiles/general-assistant.modelfile
```

and appears in `ollama list` as:

```text
general-assistant:latest
```

Use lowercase filenames containing letters, numbers, periods, underscores, or hyphens. A minimal Modelfile looks like this:

```text
FROM qwen3:8b

PARAMETER num_ctx 4096
PARAMETER temperature 0.7

SYSTEM """
You are a clear and practical general-purpose assistant.
"""
```

With the current set of assistants, the directory can contain:

```text
business-assistant.modelfile
coding-assistant.modelfile
fast-assistant.modelfile
general-assistant.modelfile
reasoning-assistant.modelfile
writing-assistant.modelfile
```

Each daily run reads the `FROM` line, updates the referenced base model, and then recreates the friendly model. Adding another lowercase `*.modelfile` does not require changing `updates.sh`.

## Command options

Show all options:

```bash
sudo /usr/local/sbin/updates.sh --help
```

Common commands:

```bash
# Preview everything
sudo /usr/local/sbin/updates.sh --dry-run --verbose

# Update only Ollama, models, assistants, and Open WebUI
sudo /usr/local/sbin/updates.sh --only-ai --verbose

# Update the operating system but skip all local-AI components
sudo /usr/local/sbin/updates.sh --skip-ai --verbose

# Do not pull base model updates
sudo /usr/local/sbin/updates.sh --skip-models

# Do not rebuild friendly models
sudo /usr/local/sbin/updates.sh --skip-assistants

# Do not update or restart Open WebUI
sudo /usr/local/sbin/updates.sh --skip-open-webui

# Clean package-manager caches during this run
sudo /usr/local/sbin/updates.sh --clean-cache
```

Package cache cleaning is disabled by default because the script is intended to run daily.

## Configuration overrides

The defaults can be changed with environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `OLLAMA_MODELFILE_DIR` | `/etc/ollama/modelfiles` | Directory containing friendly-model Modelfiles |
| `OLLAMA_SERVICE` | `ollama.service` | Ollama systemd service |
| `OLLAMA_API_URL` | `http://127.0.0.1:11434` | Local Ollama health-check URL |
| `OPEN_WEBUI_CONTAINER` | `open-webui` | Podman container name |
| `OPEN_WEBUI_SERVICE` | auto-detected | Explicit Open WebUI systemd service |
| `OPEN_WEBUI_IMAGE` | `ghcr.io/open-webui/open-webui:main` | Fallback image reference |
| `OPEN_WEBUI_HEALTH_URL` | `http://127.0.0.1:3000/` | WebUI health-check URL |
| `RESTART_WEBUI_AFTER_MODEL_CHANGES` | `1` | Restart WebUI when Ollama model IDs change |
| `LOG_DIR` | `/var/log/system-updates` | Log directory |
| `LOCK_FILE` | `/run/lock/local-llm-updates.lock` | Prevents overlapping runs |

Example:

```bash
sudo OPEN_WEBUI_SERVICE=container-open-webui.service \
  /usr/local/sbin/updates.sh --only-ai --verbose
```

## Run automatically every day

Create the systemd service:

```bash
sudo tee /etc/systemd/system/local-daily-updates.service >/dev/null <<'EOF_SERVICE'
[Unit]
Description=Daily system and Local LLM updates
After=network-online.target ollama.service container-open-webui.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/updates.sh --verbose
EOF_SERVICE
```

Create the timer:

```bash
sudo tee /etc/systemd/system/local-daily-updates.timer >/dev/null <<'EOF_TIMER'
[Unit]
Description=Run system and Local LLM updates daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now local-daily-updates.timer
```

Verify the schedule:

```bash
systemctl list-timers local-daily-updates.timer
```

Test the service immediately:

```bash
sudo systemctl start local-daily-updates.service
sudo systemctl status local-daily-updates.service --no-pager
```

## Logs

The script normally writes logs to:

```text
/var/log/system-updates/
```

Show the newest files:

```bash
sudo ls -lht /var/log/system-updates/ | head
```

Show the systemd service journal:

```bash
sudo journalctl \
  -u local-daily-updates.service \
  -n 200 \
  --no-pager
```

## Verification and troubleshooting

Check Ollama and its models:

```bash
sudo systemctl status ollama --no-pager
curl -s http://127.0.0.1:11434/api/tags
ollama list
```

Check Open WebUI:

```bash
sudo systemctl status container-open-webui.service --no-pager
sudo podman ps
curl -I http://127.0.0.1:3000/
```

For a Quadlet installation, replace `container-open-webui.service` with `open-webui.service`.

View recent service errors:

```bash
sudo journalctl -u ollama -n 100 --no-pager
sudo journalctl -u container-open-webui.service -n 100 --no-pager
```

If Open WebUI reports that it cannot connect to `host.containers.internal:11434`, verify the Ollama systemd override contains:

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
```

Then reload and restart Ollama:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
sudo ss -lntp | grep 11434
```

Do not expose port `11434/tcp` through `firewalld`; Open WebUI should access it through Podman's host bridge. Users should connect through the WebUI on port `3000` or through a secured reverse proxy.

## Update policy notes

- Running `ollama pull` updates the existing model tag. It does not automatically replace a model family with a newly released family.
- Friendly models are recreated after their base models are checked, so prompt changes and refreshed base models are applied.
- Tracking the Open WebUI `:main` image gives rapid updates but carries more regression risk than pinning a release tag.
- The script uses a lock file so two daily update runs cannot overlap.
- A failure in one AI component is recorded and summarized while the script attempts the remaining maintenance steps.
