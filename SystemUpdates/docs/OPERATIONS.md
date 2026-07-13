# Operations and maintenance guide

This document covers routine administration after the initial installation.
For a rebuild, begin with [INSTALL.md](INSTALL.md).

## Service overview

| Component | Service or command | Purpose |
|---|---|---|
| Ollama | `ollama.service` | Loads and serves local models |
| Open WebUI, Quadlet | `open-webui.service` | Browser interface |
| Open WebUI, legacy | `container-open-webui.service` | Older generated Podman unit |
| Daily maintenance | `local-daily-updates.service` | Runs one update job |
| Daily schedule | `local-daily-updates.timer` | Starts the job each day |

Only one Open WebUI service should exist at a time.

## Daily health check

```bash
sudo systemctl status ollama.service --no-pager
sudo systemctl status open-webui.service --no-pager
sudo systemctl status local-daily-updates.timer --no-pager

curl -fsS http://127.0.0.1:11434/api/tags >/dev/null &&
  echo "Ollama API is healthy"

curl -fsS http://127.0.0.1:3000/ >/dev/null &&
  echo "Open WebUI is healthy"

ollama list
sudo podman ps
```

For the legacy generated container service, replace `open-webui.service` with
`container-open-webui.service`.

## Start, stop, restart, and logs

Ollama:

```bash
sudo systemctl start ollama.service
sudo systemctl stop ollama.service
sudo systemctl restart ollama.service
sudo journalctl -u ollama.service -n 100 --no-pager
```

Open WebUI:

```bash
sudo systemctl start open-webui.service
sudo systemctl stop open-webui.service
sudo systemctl restart open-webui.service
sudo journalctl -u open-webui.service -n 100 --no-pager
```

Follow live logs:

```bash
sudo journalctl -u open-webui.service -f
```

## Run maintenance manually

Preview every action:

```bash
sudo /usr/local/sbin/updates.sh --dry-run --verbose
```

Update only the local-AI stack:

```bash
sudo /usr/local/sbin/updates.sh --only-ai --verbose
```

Update Fedora but skip Ollama and Open WebUI:

```bash
sudo /usr/local/sbin/updates.sh --skip-ai --verbose
```

Other useful controls:

```bash
sudo /usr/local/sbin/updates.sh --skip-ollama
sudo /usr/local/sbin/updates.sh --skip-models
sudo /usr/local/sbin/updates.sh --skip-assistants
sudo /usr/local/sbin/updates.sh --skip-open-webui
sudo /usr/local/sbin/updates.sh --clean-cache
```

The script uses a lock file so a timer run and manual run cannot overlap.

## Inspect the daily timer

```bash
systemctl list-timers local-daily-updates.timer
sudo systemctl status local-daily-updates.timer --no-pager
sudo systemctl cat local-daily-updates.timer
```

Change the run time by editing:

```text
/etc/systemd/system/local-daily-updates.timer
```

Then reload and restart the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl restart local-daily-updates.timer
systemctl list-timers local-daily-updates.timer
```

`Persistent=true` means a missed run occurs after the next boot.

## Read update results

The script writes private, timestamped logs to:

```text
/var/log/system-updates/
```

List the newest:

```bash
sudo ls -lht /var/log/system-updates/ | head
```

Read the most recent file:

```bash
LATEST_LOG="$(sudo find /var/log/system-updates -maxdepth 1 \
  -type f -name 'updates-*.log' -printf '%T@ %p\n' |
  sort -nr |
  awk 'NR == 1 {print $2}')"

sudo less "$LATEST_LOG"
```

Read the systemd journal:

```bash
sudo journalctl \
  -u local-daily-updates.service \
  --since today \
  --no-pager
```

## Model roles

| Friendly name | Base model | Intended role |
|---|---|---|
| `business-assistant` | `qwen2.5:7b` | Business, cloud, security, and policy work |
| `coding-assistant` | `qwen2.5-coder:7b` | Code and infrastructure as code |
| `fast-assistant` | `gemma3:4b` | Faster routine questions |
| `general-assistant` | `qwen3:8b` | General-purpose chat |
| `reasoning-assistant` | `deepseek-r1:7b` | Analysis and troubleshooting |
| `writing-assistant` | `llama3.1:8b` | Editing and professional writing |

The `:7b` or `:8b` suffix indicates the approximate parameter class of the
base model. The friendly model is a local customization built from a
Modelfile.

## Update one model manually

```bash
ollama pull qwen3:8b
ollama create general-assistant \
  -f /etc/ollama/modelfiles/general-assistant.modelfile
```

The daily script performs both operations automatically for all installed
base models and all repository-style Modelfiles.

## Add another friendly assistant

Create a lowercase filename:

```bash
sudo tee /etc/ollama/modelfiles/linux-assistant.modelfile >/dev/null <<'EOF'
FROM qwen3:8b

PARAMETER num_ctx 4096
PARAMETER temperature 0.5

SYSTEM """
You are a careful Fedora and Linux administration assistant.
Explain commands before presenting them and warn before destructive changes.
"""
EOF
```

Build it:

```bash
ollama create linux-assistant \
  -f /etc/ollama/modelfiles/linux-assistant.modelfile
```

The next daily run discovers it automatically. To make it reproducible, add
the Modelfile to this repository as well.

## Change an assistant prompt

Edit the installed Modelfile:

```bash
sudoedit /etc/ollama/modelfiles/business-assistant.modelfile
```

Rebuild it immediately:

```bash
ollama create business-assistant \
  -f /etc/ollama/modelfiles/business-assistant.modelfile
```

Also update the corresponding repository template so a future rebuild retains
the change.

## Remove an assistant

Remove only the friendly model:

```bash
ollama rm business-assistant
```

Optionally remove its Modelfile:

```bash
sudo rm /etc/ollama/modelfiles/business-assistant.modelfile
```

Do not remove a base model while another Modelfile references it.

## Install a newly released model family

The daily script updates existing tags; it does not decide when to migrate to
a different family. Test a new family alongside the current one:

```bash
ollama pull NEW-MODEL:TAG
ollama run NEW-MODEL:TAG
```

After testing, update the relevant `FROM` line and rebuild the friendly model.
Keep the old base model until the new assistant has been validated.

## Update the repository templates on the server

```bash
cd /opt/scripts
sudo git pull --ff-only
```

Reinstall changed operational files:

```bash
sudo install -o root -g root -m 0750 \
  SystemUpdates/updates.sh /usr/local/sbin/updates.sh

sudo install -o root -g root -m 0644 \
  SystemUpdates/modelfiles/*.modelfile /etc/ollama/modelfiles/

sudo install -o root -g root -m 0644 \
  SystemUpdates/systemd/local-daily-updates.service \
  /etc/systemd/system/local-daily-updates.service

sudo install -o root -g root -m 0644 \
  SystemUpdates/systemd/local-daily-updates.timer \
  /etc/systemd/system/local-daily-updates.timer

sudo install -o root -g root -m 0644 \
  SystemUpdates/quadlet/open-webui.container \
  /etc/containers/systemd/open-webui.container

sudo systemctl daemon-reload
```

Rebuild assistants after updating the templates:

```bash
sudo /usr/local/sbin/updates.sh --only-ai --verbose
```

## Choose the Open WebUI update strategy

The supplied Quadlet tracks:

```text
ghcr.io/open-webui/open-webui:main
```

This is appropriate for a homelab that prioritizes the latest features, but a
new build can introduce regressions. For greater stability, replace `:main`
in `/etc/containers/systemd/open-webui.container` with a tested version tag.

After changing the image:

```bash
sudo systemctl daemon-reload
sudo podman pull ghcr.io/open-webui/open-webui:YOUR-TAG
sudo systemctl restart open-webui.service
```

Back up Open WebUI before an update that may run database migrations.

## Back up Open WebUI

Create a backup directory:

```bash
sudo install -d -o root -g root -m 0700 /var/backups/local-llm
```

Stop Open WebUI for a consistent database backup:

```bash
sudo systemctl stop open-webui.service
```

Find the named-volume mount point and archive it:

```bash
VOLUME_PATH="$(sudo podman volume inspect open-webui \
  --format '{{.Mountpoint}}')"

sudo tar \
  -C "$VOLUME_PATH" \
  -czf "/var/backups/local-llm/open-webui-$(date +%Y%m%d-%H%M%S).tar.gz" \
  .
```

Restart:

```bash
sudo systemctl start open-webui.service
```

Also back up local configuration:

```bash
sudo tar -czf \
  "/var/backups/local-llm/local-llm-config-$(date +%Y%m%d-%H%M%S).tar.gz" \
  /etc/ollama/modelfiles \
  /etc/open-webui \
  /etc/containers/systemd/open-webui.container \
  /etc/systemd/system/ollama.service.d \
  /etc/systemd/system/local-daily-updates.service \
  /etc/systemd/system/local-daily-updates.timer \
  /usr/local/sbin/updates.sh
```

The second archive contains the Open WebUI secret and must remain private.

## Restore Open WebUI data

Stop the service:

```bash
sudo systemctl stop open-webui.service
```

Locate the volume:

```bash
VOLUME_PATH="$(sudo podman volume inspect open-webui \
  --format '{{.Mountpoint}}')"
```

Create a safety archive of the current contents, clear the volume, and
restore the selected backup:

```bash
sudo tar \
  -C "$VOLUME_PATH" \
  -czf "/var/backups/local-llm/open-webui-pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz" \
  .

sudo find "$VOLUME_PATH" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

sudo tar -C "$VOLUME_PATH" -xzf /path/to/open-webui-backup.tar.gz
sudo restorecon -RFv "$VOLUME_PATH"
```

Restart and inspect logs:

```bash
sudo systemctl start open-webui.service
sudo journalctl -u open-webui.service -n 100 --no-pager
```

Test restoration on a noncritical system when the data is important.

## Disk-space checks

```bash
df -h /
ollama list
sudo podman system df
sudo du -sh /var/lib/ollama 2>/dev/null || true
sudo du -sh /usr/share/ollama/.ollama 2>/dev/null || true
```

Do not run broad Podman volume pruning on this server. An unused-looking
volume may contain the only copy of Open WebUI data.
