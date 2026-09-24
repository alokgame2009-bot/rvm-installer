#!/usr/bin/env bash
set -Eeuo pipefail
APP_NAME="RVM Panel"
SERVICE_NAME="rvm-panel"
DEFAULT_DIR="/opt/rvm-panel"
DEFAULT_PORT="3000"
DEFAULT_DOMAIN="rvm.skylernodes.fun"
REPO="${REPO:-}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-$DEFAULT_DIR}"
PORT="${PORT:-$DEFAULT_PORT}"
DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; RESET='\033[0m'
trap 'echo -e "\n${RED}[✗] Installation failed.${RESET}" >&2' ERR
need_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash install-github.sh"; exit 1; }; }
banner(){ clear; echo -e "${CYAN}"; cat <<'EOF'
╔══════════════════════════════════════════════════════════════════╗
║                     R V M   P A N E L                            ║
║                 VPS INSTALLATION SYSTEM                         ║
║                 Powered by SkylerNodes 2026                      ║
╚══════════════════════════════════════════════════════════════════╝
EOF
echo -e "${RESET}"; }
log(){ echo -e "${GREEN}[✓]${RESET} $*"; }
info(){ echo -e "${CYAN}[•]${RESET} $*"; }
fail(){ echo -e "${RED}[✗]${RESET} $*"; exit 1; }
get_repo(){
  if [[ -z "$REPO" ]]; then read -rp "GitHub repository URL: " REPO; fi
  [[ "$REPO" =~ ^https://github\.com/[^/]+/[^/]+(\.git)?/?$ ]] || fail "Invalid GitHub repository URL."
  REPO="${REPO%.git}"; REPO="${REPO%/}"
}
raw_base(){ local path="${REPO#https://github.com/}"; echo "https://raw.githubusercontent.com/${path}/${BRANCH}"; }
install_base(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl nginx python3 tar gzip
  if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'parseInt(process.versions.node)')" -lt 20 ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  fi
  node -v; npm -v
  log "System dependencies ready"
}
download_app(){
  rm -rf "$APP_DIR"; mkdir -p "$APP_DIR"; cd "$APP_DIR"
  local base; base="$(raw_base)"
  info "Downloading RVM Panel application bundle..."
  curl -fL --retry 3 "${base}/rvm-app.tar.gz" -o /tmp/rvm-app.tar.gz
  tar -xzf /tmp/rvm-app.tar.gz -C "$APP_DIR"
  curl -fL --retry 3 "${base}/package.json" -o "$APP_DIR/package.json"
  [[ -d "$APP_DIR/app" ]] || fail "Application bundle is missing app/."
  npm install
  npm run build
  rm -f /tmp/rvm-app.tar.gz
  log "RVM Panel downloaded and built"
}
setup_service(){
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
systemctl daemon-reload; systemctl enable --now "$SERVICE_NAME"; log "RVM Panel service enabled"; }
setup_nginx(){
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
nginx -t; systemctl enable --now nginx; systemctl reload nginx; log "Nginx reverse proxy configured"; }
cloudflare_dns(){
 echo; echo -e "${MAGENTA}Cloudflare DNS (optional)${RESET}"
 read -rsp "Cloudflare API Token (leave blank to skip): " CF_TOKEN; echo
 [[ -z "$CF_TOKEN" ]] && { info "Cloudflare DNS skipped."; return; }
 local ip; read -rp "Public IPv4 [auto-detect]: " ip; ip="${ip:-$(curl -4fsS https://api.ipify.org)}"
 [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid IPv4."
 local zone="$(printf '%s' "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')"
 local zones="$(curl -fsS -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' "https://api.cloudflare.com/client/v4/zones?per_page=100")"
 local zid="$(printf '%s' "$zones" | python3 -c 'import sys,json; d=json.load(sys.stdin); n=sys.argv[1]; print(next((z["id"] for z in d.get("result",[]) if z["name"]==n),""))' "$zone")"
 [[ -n "$zid" ]] || fail "Cloudflare zone $zone not found."
 local existing="$(curl -fsS -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?type=A&name=$DOMAIN")"
 local rid="$(printf '%s' "$existing" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["result"][0]["id"] if d.get("result") else "")')"
 local payload="$(python3 - "$DOMAIN" "$ip" <<'PY'
import json,sys
print(json.dumps({"type":"A","name":sys.argv[1],"content":sys.argv[2],"ttl":1,"proxied":True}))
PY
)"
 if [[ -n "$rid" ]]; then curl -fsS -X PUT -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' "https://api.cloudflare.com/client/v4/zones/$zid/dns_records/$rid" --data "$payload" >/dev/null; else curl -fsS -X POST -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' "https://api.cloudflare.com/client/v4/zones/$zid/dns_records" --data "$payload" >/dev/null; fi
 log "Cloudflare A record configured: $DOMAIN -> $ip"; }
install_panel(){
 banner; echo -e "${YELLOW}RVM Panel Installation${RESET}"; echo
 read -rp "Domain [$DEFAULT_DOMAIN]: " d; DOMAIN="${d:-$DEFAULT_DOMAIN}"
 read -rp "Panel port [$DEFAULT_PORT]: " p; PORT="${p:-$DEFAULT_PORT}"
 get_repo; install_base; download_app; setup_service; setup_nginx; cloudflare_dns
 echo -e "${GREEN}\nRVM Panel installed: http://${DOMAIN}${RESET}"; }
requirements(){ command -v node >/dev/null && echo "Node: $(node -v)" || echo "Node: not installed"; command -v nginx >/dev/null && echo "Nginx: installed" || echo "Nginx: not installed"; systemctl is-active --quiet "$SERVICE_NAME" && echo "Panel: running" || echo "Panel: not running"; }
system_info(){ echo "Hostname: $(hostname)"; echo "OS: $(. /etc/os-release && echo "$PRETTY_NAME")"; echo "Kernel: $(uname -r)"; }
logs(){ journalctl -u "$SERVICE_NAME" -n 80 --no-pager; }
menu(){ need_root; while true; do banner; cat <<'EOF'
 [1] RVM PANEL INSTALLATION
 [2] OS INSTALLATION
 [3] VPS & NETWORK
 [4] SSH & ZERO TRUST
 [5] DATABASE
 [6] SYSTEM REQUIREMENTS
 [7] SYSTEM INFORMATION
 [8] INSTALLATION LOGS
 [0] EXIT
EOF
 echo; read -rp " root@$(hostname) ➜ " c; case "$c" in 1) install_panel; read -rp "Press Enter...";; 2) echo "OS selection is handled by the RVM Panel backend."; read -rp "Press Enter...";; 3) echo "VPS & Network configuration is handled by the RVM Panel."; read -rp "Press Enter...";; 4) echo "SSH / Zero Trust is optional and is not enabled automatically."; read -rp "Press Enter...";; 5) echo "Database configuration is handled by the application."; read -rp "Press Enter...";; 6) requirements; read -rp "Press Enter...";; 7) system_info; read -rp "Press Enter...";; 8) logs; read -rp "Press Enter...";; 0) exit 0;; *) echo "Invalid option"; sleep 1;; esac; done; }
menu
