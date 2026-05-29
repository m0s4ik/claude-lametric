# claude-lametric

A LaMetric Time indicator app that shows your **Claude AI quota usage** — the 5-hour session and 7-day weekly limits, exactly as shown in the Claude.ai interface.

Runs as a self-hosted HTTP server — one click on Proxmox, or [anywhere Node.js runs](#run-without-proxmox). **No cloud. No shared backend. Your refresh token never leaves your LAN.**

---

## What you see on the display

| Frame | Example | What it shows |
|-------|---------|---------------|
| Goal bar | ▓▓▓░░░░░ | 5-hour session usage |
| Text     | `5h 42%` | Same as percentage   |
| Goal bar | ▓░░░░░░░ | 7-day weekly usage   |
| Text     | `7d 18%` | Same as percentage   |
| Credits  | `$1.23/$50` | Extra credits (if enabled) |

---

## How it works

```
┌─────────────┐     poll /api      ┌───────────────────────┐     OAuth     ┌──────────────┐
│  LaMetric   │ ──────────────────▶│  LXC on Proxmox       │ ─────────────▶│  Anthropic   │
│  Time (LAN) │ ◀── frames JSON ───│  Node.js HTTP server  │ ◀── usage ────│  API         │
└─────────────┘     every 5 min    └───────────────────────┘               └──────────────┘
                                          │
                                          └── refresh_token sits in /opt/claude-lametric/.env (0600)
```

- LaMetric polls the LXC every 5 minutes over the local network.
- The LXC exchanges your `refreshToken` for a short-lived `accessToken` and queries the same OAuth usage endpoint that `claude.ai` uses internally.
- The token is stored in a `.env` file inside the container with 0600 permissions. It never appears in any URL or log line.

---

## Install — one command on Proxmox VE 8.x

SSH into your Proxmox host as root and run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/m0s4ik/claude-lametric/main/ct/claude-lametric.sh)"
```

The installer follows the community-scripts style: a `whiptail` menu lets you pick

- **Default Settings** — next free CTID, `claude-lametric`, 1 core / 256 MB / 2 GB, DHCP, unprivileged, port `3000`; you only pick the storage pool (if more than one) and paste the refresh token, or
- **Advanced Settings** — prompts for CTID, hostname, CPU/RAM/disk, storage, bridge, DHCP vs static IP, privileged/unprivileged, and port.

Either way it asks once for your **Claude refresh token** (hidden input). Then it downloads the Debian 12 template if missing, creates the LXC, installs Node.js 22, pulls `server.js` from this repo, writes the token to `/opt/claude-lametric/.env` (mode `0600`), and registers a systemd unit that auto-starts on boot.

At the end you get the endpoint URL — e.g. `http://192.168.1.42:3000/api`.

---

## Run without Proxmox

The Proxmox installer is just a convenience wrapper. The server itself is a single dependency-free Node.js file, so you can run it on **any machine with Node.js ≥ 18** — a regular Linux box, a Raspberry Pi, a NAS, macOS, WSL, or a Docker host. The only requirements are network reachability from your LaMetric (same LAN) and two env vars:

| Env var | Required | Default |
|---------|----------|---------|
| `CLAUDE_REFRESH_TOKEN` | yes | — |
| `PORT` | no | `3000` |

### Bare Node.js

```bash
git clone https://github.com/m0s4ik/claude-lametric.git
cd claude-lametric/app

export CLAUDE_REFRESH_TOKEN="ant-oauth-..."   # see "Get your Claude refresh token" below
export PORT=3000                              # optional

npm start          # → [claude-lametric] listening on port 3000
```

The endpoint is then `http://<this-machine-ip>:3000/api`.

### Run it as a service (systemd, no Proxmox)

On any Linux host with the repo cloned to `/opt/claude-lametric/app`:

```bash
sudo tee /etc/systemd/system/claude-lametric.service >/dev/null <<'EOF'
[Unit]
Description=claude-lametric
After=network-online.target

[Service]
WorkingDirectory=/opt/claude-lametric/app
ExecStart=/usr/bin/node server.js
Environment=CLAUDE_REFRESH_TOKEN=ant-oauth-...
Environment=PORT=3000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now claude-lametric
```

### Docker

```bash
docker run -d --name claude-lametric \
  -p 3000:3000 \
  -e CLAUDE_REFRESH_TOKEN="ant-oauth-..." \
  -w /app -v "$PWD/app:/app" \
  node:22-alpine node server.js
```

Whichever way you run it, the [Create the LaMetric app](#create-the-lametric-app) and [Verify it works](#verify-it-works) steps are identical — just point the LaMetric app at this machine's `http://<ip>:<port>/api` instead of the LXC.

> **Note:** outside an unprivileged LXC the token-at-rest hardening described in [Security model](#security-model) is up to you. Keep `CLAUDE_REFRESH_TOKEN` out of shell history and world-readable files, and don't expose the port to the internet.

---

## Get your Claude refresh token

Run this on any machine where you're logged into the Claude CLI. Where the credentials live depends on the OS:

**Linux / WSL** — plain JSON file:

```bash
cat ~/.claude/.credentials.json
# or extract the value directly:
jq -r '.claudeAiOauth.refreshToken' ~/.claude/.credentials.json
```

**macOS** — stored in the login Keychain, *not* in a file:

```bash
security find-generic-password -s "Claude Code-credentials" -w
# or extract the value directly:
security find-generic-password -s "Claude Code-credentials" -w | jq -r '.claudeAiOauth.refreshToken'
```

**Windows** — `%USERPROFILE%\.claude\.credentials.json` (read it with any text editor or `type`).

In every case the JSON looks like this — copy `claudeAiOauth.refreshToken`:

```json
{
  "claudeAiOauth": {
    "accessToken": "...",
    "refreshToken": "ant-oauth-...",  ← this one
    "expiresAt": 1234567890000
  }
}
```

> Treat it like a password — it can renew access tokens for your Claude account.

---

## Create the LaMetric app

LaMetric's **Poll** apps can't take the server address as a user-editable setting — the URL host must be a literal, not a variable — so this isn't published as a single shared Market app. Instead each user creates their own **private** indicator app pointing at their own server.

1. Go to [developer.lametric.com](https://developer.lametric.com) → **Create** → **Indicator App**
2. **Communication type:** Poll
3. **URL to get data from:** your server's LAN address followed by `/api`, e.g. `http://192.168.1.42:3000/api` — use the URL from the Proxmox installer summary, or `http://<this-machine-ip>:<port>/api` if you [run it yourself](#run-without-proxmox)
4. **Poll frequency:** `5 min`
5. **Data format:** `Predefined (LaMetric Format)` (the server already returns LaMetric frames)
6. Under **Create user interface**, click **Select icon** and pick any icon (e.g. an hourglass) — this is only the store/preview icon; at runtime the icons come from the server's frames
7. **Save** the app, then install it on your LaMetric Time as a **Private app**

> The polled URL is fixed in the developer portal — it is **not** editable from the LaMetric phone app. LaMetric's user-configurable parameters (`{{name}}` syntax) only work in the path/query of a URL with a fixed host, never as the host itself, so the server's address can't be a setting. Give the server a static IP/DHCP lease so the URL doesn't break; if it ever changes, update the URL in the developer portal and re-save the app.

The reference values are in [`lametric/developer-portal-config.json`](lametric/developer-portal-config.json).

---

## Verify it works

From any machine on the same LAN:

```bash
curl -s http://<lxc-ip>:3000/api | jq .
```

You should see something like:

```json
{
  "frames": [
    { "icon": "i16776", "goalData": { "start": 0, "current": 42, "end": 100, "unit": "%" } },
    { "icon": "i16776", "text": "5h 42%" },
    { "icon": "i2867",  "goalData": { "start": 0, "current": 18, "end": 100, "unit": "%" } },
    { "icon": "i2867",  "text": "7d 18%" }
  ]
}
```

---

## Maintenance

| Task | Command (on Proxmox host) |
|------|----------------------------|
| Check status | `pct exec <CTID> -- systemctl status claude-lametric` |
| View logs | `pct exec <CTID> -- journalctl -u claude-lametric -n 50 -f` |
| Restart service | `pct exec <CTID> -- systemctl restart claude-lametric` |
| Update refresh token | `pct exec <CTID> -- $EDITOR /opt/claude-lametric/.env && pct exec <CTID> -- systemctl restart claude-lametric` |

The refresh token is long-lived. If the LaMetric starts showing `Bad token`, copy a fresh value from `~/.claude/.credentials.json` and update `/opt/claude-lametric/.env`.

---

## Customize icons

The icon IDs are at the top of `app/server.js` (and embedded in the installer script):

```js
const ICON_SESSION = 'i16776'; // hourglass — 5h
const ICON_WEEKLY  = 'i2867';  // calendar  — 7d
const ICON_CREDITS = 'i1334';  // dollar    — extra credits
const ICON_ERROR   = 'i9182';  // warning   — errors
```

Browse the full LaMetric icon library at [developer.lametric.com/icons](https://developer.lametric.com/icons).

---

## Security model

- **Local-only.** The server binds to the LXC's LAN address. Don't port-forward it.
- **Token at rest:** `/opt/claude-lametric/.env`, mode `0600`, root-owned, inside an unprivileged LXC.
- **Token in motion:** never appears in URLs. It travels only LXC → `platform.claude.com` over HTTPS.
- **Logs:** the server logs only error types (`token_refresh_401`), never token values.
- **Open source.** Audit `ct/claude-lametric.sh` and `app/server.js` before running.

---

## Files

```
claude-lametric/
├── ct/claude-lametric.sh              ← Proxmox installer (run on the host)
├── app/server.js                      ← Node.js HTTP server (deployed in the LXC)
├── app/package.json
├── lametric/developer-portal-config.json   ← reference for the LaMetric portal
└── README.md
```

---

## Credits

Inspired by [claude-quota-display](https://github.com/fuziontech/claude-quota-display) by fuziontech for the OAuth flow, and by the [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) project for the installer style.

Uses the undocumented `api.anthropic.com/api/oauth/usage` endpoint — may break if Anthropic changes their internal API.
