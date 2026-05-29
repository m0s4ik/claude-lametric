#!/usr/bin/env bash
# ==============================================================================
# claude-lametric — Proxmox VE LXC installer (community-scripts style)
# Creates a Debian 12 LXC running a local HTTP server that LaMetric Time
# devices on the same LAN can poll to display Claude AI quota usage.
#
# Run on a Proxmox VE 8.x host as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/m0s4ik/claude-lametric/main/ct/claude-lametric.sh)"
# ==============================================================================

set -euo pipefail

APP="claude-lametric"
REPO_RAW="https://raw.githubusercontent.com/m0s4ik/claude-lametric/main"

# ---------- Colors & message helpers ----------
YW=$'\033[33m'; BL=$'\033[36m'; RD=$'\033[01;31m'; GN=$'\033[1;92m'
CL=$'\033[m'; BOLD=$'\033[1m'

msg_info()  { printf "${BL}  ›  %s...${CL}\n" "$1"; }
msg_ok()    { printf "${GN}  ✓  %s${CL}\n" "$1"; }
msg_warn()  { printf "${YW}  !  %s${CL}\n" "$1"; }
msg_error() { printf "${RD}  ✗  %s${CL}\n" "$1" >&2; exit 1; }

# ---------- Defaults (community-scripts style var_*) ----------
var_hostname="$APP"
var_cpu="1"
var_ram="256"
var_disk="2"
var_unprivileged="1"
var_net="dhcp"
var_gateway=""
var_bridge="vmbr0"
var_port="3000"
var_storage=""
var_ctid=""
CLAUDE_REFRESH_TOKEN=""

header_info() {
  clear 2>/dev/null || true
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

# ---------- Preflight ----------
check_root() {
  [[ $EUID -eq 0 ]] || msg_error "This script must be run as root on the Proxmox host"
}

check_proxmox() {
  command -v pct &>/dev/null && command -v pveversion &>/dev/null \
    || msg_error "This script requires Proxmox VE (pct / pveversion not found)"
}

ensure_whiptail() {
  if ! command -v whiptail &>/dev/null; then
    msg_info "Installing whiptail"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq whiptail >/dev/null 2>&1 \
      || msg_error "Could not install whiptail"
  fi
}

# ---------- whiptail helpers ----------
# Run whiptail and capture the result; treat Cancel/Esc as abort.
wt() { whiptail --backtitle "claude-lametric" "$@" 3>&1 1>&2 2>&3; }

# ---------- Storage selection ----------
select_storage() {
  # storages able to hold a container rootfs
  local list=() id type avail
  while read -r id type avail; do
    [[ -z "$id" ]] && continue
    list+=("$id" "$type (avail: ${avail})")
  done < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1{print $1, $2, $6}')

  if [[ ${#list[@]} -eq 0 ]]; then
    var_storage="local-lvm"
  elif [[ ${#list[@]} -eq 2 ]]; then
    var_storage="${list[0]}"
  else
    var_storage=$(wt --title "STORAGE POOL" \
      --menu "Choose the storage pool for the container rootfs:" 18 70 8 \
      "${list[@]}") || msg_error "Aborted at storage selection"
  fi
}

# ---------- Token prompt (always required) ----------
prompt_token() {
  CLAUDE_REFRESH_TOKEN=$(wt --title "CLAUDE REFRESH TOKEN" --passwordbox \
"Paste your Claude refresh token (field claudeAiOauth.refreshToken).

  Linux/WSL : cat ~/.claude/.credentials.json
  macOS     : security find-generic-password -s 'Claude Code-credentials' -w" \
    14 74) || msg_error "Aborted at token entry"
  [[ -n "$CLAUDE_REFRESH_TOKEN" ]] || msg_error "Refresh token cannot be empty"
}

# ---------- Default settings ----------
default_settings() {
  var_ctid=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
  select_storage
  printf "${BOLD}Using Default Settings${CL}\n"
  printf "  CTID %s · %s · %s core / %s MB / %s GB · %s · net: dhcp · unpriv · port %s\n\n" \
    "$var_ctid" "$var_hostname" "$var_cpu" "$var_ram" "$var_disk" "$var_storage" "$var_port"
}

# ---------- Advanced settings ----------
advanced_settings() {
  local nextid; nextid=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
  var_ctid=$(wt --title "CONTAINER ID" --inputbox "Set the Container ID" 8 60 "$nextid") \
    || msg_error "Aborted"
  var_hostname=$(wt --title "HOSTNAME" --inputbox "Set the hostname" 8 60 "$var_hostname") \
    || msg_error "Aborted"
  var_cpu=$(wt --title "CPU CORES" --inputbox "Number of CPU cores" 8 60 "$var_cpu") \
    || msg_error "Aborted"
  var_ram=$(wt --title "RAM" --inputbox "RAM in MB" 8 60 "$var_ram") \
    || msg_error "Aborted"
  var_disk=$(wt --title "DISK" --inputbox "Disk size in GB" 8 60 "$var_disk") \
    || msg_error "Aborted"

  select_storage

  var_bridge=$(wt --title "BRIDGE" --inputbox "Network bridge" 8 60 "$var_bridge") \
    || msg_error "Aborted"

  local net_choice
  net_choice=$(wt --title "NETWORK" --menu "IP address assignment" 12 60 2 \
    "dhcp"   "Automatic (DHCP)" \
    "static" "Static IP / CIDR") || msg_error "Aborted"
  if [[ "$net_choice" == "static" ]]; then
    var_net=$(wt --title "IP / CIDR" --inputbox "e.g. 192.168.1.50/24" 8 60 "192.168.1.50/24") \
      || msg_error "Aborted"
    var_gateway=$(wt --title "GATEWAY" --inputbox "e.g. 192.168.1.1" 8 60 "192.168.1.1") \
      || msg_error "Aborted"
  else
    var_net="dhcp"
  fi

  if wt --title "CONTAINER TYPE" --yesno "Create as UNPRIVILEGED container? (recommended)" 8 60; then
    var_unprivileged="1"
  else
    var_unprivileged="0"
  fi

  var_port=$(wt --title "APP PORT" --inputbox "HTTP port the server listens on" 8 60 "$var_port") \
    || msg_error "Aborted"
}

start() {
  ensure_whiptail
  local choice
  choice=$(wt --title "${APP} LXC" --menu "Choose installation type:" 12 60 2 \
    "1" "Default Settings (DHCP, unprivileged)" \
    "2" "Advanced Settings") || msg_error "Aborted"
  case "$choice" in
    1) default_settings ;;
    2) advanced_settings ;;
  esac
  prompt_token
}

# ---------- Template ----------
ensure_template() {
  msg_info "Checking Debian 12 template"
  local template_storage="local" template_name
  pveam update >/dev/null 2>&1 || true
  template_name=$(pveam available --section system 2>/dev/null \
    | awk '/debian-12.*standard.*amd64/{print $2}' | sort -V | tail -n1)
  [[ -n "$template_name" ]] || msg_error "Could not find a Debian 12 standard template via pveam"
  if ! pveam list "$template_storage" 2>/dev/null | grep -q "$template_name"; then
    msg_info "Downloading $template_name (this may take a while)"
    pveam download "$template_storage" "$template_name" >/dev/null
  fi
  TEMPLATE_REF="${template_storage}:vztmpl/${template_name}"
  msg_ok "Template ready: $template_name"
}

# ---------- LXC creation ----------
create_lxc() {
  msg_info "Creating LXC $var_ctid"
  local net_opts="name=eth0,bridge=$var_bridge"
  if [[ "$var_net" == "dhcp" ]]; then
    net_opts+=",ip=dhcp"
  else
    net_opts+=",ip=${var_net},gw=${var_gateway}"
  fi

  pct create "$var_ctid" "$TEMPLATE_REF" \
    --hostname "$var_hostname" \
    --cores "$var_cpu" \
    --memory "$var_ram" \
    --rootfs "${var_storage}:${var_disk}" \
    --net0 "$net_opts" \
    --unprivileged "$var_unprivileged" \
    --features nesting=1 \
    --onboot 1 \
    --start 0 \
    --description "Claude AI quota indicator for LaMetric Time" \
    >/dev/null
  msg_ok "Container $var_ctid created"

  msg_info "Starting container"
  pct start "$var_ctid" >/dev/null
  sleep 4
  msg_ok "Container started"
}

# ---------- Install inside the container ----------
install_inside_lxc() {
  msg_info "Installing dependencies inside LXC (apt + Node.js 22)"
  pct exec "$var_ctid" -- bash -lc '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg >/dev/null
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
    apt-get install -y -qq nodejs >/dev/null
    mkdir -p /opt/claude-lametric
  '
  msg_ok "Dependencies installed"

  msg_info "Fetching application from the repository"
  pct exec "$var_ctid" -- bash -lc "
    set -e
    curl -fsSL '${REPO_RAW}/app/server.js'    -o /opt/claude-lametric/server.js
    curl -fsSL '${REPO_RAW}/app/package.json' -o /opt/claude-lametric/package.json
  "
  msg_ok "Application deployed"

  msg_info "Writing service and credentials"
  # systemd unit
  local tmp_svc; tmp_svc=$(mktemp)
  cat > "$tmp_svc" <<EOF
[Unit]
Description=Claude LaMetric quota server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/claude-lametric
Environment=PORT=${var_port}
EnvironmentFile=/opt/claude-lametric/.env
ExecStart=/usr/bin/node /opt/claude-lametric/server.js
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
  pct push "$var_ctid" "$tmp_svc" /etc/systemd/system/claude-lametric.service
  rm -f "$tmp_svc"

  # .env with the secret (passed via stdin so it never appears in argv)
  printf 'CLAUDE_REFRESH_TOKEN=%s\n' "$CLAUDE_REFRESH_TOKEN" \
    | pct exec "$var_ctid" -- bash -lc 'umask 077; cat > /opt/claude-lametric/.env; chmod 600 /opt/claude-lametric/.env'
  msg_ok "Service and credentials written"

  msg_info "Enabling systemd service"
  pct exec "$var_ctid" -- bash -lc '
    systemctl daemon-reload
    systemctl enable --now claude-lametric.service >/dev/null 2>&1
  '
  sleep 2
  if pct exec "$var_ctid" -- systemctl is-active claude-lametric.service >/dev/null 2>&1; then
    msg_ok "Service is running"
  else
    msg_warn "Service did not start cleanly — check: pct exec $var_ctid -- journalctl -u claude-lametric -n 50"
  fi
}

# ---------- Final summary ----------
show_summary() {
  local lxc_ip
  lxc_ip=$(pct exec "$var_ctid" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)
  lxc_ip="${lxc_ip:-<container-ip>}"
  cat <<EOF

${BOLD}${GN}  ★  Installation complete  ★${CL}

  Container       : ${BOLD}$var_ctid${CL}  ($var_hostname)
  Server endpoint : ${BOLD}${BL}http://${lxc_ip}:${var_port}/api${CL}

${BOLD}Next step — create the LaMetric app${CL}
  1. ${BL}https://developer.lametric.com${CL} → Create → Indicator App
  2. Communication type : Poll
     URL              : ${BL}http://${lxc_ip}:${var_port}/api${CL}
     Poll frequency   : 5 min
     Data format      : Predefined (LaMetric Format)
  3. Save as a Private app and install it on your LaMetric Time.

${YW}  Test the endpoint now:${CL}
     curl -s http://${lxc_ip}:${var_port}/api | jq .

EOF
}

main() {
  header_info
  check_root
  check_proxmox
  start
  ensure_template
  create_lxc
  install_inside_lxc
  show_summary
}

main "$@"
