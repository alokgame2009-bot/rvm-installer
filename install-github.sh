#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="RVM Panel"
SERVICE_NAME="rvm-panel"
DEFAULT_DIR="/opt/rvm-panel"
DEFAULT_PORT="3000"
DEFAULT_DOMAIN="rvm.skylernodes.fun"
REPO="${REPO:-}"
APP_DIR="${APP_DIR:-$DEFAULT_DIR}"
PORT="${PORT:-$DEFAULT_PORT}"
DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"

c_red='\033[0;31m'; c_green='\033[0;32m'; c_yellow='\033[1;33m'
c_cyan='\033[0;36m'; c_blue='\033[0;34m'; c_magenta='\033[0;35m'; c_reset='\033[0m'
trap 'echo -e "\n${c_red}[✗] Installation failed.${c_reset}" >&2' ERR

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${c_yellow}Run as root or use sudo.${c_reset}"
    exit 1
  fi
}
banner() {
clear
echo -e "${c_cyan}"
cat <<'EOF'
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║        ██████╗ ██╗   ██╗███╗   ███╗                             ║
║        ██╔══██╗██║   ██║████╗ ████║                             ║
║        ██████╔╝██║   ██║██╔████╔██║                             ║
║        ██╔══██╗╚██╗ ██╔╝██║╚██╔╝██║                             ║
║        ██║  ██║ ╚████╔╝ ██║ ╚═╝ ██║                             ║
║        ╚═╝  ╚═╝  ╚═══╝  ╚═╝     ╚═╝                             ║
║                                                                  ║
║                     R V M   P A N E L                            ║
║                 VPS INSTALLATION SYSTEM                          ║
║                                                                  ║
║                 Powered by SkylerNodes 2026                      ║
╚══════════════════════════════════════════════════════════════════╝
EOF
echo -e "${c_reset}"
}
log(){ echo -e "${c_green}[✓]${c_reset} $*"; }
info(){ echo -e "${c_cyan}[•]${c_reset} $*"; }
fail(){ echo -e "${c_red}[✗]${c_reset} $*"; exit 1; }

install_base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl git nginx python3
  if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'parseInt(process.versions.node)')" -lt 20 ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  fi
  node -v; npm -v
  log "System dependencies ready"
}
get_repo() {
  if [[ -z "$REPO" ]]; then
    read -rp "GitHub repository URL: " REPO
  fi
  [[ "$REPO" =~ ^https://github\.com/[^/]+/[^/]+(\.git)?/?$ ]] || fail "Invalid GitHub repository URL."
}
clone_app() {
  rm -rf "$APP_DIR"
  git clone --depth 1 "$REPO" "$APP_DIR"
  cd "$APP_DIR"
  npm install
  npm run build
  log "RVM Panel downloaded and built"
}
setup_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=RVM Panel - SkylerNodes
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/npm start -- -p ${PORT}
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=${PORT}
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  log "RVM Panel service enabled"
}
setup_nginx() {
  cat > /etc/nginx/sites-available/rvm-panel <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  ln -sf /etc/nginx/sites-available/rvm-panel /etc/nginx/sites-enabled/rvm-panel
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  log "Nginx reverse proxy configured"
}
cloudflare_dns() {
  echo
  echo -e "${c_magenta}Cloudflare DNS${c_reset}"
  echo "This creates/updates an A record for ${DOMAIN}."
  read -rsp "Cloudflare API Token (leave blank to skip): " CF_TOKEN; echo
  [[ -z "$CF_TOKEN" ]] && { info "Cloudflare DNS skipped."; return; }
  read -rp "Public IPv4 [auto-detect]: " SERVER_IP
  SERVER_IP="${SERVER_IP:-$(curl -4fsS https://api.ipify.org || true)}"
  [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Could not determine IPv4."

  local zones zone_id zone_name payload resp
  zones="$(curl -fsS -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?per_page=100")"
  zone_name="$(printf '%s' "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')"
  zone_id="$(printf '%s' "$zones" | python3 -c 'import sys,json; d=json.load(sys.stdin); n=sys.argv[1]; print(next((z["id"] for z in d.get("result",[]) if z["name"]==n), ""))' "$zone_name" 2>/dev/null || true)"
  [[ -n "$zone_id" ]] || fail "Zone ${zone_name} was not found in this Cloudflare account."

  local record_name="$DOMAIN"
  local existing
  existing="$(curl -fsS -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${record_name}")"
  local record_id
  record_id="$(printf '%s' "$existing" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["result"][0]["id"] if d.get("result") else "")')"

  payload="$(python3 - "$record_name" "$SERVER_IP" <<'PY'
import json,sys
print(json.dumps({"type":"A","name":sys.argv[1],"content":sys.argv[2],"ttl":1,"proxied":True}))
PY
)"
  if [[ -n "$record_id" ]]; then
    resp="$(curl -fsS -X PUT -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" --data "$payload")"
  else
    resp="$(curl -fsS -X POST -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" --data "$payload")"
  fi
  printf '%s' "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); raise SystemExit(0 if d.get("success") else 1)'
  log "Cloudflare A record configured: ${DOMAIN} -> ${SERVER_IP}"
}
install_panel() {
  banner
  echo -e "${c_yellow}RVM Panel Installation${c_reset}"
  echo
  read -rp "Domain [${DEFAULT_DOMAIN}]: " DOMAIN_IN
  DOMAIN="${DOMAIN_IN:-$DEFAULT_DOMAIN}"
  read -rp "Panel port [${DEFAULT_PORT}]: " PORT_IN
  PORT="${PORT_IN:-$DEFAULT_PORT}"
  get_repo
  install_base
  clone_app
  setup_service
  setup_nginx
  cloudflare_dns
  echo
  echo -e "${c_green}╔══════════════════════════════════════════════════════════════╗"
  echo -e "║                 INSTALLATION COMPLETE                      ║"
  echo -e "╠══════════════════════════════════════════════════════════════╣"
  printf "║  Panel: http://%-47s║\n" "${DOMAIN}"
  printf "║  Local: http://127.0.0.1:%-35s║\n" "${PORT}"
  echo -e "║  Service: ${SERVICE_NAME}.service"
  echo -e "╚══════════════════════════════════════════════════════════════╝${c_reset}"
}
requirements() {
  command -v node >/dev/null && echo "Node: $(node -v)" || echo "Node: not installed"
  command -v npm >/dev/null && echo "npm : $(npm -v)" || echo "npm : not installed"
  command -v nginx >/dev/null && echo "Nginx: installed" || echo "Nginx: not installed"
  systemctl is-active --quiet "$SERVICE_NAME" && echo "Panel service: running" || echo "Panel service: not running"
}
system_info(){ echo "Hostname: $(hostname)"; echo "OS: $(. /etc/os-release && echo "$PRETTY_NAME")"; echo "Kernel: $(uname -r)"; echo "IPv4: $(curl -4fsS https://api.ipify.org 2>/dev/null || echo unknown)"; }
logs(){ journalctl -u "$SERVICE_NAME" -n 80 --no-pager; }
menu() {
  need_root
  while true; do
    banner
    echo " ┌──────────────────────────────────────────────────────────────┐"
    echo " │                         MAIN MENU                            │"
    echo " ├──────────────────────────────────────────────────────────────┤"
    echo " │  [1] RVM PANEL INSTALLATION                                 │"
    echo " │  [2] OS INSTALLATION                                        │"
    echo " │  [3] VPS & NETWORK                                          │"
    echo " │  [4] SSH & ZERO TRUST                                       │"
    echo " │  [5] DATABASE                                                │"
    echo " │  [6] SYSTEM REQUIREMENTS                                     │"
    echo " │  [7] SYSTEM INFORMATION                                      │"
    echo " │  [8] INSTALLATION LOGS                                       │"
    echo " │  [0] EXIT                                                    │"
    echo " └──────────────────────────────────────────────────────────────┘"
    echo
    read -rp " root@$(hostname) ➜ " choice
    case "$choice" in
      1) install_panel; read -rp "Press Enter to continue..." ;;
      2) echo "OS selection is managed by the RVM Panel virtualization backend."; read -rp "Press Enter..." ;;
      3) echo "VPS & Network configuration is managed by the RVM Panel."; read -rp "Press Enter..." ;;
      4) echo "SSH / Zero Trust configuration is optional and is not enabled automatically."; read -rp "Press Enter..." ;;
      5) echo "Database configuration is managed by the application."; read -rp "Press Enter..." ;;
      6) requirements; read -rp "Press Enter..." ;;
      7) system_info; read -rp "Press Enter..." ;;
      8) logs; read -rp "Press Enter..." ;;
      0) exit 0 ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}
menu
