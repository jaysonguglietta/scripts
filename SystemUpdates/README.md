# SystemUpdates

A reproducible Fedora local-LLM build and daily-maintenance bundle for a
CPU-only server.

The documented reference system is a quad-core Intel i7 with 32 GB RAM, a
250 GB SSD, no GPU, and one or two users. It runs Ollama on the host and Open
WebUI as a systemd-managed Podman container.

Current maintenance script: **`updates.sh` 2.2.1**

## Documentation

- [Complete installation and rebuild](docs/INSTALL.md)
- [Routine operations, models, updates, and backups](docs/OPERATIONS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Security and privacy](docs/SECURITY.md)

## Repository layout

```text
SystemUpdates/
├── README.md
├── updates.sh
├── docs/
│   ├── INSTALL.md
│   ├── OPERATIONS.md
│   ├── SECURITY.md
│   └── TROUBLESHOOTING.md
├── modelfiles/
│   ├── business-assistant.modelfile
│   ├── coding-assistant.modelfile
│   ├── fast-assistant.modelfile
│   ├── general-assistant.modelfile
│   ├── reasoning-assistant.modelfile
│   └── writing-assistant.modelfile
├── quadlet/
│   ├── open-webui.container
│   └── open-webui.env.example
└── systemd/
    ├── local-daily-updates.service
    ├── local-daily-updates.timer
    └── ollama.service.d/
        └── override.conf
```

The repository contains templates only. The real Open WebUI secret is created
under `/etc/open-webui` and is never committed.

## Architecture

```text
Trusted LAN users
        |
        | TCP 3000
        v
Open WebUI Podman container
        |
        | http://host.containers.internal:11434
        v
Ollama systemd service
        |
        v
Local base models and friendly assistants
```

Port `11434` is intentionally not exposed through `firewalld`. Open WebUI is
the user-facing entry point.

## Quick start

On a new Fedora server, follow
[the complete installation guide](docs/INSTALL.md). The condensed sequence is:

```bash
sudo dnf install -y curl firewalld git htop openssl podman
sudo systemctl enable --now firewalld

sudo mkdir -p /opt
cd /opt
sudo git clone https://github.com/jaysonguglietta/scripts.git

curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl enable --now ollama.service
```

Then install the supplied templates exactly as documented in
[INSTALL.md](docs/INSTALL.md). That guide includes:

- Ollama's container-reachable systemd configuration
- base-model downloads
- friendly-assistant creation
- the Open WebUI secret
- a modern Podman Quadlet
- LAN-only firewall rules
- the daily maintenance script and timer
- migration from the deprecated `podman generate systemd` workflow

## Friendly assistants

| Friendly choice | Base model | Use |
|---|---|---|
| `business-assistant` | `qwen2.5:7b` | Business, cloud, security, and policy work |
| `coding-assistant` | `qwen2.5-coder:7b` | Programming and infrastructure as code |
| `fast-assistant` | `gemma3:4b` | Faster routine questions |
| `general-assistant` | `qwen3:8b` | General-purpose chat |
| `reasoning-assistant` | `deepseek-r1:7b` | Analysis and troubleshooting |
| `writing-assistant` | `llama3.1:8b` | Editing and professional writing |

The technical base names remain installed because the friendly models reference
them. Open WebUI can hide the technical names from normal users.

## What the daily script updates

A normal run:

1. Updates Fedora/DNF or Debian/APT packages.
2. Updates Ollama.
3. Discovers every installed base model and every `FROM` reference in
   `/etc/ollama/modelfiles`.
4. Pulls the base-model tags.
5. Skips locally created friendly names during the pull phase.
6. Rebuilds every friendly model.
7. Pulls the configured Open WebUI image.
8. Restarts Open WebUI only when required.
9. Performs HTTP health checks.
10. Reports whether a reboot is recommended.
11. Writes a private timestamped log and summary.

It does not reboot automatically, delete models, delete Podman volumes, or
delete Open WebUI data.

## Install or refresh the maintenance script

```bash
cd /opt/scripts
sudo git pull --ff-only

sudo install \
  -o root \
  -g root \
  -m 0750 \
  SystemUpdates/updates.sh \
  /usr/local/sbin/updates.sh

sudo bash -n /usr/local/sbin/updates.sh
sudo /usr/local/sbin/updates.sh --version
```

Expected:

```text
updates.sh 2.2.1
```

Preview the AI work:

```bash
sudo /usr/local/sbin/updates.sh \
  --only-ai \
  --dry-run \
  --verbose
```

Run it:

```bash
sudo /usr/local/sbin/updates.sh --only-ai --verbose
```

Show every option:

```bash
sudo /usr/local/sbin/updates.sh --help
```

## Supported Open WebUI service names

The script detects:

```text
open-webui.service             # Recommended Quadlet
container-open-webui.service   # Legacy generated service
```

Use only one. New installations should use
[`quadlet/open-webui.container`](quadlet/open-webui.container).

## Daily schedule

The supplied timer runs at 03:15 server-local time with up to 30 minutes of
random delay:

```bash
sudo install -o root -g root -m 0644 \
  SystemUpdates/systemd/local-daily-updates.service \
  /etc/systemd/system/local-daily-updates.service

sudo install -o root -g root -m 0644 \
  SystemUpdates/systemd/local-daily-updates.timer \
  /etc/systemd/system/local-daily-updates.timer

sudo systemctl daemon-reload
sudo systemctl enable --now local-daily-updates.timer
systemctl list-timers local-daily-updates.timer
```

## Important update-policy choice

The supplied Quadlet tracks:

```text
ghcr.io/open-webui/open-webui:main
```

Open WebUI recommends `:main` for personal/homelab systems that prioritize the
latest build, while a shared or critical system should pin and test a specific
release. Back up the Open WebUI volume before updates that may include database
migrations.

## Official references

- <https://docs.ollama.com/faq>
- <https://docs.ollama.com/modelfile>
- <https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html>
- <https://docs.openwebui.com/getting-started/quick-start/>
- <https://docs.openwebui.com/getting-started/updating/>
