#!/usr/bin/env bash
# ==============================================================================
# claude-lametric — Proxmox VE LXC installer
# Creates a Debian 12 LXC running a local HTTP server that LaMetric Time
# devices on the same LAN can poll to display Claude AI quota usage.
#
# Run on a Proxmox VE 8.x host as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/m0s4ik/claude-lametric/main/ct/claude-lametric.sh)"
# ==============================================================================

set -euo pipefail

# ---------- Colors & message helpers (community-scripts style) ----------
YW=$'\033[33m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
CL=$'\033[m'
BOLD=$'\033[1m'

msg_info()  { printf "${BL}  ›  %s...${CL}\n" "$1"; }
msg_ok()    { printf "${GN}  ✓  %s${CL}\n" "$1"; }
msg_warn()  { printf "${YW}  !  %s${CL}\n" "$1"; }
msg_error() { printf "${RD}  ✗  %s${CL}\n" "$1" >&2; exit 1; }

header_info() {
  clear
  cat <<EOF
${BOLD}${BL}
   ___ _                _        _      __  __     _       _
  / __| |__ _ _  _ __ _| |___   | |    /  \\/  |___| |_ _ _(_)__
 | (__| / _\` | || / _\` | / -_)  | |__ / /\\_/\\ / -_)  _| '_| / _|
  \\___|_\\__,_|\\_,_\\__,_|_\\___|  |____/_/    \\_\\___|\\__|_| |_\\__|
${CL}
   ${YW}LaMetric Time indicator for Claude AI quota usage${CL}
   ${YW}Self-hosted Proxmox LXC — no cloud, no shared backend${CL}

EOF
}

# ---------- Preflight checks ----------
check_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root on the Proxmox host"
  fi
}

check_proxmox() {
  if ! command -v pct &>/dev/null || ! command -v pveversion &>/dev/null; then
    msg_error "This script requires Proxmox VE (pct / pveversion not found)"
  fi
  local ver
  ver=$(pveversion | head -n1 | grep -oE 'pve-manager/[0-9]+' | cut -d/ -f2 || true)
  if [[ -z "$ver" || "$ver" -lt 7 ]]; then
    msg_warn "Detected Proxmox VE older than 8.x — proceeding but untested"
  fi
}

# ---------- Configuration ----------
prompt() {
  local var_name="$1" label="$2" default="${3:-}"
  local value
  if [[ -n "$default" ]]; then
    read -rp "  $label [${default}]: " value
    value="${value:-$default}"
  else
    read -rp "  $label: " value
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_secret() {
  local var_name="$1" label="$2"
  local value
  read -rsp "  $label: " value
  echo
  printf -v "$var_name" '%s' "$value"
}

collect_config() {
  printf "\n${BOLD}Container settings${CL}\n"

  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")

  prompt CTID         "Container ID"        "$next_id"
  prompt HOSTNAME     "Hostname"            "claude-lametric"
  prompt CORES        "CPU cores"           "1"
  prompt RAM_MB       "RAM (MB)"            "256"
  prompt DISK_GB      "Disk (GB)"           "2"
  prompt STORAGE      "Storage pool"        "local-lvm"
  prompt BRIDGE       "Network bridge"      "vmbr0"
  prompt IP_CIDR      "IP/CIDR (or 'dhcp')" "dhcp"
  if [[ "$IP_CIDR" != "dhcp" ]]; then
    prompt GATEWAY    "Gateway"             ""
  fi
  prompt UNPRIVILEGED "Unprivileged (1/0)"  "1"

  printf "\n${BOLD}Claude credentials${CL}\n"
  printf "  Get the refresh token from ${YW}~/.claude/.credentials.json${CL} on a Mac/Linux\n"
  printf "  with the Claude CLI logged in. Field: claudeAiOauth.refreshToken\n\n"
  prompt_secret CLAUDE_REFRESH_TOKEN "Claude refresh token (hidden)"
  [[ -z "$CLAUDE_REFRESH_TOKEN" ]] && msg_error "Refresh token cannot be empty"

  printf "\n${BOLD}Application${CL}\n"
  prompt APP_PORT "HTTP port the server will listen on" "3000"

  cat <<EOF

${BOLD}Summary${CL}
  CTID            : $CTID
  Hostname        : $HOSTNAME
  Resources       : ${CORES} core / ${RAM_MB} MB / ${DISK_GB} GB on $STORAGE
  Network         : $BRIDGE — $IP_CIDR ${GATEWAY:+(gw $GATEWAY)}
  Unprivileged    : $UNPRIVILEGED
  App port        : $APP_PORT
  Refresh token   : ${CLAUDE_REFRESH_TOKEN:0:10}… (hidden)

EOF

  local confirm
  read -rp "  Proceed? [Y/n]: " confirm
  [[ "${confirm:-Y}" =~ ^[Yy]$ ]] || msg_error "Aborted by user"
}

# ---------- Template ----------
ensure_template() {
  msg_info "Checking Debian 12 template"
  local template_storage="local"
  local template_name
  template_name=$(pveam available --section system 2>/dev/null \
    | awk '/debian-12.*standard.*amd64/{print $2}' | sort -V | tail -n1)
  [[ -z "$template_name" ]] && msg_error "Could not find a Debian 12 standard template via pveam"

  if ! pveam list "$template_storage" 2>/dev/null | grep -q "$template_name"; then
    msg_info "Downloading $template_name (this may take a while)"
    pveam update >/dev/null
    pveam download "$template_storage" "$template_name" >/dev/null
  fi
  TEMPLATE_REF="${template_storage}:vztmpl/${template_name}"
  msg_ok "Template ready: $template_name"
}

# ---------- LXC creation ----------
create_lxc() {
  msg_info "Creating LXC $CTID"

  local net_opts="name=eth0,bridge=$BRIDGE"
  if [[ "$IP_CIDR" == "dhcp" ]]; then
    net_opts+=",ip=dhcp"
  else
    net_opts+=",ip=${IP_CIDR},gw=${GATEWAY}"
  fi

  pct create "$CTID" "$TEMPLATE_REF" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM_MB" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "$net_opts" \
    --unprivileged "$UNPRIVILEGED" \
    --features nesting=1 \
    --onboot 1 \
    --start 0 \
    --description "Claude AI quota indicator for LaMetric Time" \
    >/dev/null

  msg_ok "Container $CTID created"

  msg_info "Starting container"
  pct start "$CTID" >/dev/null
  sleep 4
  msg_ok "Container started"
}

# ---------- Install inside the container ----------
install_inside_lxc() {
  msg_info "Installing dependencies inside LXC (apt + Node.js 22)"
  pct exec "$CTID" -- bash -lc '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg >/dev/null
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
    apt-get install -y -qq nodejs >/dev/null
    mkdir -p /opt/claude-lametric
  '
  msg_ok "Dependencies installed"

  msg_info "Deploying application"
  local tmp_server tmp_pkg tmp_svc
  tmp_server=$(mktemp)
  tmp_pkg=$(mktemp)
  tmp_svc=$(mktemp)

  cat > "$tmp_pkg" <<'JSON'
{
  "name": "claude-lametric-server",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "engines": { "node": ">=18" }
}
JSON

  cat > "$tmp_server" <<'NODE'
const http = require('http');

const TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const OAUTH_BETA = 'oauth-2025-04-20';
const USER_AGENT = 'claude-lametric/1.0';
const PORT      = process.env.PORT || 3000;

const ICON_SESSION = 'i16776';
const ICON_WEEKLY  = 'i2867';
const ICON_CREDITS = 'i1334';
const ICON_ERROR   = 'i9182';

const REFRESH_TOKEN = process.env.CLAUDE_REFRESH_TOKEN;
if (!REFRESH_TOKEN) { console.error('CLAUDE_REFRESH_TOKEN not set'); process.exit(1); }

let cachedAccessToken = null;
let tokenExpiresAt    = 0;

async function getAccessToken() {
  if (cachedAccessToken && Date.now() < tokenExpiresAt - 60000) return cachedAccessToken;
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': USER_AGENT },
    body: JSON.stringify({ grant_type: 'refresh_token', refresh_token: REFRESH_TOKEN, client_id: CLIENT_ID }),
  });
  if (!res.ok) throw new Error('token_refresh_' + res.status);
  const data = await res.json();
  if (!data.access_token) throw new Error('token_refresh_no_access_token');
  cachedAccessToken = data.access_token;
  tokenExpiresAt    = data.expires_in ? Date.now() + data.expires_in * 1000 : Date.now() + 3600000;
  return cachedAccessToken;
}

async function fetchUsage() {
  const token = await getAccessToken();
  const res = await fetch(USAGE_URL, {
    headers: { Authorization: 'Bearer ' + token, 'anthropic-beta': OAUTH_BETA, 'User-Agent': USER_AGENT },
  });
  if (!res.ok) throw new Error('usage_api_' + res.status);
  return res.json();
}

function buildFrames(usage) {
  const frames = [];
  const s = Math.round(usage.five_hour?.utilization ?? 0);
  frames.push({ icon: ICON_SESSION, goalData: { start: 0, current: s, end: 100, unit: '%' } });
  frames.push({ icon: ICON_SESSION, text: '5h ' + s + '%' });
  const w = Math.round(usage.seven_day?.utilization ?? 0);
  frames.push({ icon: ICON_WEEKLY, goalData: { start: 0, current: w, end: 100, unit: '%' } });
  frames.push({ icon: ICON_WEEKLY, text: '7d ' + w + '%' });
  const ex = usage.extra_usage;
  if (ex?.is_enabled) {
    const used  = Number(ex.used_credits  ?? 0).toFixed(2);
    const limit = Number(ex.monthly_limit ?? 0).toFixed(0);
    frames.push({ icon: ICON_CREDITS, text: '$' + used + '/$' + limit });
  }
  return { frames };
}

http.createServer(async (req, res) => {
  if (req.url !== '/api' && req.url !== '/api/') { res.writeHead(404); res.end(); return; }
  res.setHeader('Content-Type', 'application/json');
  try {
    const usage = await fetchUsage();
    res.writeHead(200);
    res.end(JSON.stringify(buildFrames(usage)));
  } catch (err) {
    const type = err.message.split(':')[0];
    const isAuth = type.includes('401') || type.includes('403');
    console.error('error:', type);
    res.writeHead(200);
    res.end(JSON.stringify({ frames: [{ text: isAuth ? 'Bad token' : 'API error', icon: ICON_ERROR }] }));
  }
}).listen(PORT, '0.0.0.0', () => console.log('claude-lametric listening on ' + PORT));
NODE

  cat > "$tmp_svc" <<EOF
[Unit]
Description=Claude LaMetric quota server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/claude-lametric
Environment=PORT=${APP_PORT}
EnvironmentFile=/opt/claude-lametric/.env
ExecStart=/usr/bin/node /opt/claude-lametric/server.js
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

  pct push "$CTID" "$tmp_pkg"    /opt/claude-lametric/package.json
  pct push "$CTID" "$tmp_server" /opt/claude-lametric/server.js
  pct push "$CTID" "$tmp_svc"    /etc/systemd/system/claude-lametric.service

  # .env with the secret, 600 perms
  pct exec "$CTID" -- bash -lc "
    umask 077
    printf 'CLAUDE_REFRESH_TOKEN=%s\n' '$CLAUDE_REFRESH_TOKEN' > /opt/claude-lametric/.env
    chmod 600 /opt/claude-lametric/.env
  "

  rm -f "$tmp_server" "$tmp_pkg" "$tmp_svc"
  msg_ok "Application deployed"

  msg_info "Enabling systemd service"
  pct exec "$CTID" -- bash -lc '
    systemctl daemon-reload
    systemctl enable --now claude-lametric.service >/dev/null 2>&1
  '
  sleep 2
  if pct exec "$CTID" -- systemctl is-active claude-lametric.service >/dev/null 2>&1; then
    msg_ok "Service is running"
  else
    msg_warn "Service did not start cleanly — check: pct exec $CTID -- journalctl -u claude-lametric -n 50"
  fi
}

# ---------- Final summary ----------
show_summary() {
  local lxc_ip
  lxc_ip=$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)
  lxc_ip="${lxc_ip:-<container-ip>}"

  cat <<EOF

${BOLD}${GN}  ★  Installation complete  ★${CL}

  Container       : ${BOLD}$CTID${CL}  ($HOSTNAME)
  Server endpoint : ${BOLD}${BL}http://${lxc_ip}:${APP_PORT}/api${CL}

${BOLD}Next step — configure LaMetric${CL}

  1. Open ${BL}https://developer.lametric.com${CL} → Create → Indicator App
  2. Communication type : Poll
     URL              : ${BL}http://${lxc_ip}:${APP_PORT}/api${CL}
     Poll frequency   : 300 seconds
  3. Save as Private app and install it on your LaMetric Time device.

${YW}  Test the endpoint right now:${CL}
     curl -s http://${lxc_ip}:${APP_PORT}/api | jq .

EOF
}

# ---------- Main ----------
main() {
  header_info
  check_root
  check_proxmox
  collect_config
  ensure_template
  create_lxc
  install_inside_lxc
  show_summary
}

main "$@"
