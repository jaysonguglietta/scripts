# Security and privacy guidance

This project is intended for a private local server. A local model can reduce
external data exposure, but it does not automatically make the system secure.

## Network exposure

The intended traffic path is:

```text
LAN user -> TCP 3000 -> Open WebUI container -> Podman host bridge -> Ollama 11434
```

Ollama uses `OLLAMA_HOST=0.0.0.0:11434` so the container can reach it. That
does **not** mean clients should connect to port `11434` directly.

Required controls:

- Do not add `11434/tcp` to `firewalld`.
- Limit `3000/tcp` to the trusted LAN.
- Do not forward either port from an Internet router.
- For remote use, prefer a VPN such as WireGuard or Tailscale.
- When using a reverse proxy, require HTTPS and authentication.

Audit listeners and firewall rules:

```bash
sudo ss -lntp | grep -E ':(3000|11434)[[:space:]]'
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --list-all
```

## Authentication

Open WebUI uses multi-user authentication by default. The first account
created becomes the administrator.

- Use a strong, unique administrator password.
- Create separate accounts for separate people.
- Do not share the administrator account.
- Review user permissions before enabling document upload or tools.
- Remove unused accounts promptly.

## Protect `WEBUI_SECRET_KEY`

The Quadlet reads:

```text
/etc/open-webui/open-webui.env
```

The file must be owned by root with mode `0600`:

```bash
sudo chown root:root /etc/open-webui/open-webui.env
sudo chmod 0600 /etc/open-webui/open-webui.env
sudo stat -c '%U:%G %a %n' /etc/open-webui/open-webui.env
```

Never commit the real file to Git. A persistent secret avoids invalidating
sessions when Open WebUI is recreated.

## Local-only Ollama mode

Ollama can expose optional cloud features in newer releases. To force a
local-only server, uncomment this line in the Ollama systemd drop-in:

```ini
Environment="OLLAMA_NO_CLOUD=1"
```

Then apply it:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama.service
```

This disables Ollama cloud models and related cloud features. Confirm that this
matches the desired functionality before enabling it.

## Update risk

Daily updates improve patch speed but increase change frequency.

- Fedora packages may require a reboot; the script reports but does not reboot.
- Ollama model tags can change while retaining the same friendly name.
- Open WebUI's `:main` tag tracks the newest build and may introduce breaking
  changes.
- Back up Open WebUI before upgrades likely to include database migrations.
- For a more stable shared service, pin a tested Open WebUI release tag and
  review release notes before changing it.

The update script does not delete models, volumes, or application data.

## Sensitive documents and prompts

Local processing keeps routine Ollama inference on the server, but sensitive
content can still appear in:

- Open WebUI chat history
- Uploaded-document indexes
- Browser caches
- Server backups
- System and container logs
- Diagnostic bundles copied for troubleshooting

Treat Open WebUI's persistent volume and backups as sensitive. Encrypt backup
media and limit filesystem access.

A local model may follow malicious instructions embedded in uploaded
documents. Retrieval-augmented generation does not eliminate prompt injection.
Review outputs before using them for security, legal, medical, financial, or
production-operational decisions.

## Model trust and licensing

Before business use:

- Review each model's license and acceptable-use terms.
- Record which exact model tag is approved.
- Test updates before relying on them for critical workflows.
- Do not assume a model's answer is accurate because it runs locally.
- Do not give a model unrestricted shell, cloud, or administrative credentials.

## Fedora and Podman controls

- Keep SELinux enforcing.
- Use a named Podman volume for Open WebUI data.
- Avoid privileged containers.
- Do not mount the Podman socket into Open WebUI.
- Do not use `podman volume prune` as routine maintenance.
- Keep the host's SSH configuration and administrator accounts hardened.

## File permissions

Recommended modes:

| Path | Owner | Mode |
|---|---|---|
| `/usr/local/sbin/updates.sh` | `root:root` | `0750` |
| `/etc/ollama/modelfiles/*.modelfile` | `root:root` | `0644` |
| `/etc/open-webui/open-webui.env` | `root:root` | `0600` |
| `/etc/containers/systemd/open-webui.container` | `root:root` | `0644` |
| `/var/log/system-updates` | `root:root` | private files created with umask `0077` |

Audit them:

```bash
sudo stat -c '%U:%G %a %n' \
  /usr/local/sbin/updates.sh \
  /etc/open-webui/open-webui.env \
  /etc/containers/systemd/open-webui.container
```

## Backups

Back up:

- Open WebUI's `open-webui` volume
- `/etc/ollama/modelfiles`
- `/etc/open-webui`
- `/etc/containers/systemd`
- Ollama's systemd drop-in
- The daily timer and service
- The active update script

The configuration archive contains secrets and must not be placed in this
public repository.
