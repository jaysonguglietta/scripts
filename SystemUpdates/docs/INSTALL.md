# Complete Fedora installation and rebuild guide

This guide builds a CPU-only local LLM server with:

- Fedora Linux
- Ollama running as a systemd service
- Six friendly assistants built from Ollama Modelfiles
- Open WebUI running as a root-managed Podman Quadlet
- A daily systemd timer that runs `updates.sh`

The example hardware is a quad-core Intel i7, 32 GB of RAM, a 250 GB SSD, no
GPU, and one or two users. Commands assume an administrator account with
`sudo` access. Run them in order.

## 1. Prepare Fedora

Update the operating system:

```bash
sudo dnf upgrade --refresh -y
sudo reboot
```

After reconnecting, install the required utilities:

```bash
sudo dnf install -y \
  curl \
  firewalld \
  git \
  htop \
  openssl \
  podman
```

Enable the firewall:

```bash
sudo systemctl enable --now firewalld
```

Confirm that SELinux remains enabled:

```bash
getenforce
```

Expected:

```text
Enforcing
```

## 2. Clone this repository

```bash
sudo mkdir -p /opt
cd /opt
sudo git clone https://github.com/jaysonguglietta/scripts.git
cd /opt/scripts/SystemUpdates
```

For an existing clone:

```bash
cd /opt/scripts
sudo git pull --ff-only
cd SystemUpdates
```

## 3. Install and enable Ollama

Install Ollama using its Linux installer:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Enable and start it:

```bash
sudo systemctl enable --now ollama.service
sudo systemctl status ollama.service --no-pager
```

Confirm the client is installed:

```bash
ollama --version
```

## 4. Install the CPU and container-network settings

Open WebUI runs in a container. Ollama binds only to `127.0.0.1` by default,
which a separate container cannot use. Install the supplied systemd drop-in:

```bash
sudo install -d -m 0755 /etc/systemd/system/ollama.service.d

sudo install \
  -o root \
  -g root \
  -m 0644 \
  /opt/scripts/SystemUpdates/systemd/ollama.service.d/override.conf \
  /etc/systemd/system/ollama.service.d/override.conf
```

Reload systemd and restart Ollama:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama.service
```

Verify the listener and API:

```bash
sudo ss -lntp | grep 11434
curl -fsS http://127.0.0.1:11434/api/tags
```

The listener should include `0.0.0.0:11434`. Do **not** open this port in
`firewalld`; the firewall guidance later in this document exposes only the
WebUI.

## 5. Pull the base models

These models fit within 32 GB of RAM when only one model is loaded at a time.
They are still CPU-bound, so the 4B model will be much faster than the 7B/8B
models.

```bash
ollama pull qwen2.5:7b
ollama pull qwen2.5-coder:7b
ollama pull qwen3:8b
ollama pull llama3.1:8b
ollama pull deepseek-r1:7b
ollama pull gemma3:4b
```

Confirm:

```bash
ollama list
```

## 6. Install and build the friendly assistants

Install all repository Modelfiles:

```bash
sudo install -d -m 0755 /etc/ollama/modelfiles

sudo install \
  -o root \
  -g root \
  -m 0644 \
  /opt/scripts/SystemUpdates/modelfiles/*.modelfile \
  /etc/ollama/modelfiles/
```

Build every friendly assistant:

```bash
for file in /etc/ollama/modelfiles/*.modelfile; do
  name="$(basename "$file" .modelfile)"
  ollama create "$name" -f "$file"
done
```

Verify:

```bash
ollama list
```

You should see these friendly names in addition to the technical base names:

```text
business-assistant:latest
coding-assistant:latest
fast-assistant:latest
general-assistant:latest
reasoning-assistant:latest
writing-assistant:latest
```

The custom entries normally reuse the base model's content-addressed layers;
they do not require another complete copy of every weight file.

## 7. Create the Open WebUI secret

The real secret belongs in `/etc`, not in Git:

```bash
sudo install -d -o root -g root -m 0750 /etc/open-webui

WEBUI_SECRET_KEY="$(openssl rand -hex 32)"
printf 'WEBUI_SECRET_KEY=%s\n' "$WEBUI_SECRET_KEY" |
  sudo tee /etc/open-webui/open-webui.env >/dev/null
unset WEBUI_SECRET_KEY

sudo chown root:root /etc/open-webui/open-webui.env
sudo chmod 0600 /etc/open-webui/open-webui.env
```

Confirm permissions without printing the secret:

```bash
sudo stat -c '%U:%G %a %n' /etc/open-webui/open-webui.env
```

Expected:

```text
root:root 600 /etc/open-webui/open-webui.env
```

## 8. Install Open WebUI as a Podman Quadlet

New Fedora installations should use Quadlet instead of the deprecated
`podman generate systemd` command.

Install the Quadlet:

```bash
sudo install -d -m 0755 /etc/containers/systemd

sudo install \
  -o root \
  -g root \
  -m 0644 \
  /opt/scripts/SystemUpdates/quadlet/open-webui.container \
  /etc/containers/systemd/open-webui.container
```

Ask systemd to regenerate units:

```bash
sudo systemctl daemon-reload
```

Inspect the generated unit before starting it:

```bash
sudo systemctl cat open-webui.service
```

Start it:

```bash
sudo systemctl start open-webui.service
sudo systemctl status open-webui.service --no-pager
```

The `[Install]` section inside the Quadlet connects it to
`multi-user.target` when the systemd generator runs. Do not be alarmed if
`systemctl enable open-webui.service` reports that the unit is generated or
transient; startup-at-boot is defined in the `.container` file.

Verify the container and HTTP endpoint:

```bash
sudo podman ps
curl -I http://127.0.0.1:3000/
```

## 9. Migrate an existing generated Podman service

Skip this section on a new installation. Do not run the legacy generated
service and the Quadlet at the same time because both use the container name
`open-webui` and host port `3000`.

First verify the persistent volume exists:

```bash
sudo podman volume inspect open-webui
```

Stop and disable the legacy service:

```bash
sudo systemctl disable --now container-open-webui.service
```

Back up and remove only the legacy unit file:

```bash
sudo mkdir -p /root/local-llm-backup
sudo cp -a \
  /etc/systemd/system/container-open-webui.service \
  /root/local-llm-backup/ 2>/dev/null || true
sudo rm -f /etc/systemd/system/container-open-webui.service
```

Remove a leftover container, but never remove the volume:

```bash
sudo podman rm -f open-webui 2>/dev/null || true
```

Then install and start the Quadlet using step 8. Do **not** run:

```text
podman volume rm open-webui
```

That would delete Open WebUI chats, users, settings, and document indexes.

## 10. Configure the firewall

Ollama must not be directly exposed. Check that port `11434` is not allowed:

```bash
sudo firewall-cmd --list-all
```

Remove a previously opened Ollama port if necessary:

```bash
ZONE="$(sudo firewall-cmd --get-default-zone)"
sudo firewall-cmd --permanent --zone="$ZONE" --remove-port=11434/tcp || true
sudo firewall-cmd --reload
```

For a trusted home LAN such as `192.168.1.0/24`, allow only that subnet to
reach Open WebUI:

```bash
ZONE="$(sudo firewall-cmd --get-default-zone)"

sudo firewall-cmd --permanent --zone="$ZONE" --remove-port=3000/tcp || true

sudo firewall-cmd --permanent --zone="$ZONE" \
  --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="3000" protocol="tcp" accept'

sudo firewall-cmd --reload
sudo firewall-cmd --zone="$ZONE" --list-all
```

Adjust the subnet before running the rich-rule command when your LAN is not
`192.168.1.0/24`.

Do not expose port `3000` directly to the Internet. Use a VPN or an
authenticated HTTPS reverse proxy for remote access.

## 11. Install the daily update script

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

Run a safe AI-only preview:

```bash
sudo /usr/local/sbin/updates.sh \
  --only-ai \
  --dry-run \
  --verbose
```

Then perform the first AI update:

```bash
sudo /usr/local/sbin/updates.sh --only-ai --verbose
```

## 12. Install the daily systemd timer

```bash
sudo install \
  -o root \
  -g root \
  -m 0644 \
  /opt/scripts/SystemUpdates/systemd/local-daily-updates.service \
  /etc/systemd/system/local-daily-updates.service

sudo install \
  -o root \
  -g root \
  -m 0644 \
  /opt/scripts/SystemUpdates/systemd/local-daily-updates.timer \
  /etc/systemd/system/local-daily-updates.timer

sudo systemctl daemon-reload
sudo systemctl enable --now local-daily-updates.timer
```

Verify the schedule:

```bash
systemctl list-timers local-daily-updates.timer
systemd-analyze calendar '*-*-* 03:15:00'
```

Run the service immediately as a final test:

```bash
sudo systemctl start local-daily-updates.service
sudo systemctl status local-daily-updates.service --no-pager
```

## 13. Open the WebUI

From a computer on the allowed LAN, browse to:

```text
http://SERVER-IP:3000/
```

For the server used in the original setup:

```text
http://192.168.1.102:3000/
```

The first account created becomes the Open WebUI administrator. Use a strong,
unique password.

Open a new chat and select one of the friendly assistants. In Open WebUI's
model administration page, hide the underlying technical model names when you
want users to see only the friendly choices.

## 14. Final verification checklist

```bash
sudo systemctl is-active ollama.service
sudo systemctl is-active open-webui.service
sudo systemctl is-active local-daily-updates.timer

curl -fsS http://127.0.0.1:11434/api/tags >/dev/null
curl -fsS http://127.0.0.1:3000/ >/dev/null

ollama list
sudo podman ps
systemctl list-timers local-daily-updates.timer
```

Every `is-active` command should return `active`.

## Official references

- Ollama Linux and systemd configuration:
  <https://docs.ollama.com/linux>
- Ollama environment variables and `OLLAMA_HOST`:
  <https://docs.ollama.com/faq>
- Ollama Modelfile reference:
  <https://docs.ollama.com/modelfile>
- Podman Quadlet reference:
  <https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html>
- Open WebUI Podman and Quadlet quick start:
  <https://docs.openwebui.com/getting-started/quick-start/>
- Open WebUI update guidance:
  <https://docs.openwebui.com/getting-started/updating/>
