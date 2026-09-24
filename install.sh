#!/usr/bin/env bash
set -Eeuo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${APP_DIR:-/opt/rvm-panel}"; PORT="${PORT:-3000}"; DOMAIN="${DOMAIN:-rvm.skylernodes.fun}"
[[ $EUID -eq 0 ]] || { echo 'Run as root: sudo bash install.sh'; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update; apt-get install -y ca-certificates curl nginx python3 tar gzip
if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'parseInt(process.versions.node)')" -lt 20 ]]; then curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; apt-get install -y nodejs; fi
rm -rf "$APP_DIR"; mkdir -p "$APP_DIR"
tar -xzf "$SRC_DIR/rvm-app.tar.gz" -C "$APP_DIR"
cp "$SRC_DIR/package.json" "$APP_DIR/package.json"
cd "$APP_DIR"; npm install; npm run build
cat > /etc/systemd/system/rvm-panel.service <<EOF
[Unit]
Description=RVM Panel - SkylerNodes
After=network.target
[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/npm start -- -p $PORT
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=$PORT
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/nginx/sites-available/rvm-panel <<EOF
server { listen 80; listen [::]:80; server_name $DOMAIN; location / { proxy_pass http://127.0.0.1:$PORT; proxy_http_version 1.1; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; } }
EOF
ln -sf /etc/nginx/sites-available/rvm-panel /etc/nginx/sites-enabled/rvm-panel; rm -f /etc/nginx/sites-enabled/default; nginx -t
systemctl daemon-reload; systemctl enable --now rvm-panel nginx; systemctl reload nginx
echo "RVM Panel installed: http://$DOMAIN"
