#!/usr/bin/env bash
set -euo pipefail

export TERM=xterm

SECRETS_DIR="/root/.secrets"
USERS_ENV="$SECRETS_DIR/users.env"
CF_ENV="$SECRETS_DIR/cloudflare.env"

[[ -f "$USERS_ENV" ]] || {
  echo "❌ users.env yok. Önce Part1 çalışmalı."
  exit 1
}

source "$USERS_ENV"

SSH_USER="$BACMASTER_USER"
SSH_PASS="$BACMASTER_PASS"

ARR_IP="192.168.50.102"
NET_IP="192.168.50.103"
NEXTCLOUD_IP="192.168.50.104"
HA_IP="192.168.50.105"
MEDIA_IP="192.168.50.106"

ask_visible_into() {
  local __var="$1"
  local prompt="$2"
  local input=""

  while true; do
    read -r -p "$prompt: " input
    [[ -n "$input" ]] && break
    echo "Boş bırakılamaz."
  done

  printf -v "$__var" "%s" "$input"
}

if [[ ! -f "$CF_ENV" ]]; then
  echo
  echo "Cloudflare Token alma yolu:"
  echo "Zero Trust → Networks → Tunnels → Create Tunnel"
  echo "Tunnel name: bacmaster"
  echo "Connector type: Docker"
  echo "Token'ı kopyala."
  echo
  echo "⚠️ Cloudflare token bu kurulum sırasında ekranda görünecek."
  ask_visible_into CF_TOKEN "Cloudflared token yapıştır"

  cat > "$CF_ENV" <<EOF
CLOUDFLARED_TOKEN="$CF_TOKEN"
EOF

  chmod 600 "$CF_ENV"
fi

source "$CF_ENV"

apt update
apt install -y sshpass curl

wait_ssh() {
  local IP="$1"

  echo "⏳ SSH bekleniyor: $IP"

  until sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    "$SSH_USER@$IP" "echo ok" >/dev/null 2>&1; do
    sleep 5
  done

  echo "✅ SSH hazır: $IP"
}

run_remote() {
  local IP="$1"

  {
    printf '%s\n' "$SSH_PASS"
    cat
  } | sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    "$SSH_USER@$IP" \
    "sudo -S -p '' bash -s"
}

echo "🔎 SSH erişimleri kontrol ediliyor..."

for IP in "$ARR_IP" "$NET_IP" "$NEXTCLOUD_IP" "$HA_IP" "$MEDIA_IP"; do
  wait_ssh "$IP"
done

prepare_vm() {
  local IP="$1"

  echo "🐳 Docker/NFS hazırlığı: $IP"

  run_remote "$IP" <<'EOS'
set -e

apt update
apt install -y curl wget nano htop git ca-certificates nfs-common

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

mkdir -p /mnt/media

grep -q "192.168.50.101:/mnt/tank/media" /etc/fstab || \
echo '192.168.50.101:/mnt/tank/media /mnt/media nfs defaults,_netdev,x-systemd.automount,noatime,nofail 0 0' >> /etc/fstab

mkdir -p /etc/systemd/system/docker.service.d

cat > /etc/systemd/system/docker.service.d/override.conf <<'EOF'
[Unit]
After=network-online.target remote-fs.target
Wants=network-online.target remote-fs.target
EOF

cat > /usr/local/sbin/homelab-recover-stack.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mount -a || true

for i in {1..20}; do
  if mountpoint -q /mnt/media || [[ ! -f /etc/homelab-needs-media ]]; then
    break
  fi
  sleep 3
  mount -a || true
done

if [[ -f /etc/homelab-stack-dirs ]]; then
  while read -r dir; do
    [[ -z "$dir" ]] && continue
    [[ -d "$dir" ]] || continue
    cd "$dir"
    docker compose up -d || true
  done < /etc/homelab-stack-dirs
fi
EOF

chmod +x /usr/local/sbin/homelab-recover-stack.sh

cat > /etc/systemd/system/homelab-recover-stack.service <<'EOF'
[Unit]
Description=HomeLab Docker stack recovery after NFS/network
After=network-online.target remote-fs.target docker.service
Wants=network-online.target remote-fs.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-recover-stack.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable docker || true
systemctl enable homelab-recover-stack.service || true

mount -a || true

mkdir -p /home/bacmaster/docker
chown -R bacmaster:bacmaster /home/bacmaster/docker

usermod -aG docker bacmaster || true
EOS
}

register_stack_remote() {
  local IP="$1"
  local DIR="$2"
  local NEEDS_MEDIA="${3:-yes}"

  run_remote "$IP" <<EOS
set -e
touch /etc/homelab-stack-dirs
grep -qxF "$DIR" /etc/homelab-stack-dirs || echo "$DIR" >> /etc/homelab-stack-dirs
if [[ "$NEEDS_MEDIA" == "yes" ]]; then
  touch /etc/homelab-needs-media
fi
systemctl daemon-reload
systemctl enable homelab-recover-stack.service || true
EOS
}

echo "🐳 Docker/NFS hazırlığı yapılıyor..."

for IP in "$ARR_IP" "$NET_IP" "$NEXTCLOUD_IP" "$HA_IP" "$MEDIA_IP"; do
  prepare_vm "$IP"
done

echo "🎬 VM102 docker-arr stack kuruluyor..."

run_remote "$ARR_IP" <<'EOS'
set -e

mkdir -p /home/bacmaster/docker/arr/{qbittorrent,prowlarr,sonarr,radarr,bazarr,jellyseerr,recyclarr}
mkdir -p /mnt/media/downloads /mnt/media/movies /mnt/media/series /mnt/media/music

cat > /home/bacmaster/docker/arr/docker-compose.yml <<'YAML'
services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Istanbul
      - WEBUI_PORT=8080
    volumes:
      - ./qbittorrent:/config
      - /mnt/media/downloads:/downloads
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Istanbul
    volumes:
      - ./prowlarr:/config
    ports:
      - "9696:9696"
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Istanbul
    volumes:
      - ./sonarr:/config
      - /mnt/media/series:/series
      - /mnt/media/downloads:/downloads
    ports:
      - "8989:8989"
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Istanbul
    volumes:
      - ./radarr:/config
      - /mnt/media/movies:/movies
      - /mnt/media/downloads:/downloads
    ports:
      - "7878:7878"
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Istanbul
    volumes:
      - ./bazarr:/config
      - /mnt/media/movies:/movies
      - /mnt/media/series:/series
    ports:
      - "6767:6767"
    restart: unless-stopped

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    environment:
      - TZ=Europe/Istanbul
    volumes:
      - ./jellyseerr:/app/config
    ports:
      - "5055:5055"
    restart: unless-stopped

  recyclarr:
    image: ghcr.io/recyclarr/recyclarr:latest
    container_name: recyclarr
    environment:
      - TZ=Europe/Istanbul
    volumes:
      - ./recyclarr:/config
    restart: unless-stopped
YAML

chown -R bacmaster:bacmaster /home/bacmaster/docker/arr
cd /home/bacmaster/docker/arr
docker compose up -d || true
EOS

register_stack_remote "$ARR_IP" "/home/bacmaster/docker/arr" "yes"

echo "🌐 VM103 docker-network stack kuruluyor..."

run_remote "$NET_IP" <<EOS
set -e

mkdir -p /home/bacmaster/docker/network/{adguard,uptime-kuma,flaresolverr,cloudflared}

cat > /home/bacmaster/docker/network/.env <<ENV
CLOUDFLARED_TOKEN=${CLOUDFLARED_TOKEN}
ENV

cat > /home/bacmaster/docker/network/docker-compose.yml <<'YAML'
services:
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguard
    volumes:
      - ./adguard/work:/opt/adguardhome/work
      - ./adguard/conf:/opt/adguardhome/conf
    ports:
      - "3000:3000"
      - "8081:80"
    restart: unless-stopped

  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    volumes:
      - ./uptime-kuma:/app/data
    ports:
      - "3001:3001"
    restart: unless-stopped

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - TZ=Europe/Istanbul
    ports:
      - "8191:8191"
    restart: unless-stopped

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    command: tunnel --no-autoupdate run --token \${CLOUDFLARED_TOKEN}
    restart: unless-stopped
YAML

chown -R bacmaster:bacmaster /home/bacmaster/docker/network
cd /home/bacmaster/docker/network
docker compose up -d || true
EOS

register_stack_remote "$NET_IP" "/home/bacmaster/docker/network" "no"

echo "☁️ VM104 nextcloud stack kuruluyor..."

run_remote "$NEXTCLOUD_IP" <<'EOS'
set -e

mkdir -p /home/bacmaster/docker/nextcloud/{nextcloud,db,redis}

cat > /home/bacmaster/docker/nextcloud/docker-compose.yml <<'YAML'
services:
  nextcloud-db:
    image: mariadb:11
    container_name: nextcloud-db
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
    environment:
      - MYSQL_ROOT_PASSWORD=passkey1
      - MYSQL_PASSWORD=passkey1
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - TZ=Europe/Istanbul
    volumes:
      - ./db:/var/lib/mysql
    restart: unless-stopped

  nextcloud-redis:
    image: redis:alpine
    container_name: nextcloud-redis
    restart: unless-stopped

  nextcloud:
    image: nextcloud:apache
    container_name: nextcloud
    depends_on:
      - nextcloud-db
      - nextcloud-redis
    environment:
      - MYSQL_HOST=nextcloud-db
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=passkey1
      - REDIS_HOST=nextcloud-redis
      - TZ=Europe/Istanbul
    volumes:
      - ./nextcloud:/var/www/html
    ports:
      - "8080:80"
    restart: unless-stopped
YAML

chown -R bacmaster:bacmaster /home/bacmaster/docker/nextcloud
cd /home/bacmaster/docker/nextcloud
docker compose up -d || true
EOS

register_stack_remote "$NEXTCLOUD_IP" "/home/bacmaster/docker/nextcloud" "no"

echo "🏠 VM105 Home Assistant stack kuruluyor..."

run_remote "$HA_IP" <<'EOS'
set -e

mkdir -p /home/bacmaster/docker/homeassistant/config

cat > /home/bacmaster/docker/homeassistant/docker-compose.yml <<'YAML'
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    privileged: true
    network_mode: host
    environment:
      - TZ=Europe/Istanbul
    volumes:
      - ./config:/config
      - /etc/localtime:/etc/localtime:ro
    restart: unless-stopped
YAML

chown -R bacmaster:bacmaster /home/bacmaster/docker/homeassistant
cd /home/bacmaster/docker/homeassistant
docker compose up -d || true
EOS

register_stack_remote "$HA_IP" "/home/bacmaster/docker/homeassistant" "no"

echo "🎞️ VM106 media stack kuruluyor..."

run_remote "$MEDIA_IP" <<'EOS'
set -e

mkdir -p /home/bacmaster/docker/media/{jellyfin,ollama,open-webui,immich}

cat > /home/bacmaster/docker/media/docker-compose.yml <<'YAML'
services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Istanbul
    volumes:
      - ./jellyfin:/config
      - /mnt/media:/media
    ports:
      - "8096:8096"
    restart: unless-stopped

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    volumes:
      - ./ollama:/root/.ollama
    ports:
      - "11434:11434"
    restart: unless-stopped

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    depends_on:
      - ollama
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - TZ=Europe/Istanbul
    volumes:
      - ./open-webui:/app/backend/data
    ports:
      - "3000:8080"
    restart: unless-stopped
YAML

cd /home/bacmaster/docker/media/immich

if [[ ! -f docker-compose.yml ]]; then
  curl -L https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml -o docker-compose.yml
  curl -L https://github.com/immich-app/immich/releases/latest/download/example.env -o .env
  sed -i 's|UPLOAD_LOCATION=.*|UPLOAD_LOCATION=./library|' .env || true
  sed -i 's|DB_PASSWORD=.*|DB_PASSWORD=passkey1|' .env || true
  sed -i 's|TZ=.*|TZ=Europe/Istanbul|' .env || true
fi

chown -R bacmaster:bacmaster /home/bacmaster/docker/media

cd /home/bacmaster/docker/media
docker compose up -d || true

cd /home/bacmaster/docker/media/immich
docker compose up -d || true
EOS

register_stack_remote "$MEDIA_IP" "/home/bacmaster/docker/media" "yes"
register_stack_remote "$MEDIA_IP" "/home/bacmaster/docker/media/immich" "yes"

healthcheck() {
  local name="$1"
  local url="$2"

  if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
    echo "✅ $name : $url"
  else
    echo "❌ $name : $url"
  fi
}

echo
echo "🔍 Healthcheck başlıyor..."
echo

healthcheck "qBittorrent"   "http://192.168.50.102:8080"
healthcheck "Prowlarr"      "http://192.168.50.102:9696"
healthcheck "Sonarr"        "http://192.168.50.102:8989"
healthcheck "Radarr"        "http://192.168.50.102:7878"
healthcheck "Bazarr"        "http://192.168.50.102:6767"
healthcheck "Jellyseerr"    "http://192.168.50.102:5055"
healthcheck "AdGuard"       "http://192.168.50.103:3000"
healthcheck "Uptime Kuma"   "http://192.168.50.103:3001"
healthcheck "Flaresolverr"  "http://192.168.50.103:8191"
healthcheck "Nextcloud"     "http://192.168.50.104:8080"
healthcheck "HomeAssistant" "http://192.168.50.105:8123"
healthcheck "Jellyfin"      "http://192.168.50.106:8096"
healthcheck "Ollama"        "http://192.168.50.106:11434"
healthcheck "Open WebUI"    "http://192.168.50.106:3000"
healthcheck "Immich"        "http://192.168.50.106:2283"

echo
echo "✅ PART3 Docker stack tamamlandı."
echo
