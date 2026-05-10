#!/usr/bin/env bash
set -euo pipefail

export TERM=xterm

SECRETS_DIR="/root/.secrets"
USERS_ENV="$SECRETS_DIR/users.env"

[[ -f "$USERS_ENV" ]] || {
  echo "❌ users.env yok. Önce Part1 çalışmalı."
  exit 1
}

source "$USERS_ENV"

SSH_USER="$BACMASTER_USER"
SSH_PASS="$BACMASTER_PASS"

NET_IP="192.168.50.103"

TUNNEL_NAME="bacmaster"
DOMAIN="bacmastercloud.com"

PVE_IP="192.168.50.100"
TRUENAS_IP="192.168.50.101"
ARR_IP="192.168.50.102"
NEXTCLOUD_IP="192.168.50.104"
HA_IP="192.168.50.105"
MEDIA_IP="192.168.50.106"
CHIA_IP="192.168.50.107"

apt update
apt install -y sshpass

wait_ssh() {
  echo "⏳ SSH bekleniyor: $NET_IP"

  until sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    "$SSH_USER@$NET_IP" "echo ok" >/dev/null 2>&1; do
    sleep 5
  done

  echo "✅ SSH hazır: $NET_IP"
}

run_remote() {
  {
    printf '%s\n' "$SSH_PASS"
    cat
  } | sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    "$SSH_USER@$NET_IP" \
    "sudo -S -p '' bash -s"
}

wait_ssh

run_remote <<EOF
set -euo pipefail

TUNNEL_NAME="$TUNNEL_NAME"
DOMAIN="$DOMAIN"

CF_DIR="/home/bacmaster/docker/network/cloudflared"
CONFIG_FILE="\$CF_DIR/config.yml"

PVE_IP="$PVE_IP"
TRUENAS_IP="$TRUENAS_IP"
ARR_IP="$ARR_IP"
NET_IP="$NET_IP"
NEXTCLOUD_IP="$NEXTCLOUD_IP"
HA_IP="$HA_IP"
MEDIA_IP="$MEDIA_IP"
CHIA_IP="$CHIA_IP"

echo "📦 Cloudflared CLI kuruluyor..."

mkdir -p /usr/share/keyrings

curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | \
tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | \
tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

apt update
apt install -y cloudflared docker.io docker-compose-plugin python3

echo
echo "🔐 Cloudflare login gerekiyor."
echo "Açılan linki tarayıcıda aç, bacmastercloud.com domainini seç."
echo

cloudflared tunnel login

echo
echo "🚇 Tunnel oluşturuluyor: \$TUNNEL_NAME"
cloudflared tunnel create "\$TUNNEL_NAME" || true

TUNNEL_ID="\$(cloudflared tunnel list | awk -v name="\$TUNNEL_NAME" '\$0 ~ name {print \$1; exit}')"

if [[ -z "\$TUNNEL_ID" ]]; then
  echo "❌ Tunnel ID bulunamadı."
  cloudflared tunnel list
  exit 1
fi

echo "✅ Tunnel ID: \$TUNNEL_ID"

mkdir -p "\$CF_DIR"

CRED_SRC="/root/.cloudflared/\$TUNNEL_ID.json"
CRED_DEST="\$CF_DIR/\$TUNNEL_ID.json"

if [[ ! -f "\$CRED_SRC" ]]; then
  echo "❌ Credentials dosyası bulunamadı: \$CRED_SRC"
  exit 1
fi

cp "\$CRED_SRC" "\$CRED_DEST"
chown -R bacmaster:bacmaster "\$CF_DIR"

cat > "\$CONFIG_FILE" <<YAML
tunnel: \$TUNNEL_ID
credentials-file: /etc/cloudflared/\$TUNNEL_ID.json

ingress:
  - hostname: pve.\$DOMAIN
    service: https://\$PVE_IP:8006
    originRequest:
      noTLSVerify: true

  - hostname: truenas.\$DOMAIN
    service: http://\$TRUENAS_IP:80

  - hostname: qbittorrent.\$DOMAIN
    service: http://\$ARR_IP:8080

  - hostname: bacneyplus.\$DOMAIN
    service: http://\$ARR_IP:5055

  - hostname: status.\$DOMAIN
    service: http://\$NET_IP:3001

  - hostname: cloud.\$DOMAIN
    service: http://\$NEXTCLOUD_IP:8080

  - hostname: home.\$DOMAIN
    service: http://\$HA_IP:8123

  - hostname: ai.\$DOMAIN
    service: http://\$MEDIA_IP:3000

  - hostname: bacsflix.\$DOMAIN
    service: http://\$MEDIA_IP:8096

  - hostname: photos.\$DOMAIN
    service: http://\$MEDIA_IP:2283

  - hostname: sonarr.\$DOMAIN
    service: http://\$ARR_IP:8989

  - hostname: radarr.\$DOMAIN
    service: http://\$ARR_IP:7878

  - hostname: bazarr.\$DOMAIN
    service: http://\$ARR_IP:6767

  - hostname: prowlarr.\$DOMAIN
    service: http://\$ARR_IP:9696

  - hostname: adguard.\$DOMAIN
    service: http://\$NET_IP:3000

  - hostname: chia.\$DOMAIN
    service: http://\$CHIA_IP:8555

  - hostname: pve-api.\$DOMAIN
    service: https://\$PVE_IP:8006
    originRequest:
      noTLSVerify: true

  - hostname: qbittorrent-api.\$DOMAIN
    service: http://\$ARR_IP:8080

  - hostname: bacneyplus-api.\$DOMAIN
    service: http://\$ARR_IP:5055

  - hostname: status-api.\$DOMAIN
    service: http://\$NET_IP:3001

  - hostname: cloud-api.\$DOMAIN
    service: http://\$NEXTCLOUD_IP:8080

  - hostname: home-api.\$DOMAIN
    service: http://\$HA_IP:8123

  - hostname: bacsflix-api.\$DOMAIN
    service: http://\$MEDIA_IP:8096

  - hostname: photos-api.\$DOMAIN
    service: http://\$MEDIA_IP:2283

  - service: http_status:404
YAML

chown -R bacmaster:bacmaster "\$CF_DIR"

echo
echo "🌍 DNS route kayıtları ekleniyor..."
echo

HOSTNAMES=(
  "pve.\$DOMAIN"
  "truenas.\$DOMAIN"
  "qbittorrent.\$DOMAIN"
  "bacneyplus.\$DOMAIN"
  "status.\$DOMAIN"
  "cloud.\$DOMAIN"
  "home.\$DOMAIN"
  "ai.\$DOMAIN"
  "bacsflix.\$DOMAIN"
  "photos.\$DOMAIN"
  "sonarr.\$DOMAIN"
  "radarr.\$DOMAIN"
  "bazarr.\$DOMAIN"
  "prowlarr.\$DOMAIN"
  "adguard.\$DOMAIN"
  "chia.\$DOMAIN"
  "pve-api.\$DOMAIN"
  "qbittorrent-api.\$DOMAIN"
  "bacneyplus-api.\$DOMAIN"
  "status-api.\$DOMAIN"
  "cloud-api.\$DOMAIN"
  "home-api.\$DOMAIN"
  "bacsflix-api.\$DOMAIN"
  "photos-api.\$DOMAIN"
)

for HOST in "\${HOSTNAMES[@]}"; do
  echo "➡️ \$HOST"
  cloudflared tunnel route dns "\$TUNNEL_NAME" "\$HOST" || true
done

echo
echo "🐳 docker-compose cloudflared servisi güncelleniyor..."
echo

cd /home/bacmaster/docker/network

if [[ ! -f docker-compose.yml ]]; then
  echo "❌ docker-compose.yml bulunamadı: /home/bacmaster/docker/network"
  exit 1
fi

cp docker-compose.yml docker-compose.yml.bak.\$(date +%Y%m%d-%H%M%S)

python3 - <<'PY'
from pathlib import Path

p = Path("/home/bacmaster/docker/network/docker-compose.yml")
text = p.read_text()

new_block = """
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    command: tunnel --config /etc/cloudflared/config.yml run
    volumes:
      - ./cloudflared:/etc/cloudflared
    restart: unless-stopped
"""

lines = text.splitlines()
out = []
inside = False
found = False

for line in lines:
    if line.startswith("  cloudflared:"):
        found = True
        inside = True
        out.extend(new_block.strip("\\n").splitlines())
        continue

    if inside and line.startswith("  ") and not line.startswith("    ") and line.strip():
        inside = False

    if not inside:
        out.append(line)

if not found:
    if not text.endswith("\\n"):
        out.append("")
    out.extend(new_block.strip("\\n").splitlines())

p.write_text("\\n".join(out) + "\\n")
PY

docker compose up -d cloudflared

echo
echo "✅ Cloudflared local managed tunnel hazır."
echo
echo "Kontrol:"
echo "docker logs -f cloudflared"
echo
echo "Config:"
echo "\$CONFIG_FILE"
EOF
