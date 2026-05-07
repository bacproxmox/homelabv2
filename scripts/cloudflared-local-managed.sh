#!/usr/bin/env bash
set -euo pipefail

TUNNEL_NAME="bacmaster"
DOMAIN="bacmastercloud.com"

CF_DIR="/home/bacmaster/docker/network/cloudflared"
CONFIG_FILE="$CF_DIR/config.yml"

PVE_IP="192.168.50.100"
TRUENAS_IP="192.168.50.101"
ARR_IP="192.168.50.102"
NET_IP="192.168.50.103"
NEXTCLOUD_IP="192.168.50.104"
HA_IP="192.168.50.105"
MEDIA_IP="192.168.50.106"
CHIA_IP="192.168.50.108"

echo "📦 Cloudflared CLI kuruluyor..."

sudo mkdir -p -- /usr/share/keyrings

curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | \
sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | \
sudo tee /etc/apt/sources.list.d/cloudflared.list

sudo apt update
sudo apt install -y cloudflared

echo
echo "🔐 Cloudflare login gerekiyor."
echo "Açılan linki tarayıcıda aç, bacmastercloud.com domainini seç."
echo

cloudflared tunnel login

echo
echo "🚇 Tunnel oluşturuluyor: $TUNNEL_NAME"
echo "Eğer zaten varsa hata verebilir, sorun değil."
echo

cloudflared tunnel create "$TUNNEL_NAME" || true

TUNNEL_ID="$(cloudflared tunnel list | awk -v name="$TUNNEL_NAME" '$0 ~ name {print $1; exit}')"

if [[ -z "$TUNNEL_ID" ]]; then
  echo "❌ Tunnel ID bulunamadı."
  cloudflared tunnel list
  exit 1
fi

echo "✅ Tunnel ID: $TUNNEL_ID"

sudo mkdir -p "$CF_DIR"

CRED_SRC="/home/$USER/.cloudflared/$TUNNEL_ID.json"
CRED_DEST="$CF_DIR/$TUNNEL_ID.json"

if [[ ! -f "$CRED_SRC" ]]; then
  echo "❌ Credentials dosyası bulunamadı: $CRED_SRC"
  exit 1
fi

sudo cp "$CRED_SRC" "$CRED_DEST"
sudo chown -R bacmaster:bacmaster "$CF_DIR"

cat > "$CONFIG_FILE" <<EOF
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: pve.$DOMAIN
    service: https://$PVE_IP:8006
    originRequest:
      noTLSVerify: true

  - hostname: truenas.$DOMAIN
    service: http://$TRUENAS_IP:80

  - hostname: qbittorrent.$DOMAIN
    service: http://$ARR_IP:8080

  - hostname: bacneyplus.$DOMAIN
    service: http://$ARR_IP:5055

  - hostname: status.$DOMAIN
    service: http://$NET_IP:3001

  - hostname: cloud.$DOMAIN
    service: http://$NEXTCLOUD_IP:8080

  - hostname: home.$DOMAIN
    service: http://$HA_IP:8123

  - hostname: ai.$DOMAIN
    service: http://$MEDIA_IP:3000

  - hostname: bacsflix.$DOMAIN
    service: http://$MEDIA_IP:8096

  - hostname: photos.$DOMAIN
    service: http://$MEDIA_IP:2283

  - hostname: sonarr.$DOMAIN
    service: http://$ARR_IP:8989

  - hostname: radarr.$DOMAIN
    service: http://$ARR_IP:7878

  - hostname: bazarr.$DOMAIN
    service: http://$ARR_IP:6767

  - hostname: prowlarr.$DOMAIN
    service: http://$ARR_IP:9696

  - hostname: recyclarr.$DOMAIN
    service: http://$ARR_IP:9898

  - hostname: adguard.$DOMAIN
    service: http://$NET_IP:3000

  - hostname: chia.$DOMAIN
    service: http://$CHIA_IP:8555

  # API / App hostnames

  - hostname: pve-api.$DOMAIN
    service: https://$PVE_IP:8006
    originRequest:
      noTLSVerify: true

  - hostname: qbittorrent-api.$DOMAIN
    service: http://$ARR_IP:8080

  - hostname: bacneyplus-api.$DOMAIN
    service: http://$ARR_IP:5055

  - hostname: status-api.$DOMAIN
    service: http://$NET_IP:3001

  - hostname: cloud-api.$DOMAIN
    service: http://$NEXTCLOUD_IP:8080

  - hostname: home-api.$DOMAIN
    service: http://$HA_IP:8123

  - hostname: bacsflix-api.$DOMAIN
    service: http://$MEDIA_IP:8096

  - hostname: photos-api.$DOMAIN
    service: http://$MEDIA_IP:2283

  - service: http_status:404
EOF

sudo chown -R bacmaster:bacmaster "$CF_DIR"

echo
echo "🌍 DNS route kayıtları ekleniyor..."
echo

HOSTNAMES=(
  "pve.$DOMAIN"
  "truenas.$DOMAIN"
  "qbittorrent.$DOMAIN"
  "bacneyplus.$DOMAIN"
  "status.$DOMAIN"
  "cloud.$DOMAIN"
  "home.$DOMAIN"
  "ai.$DOMAIN"
  "bacsflix.$DOMAIN"
  "photos.$DOMAIN"
  "sonarr.$DOMAIN"
  "radarr.$DOMAIN"
  "bazarr.$DOMAIN"
  "prowlarr.$DOMAIN"
  "recyclarr.$DOMAIN"
  "adguard.$DOMAIN"
  "chia.$DOMAIN"
  "pve-api.$DOMAIN"
  "qbittorrent-api.$DOMAIN"
  "bacneyplus-api.$DOMAIN"
  "status-api.$DOMAIN"
  "cloud-api.$DOMAIN"
  "home-api.$DOMAIN"
  "bacsflix-api.$DOMAIN"
  "photos-api.$DOMAIN"
)

for HOST in "${HOSTNAMES[@]}"; do
  echo "➡️ $HOST"
  cloudflared tunnel route dns "$TUNNEL_NAME" "$HOST" || true
done

echo
echo "🐳 docker-compose cloudflared servisi güncelleniyor..."
echo

cd /home/bacmaster/docker/network

if [[ ! -f docker-compose.yml ]]; then
  echo "❌ docker-compose.yml bulunamadı: /home/bacmaster/docker/network"
  exit 1
fi

cp docker-compose.yml docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)

python3 - <<'PY'
from pathlib import Path

p = Path("/home/bacmaster/docker/network/docker-compose.yml")
text = p.read_text()

start = text.find("  cloudflared:")
if start == -1:
    text += """

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    command: tunnel --config /etc/cloudflared/config.yml run
    volumes:
      - ./cloudflared:/etc/cloudflared
    restart: unless-stopped
"""
else:
    lines = text.splitlines()
    out = []
    inside = False

    for line in lines:
        if line.startswith("  cloudflared:"):
            inside = True
            out.extend([
                "  cloudflared:",
                "    image: cloudflare/cloudflared:latest",
                "    container_name: cloudflared",
                "    command: tunnel --config /etc/cloudflared/config.yml run",
                "    volumes:",
                "      - ./cloudflared:/etc/cloudflared",
                "    restart: unless-stopped",
            ])
            continue

        if inside and line.startswith("  ") and not line.startswith("    ") and line.strip():
            inside = False

        if not inside:
            out.append(line)

    text = "\n".join(out) + "\n"

p.write_text(text)
PY

docker compose up -d cloudflared

echo
echo "✅ Cloudflared local managed tunnel hazır."
echo
echo "Kontrol:"
echo "docker logs -f cloudflared"
echo
echo "Config:"
echo "$CONFIG_FILE"
