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

TRUENAS_MEDIA_NFS="192.168.50.101:/mnt/tank/media"
TRUENAS_PHOTOS_NFS="192.168.50.101:/mnt/private/photos"

MEDIA_MOUNT="/mnt/media"
PHOTOS_MOUNT="/mnt/photos"

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
  echo "Cloudflare Tunnel token gerekli."
  echo "Zero Trust → Networks → Tunnels → Create Tunnel"
  echo "Tunnel name: bacmaster"
  echo "Connector type: Docker"
  echo "Token'ı kopyala."
  echo
  echo "⚠️ Cloudflare token bu kurulum sırasında ekranda görünecek."
  ask_visible_into CF_TOKEN "Cloudflare token"

  cat > "$CF_ENV" <<EOF
CLOUDFLARED_TOKEN="$CF_TOKEN"
EOF

  chmod 600 "$CF_ENV"
fi

source "$CF_ENV"

apt update
apt install -y sshpass curl jq

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o ConnectTimeout=5
)

wait_ssh() {
  local IP="$1"

  echo "⏳ SSH bekleniyor: $IP"

  until sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "$SSH_USER@$IP" "echo ok" >/dev/null 2>&1; do
    sleep 5
  done

  echo "✅ SSH hazır: $IP"
}

run_remote() {
  local IP="$1"

  {
    printf '%s\n' "$SSH_PASS"
    cat
  } | sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "$SSH_USER@$IP" "sudo -S -p '' bash -s"
}

healthcheck() {
  local name="$1"
  local url="$2"

  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" || true)"

  if [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]; then
    echo "✅ $name : $url HTTP:$code"
  else
    echo "❌ $name : $url HTTP:$code"
  fi
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local retries="${3:-60}"
  local sleep_time="${4:-5}"

  echo "⏳ $name bekleniyor..."

  for i in $(seq 1 "$retries"); do
    local code
    code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" || true)"

    if [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]; then
      echo "✅ $name hazır HTTP:$code"
      return 0
    fi

    sleep "$sleep_time"
  done

  echo "❌ $name hazır olmadı"
  return 1
}

echo "🔎 SSH erişimleri kontrol ediliyor..."

for IP in "$ARR_IP" "$NET_IP" "$NEXTCLOUD_IP" "$HA_IP" "$MEDIA_IP"; do
  wait_ssh "$IP"
done

prepare_vm() {
  local IP="$1"
  local NEED_MEDIA="${2:-no}"
  local NEED_PHOTOS="${3:-no}"
  local STACK_DIR="${4:-}"

  echo "🐳 VM hazırlanıyor: $IP"

  run_remote "$IP" <<EOS
set -e

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y curl wget nano htop git ca-certificates nfs-common jq

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

mkdir -p /etc/systemd/system/docker.service.d

cat > /etc/systemd/system/docker.service.d/override.conf <<'UNIT'
[Unit]
After=network-online.target remote-fs.target
Wants=network-online.target remote-fs.target
UNIT

systemctl daemon-reload
systemctl enable docker

mkdir -p "$MEDIA_MOUNT"
mkdir -p "$PHOTOS_MOUNT"

if [[ "$NEED_MEDIA" == "yes" ]]; then
  grep -q "$TRUENAS_MEDIA_NFS" /etc/fstab || echo '$TRUENAS_MEDIA_NFS $MEDIA_MOUNT nfs defaults,_netdev,x-systemd.automount,x-systemd.requires=network-online.target,noatime,nofail 0 0' >> /etc/fstab
fi

if [[ "$NEED_PHOTOS" == "yes" ]]; then
  grep -q "$TRUENAS_PHOTOS_NFS" /etc/fstab || echo '$TRUENAS_PHOTOS_NFS $PHOTOS_MOUNT nfs defaults,_netdev,x-systemd.automount,x-systemd.requires=network-online.target,noatime,nofail 0 0' >> /etc/fstab
fi

systemctl daemon-reload
mount -a || true

mkdir -p /home/$SSH_USER/docker
chown -R $SSH_USER:$SSH_USER /home/$SSH_USER/docker

usermod -aG docker $SSH_USER || true

cat > /usr/local/sbin/homelab-recover-stack.sh <<'RECOVER'
#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="\${1:-}"
NEED_MEDIA="\${2:-no}"
NEED_PHOTOS="\${3:-no}"

if [[ "\$NEED_MEDIA" == "yes" ]]; then
  for i in {1..30}; do
    mountpoint -q /mnt/media && break
    mount -a || true
    sleep 5
  done
fi

if [[ "\$NEED_PHOTOS" == "yes" ]]; then
  for i in {1..30}; do
    mountpoint -q /mnt/photos && break
    mount -a || true
    sleep 5
  done
fi

if [[ -n "\$STACK_DIR" && -f "\$STACK_DIR/docker-compose.yml" ]]; then
  cd "\$STACK_DIR"
  docker compose up -d || true
fi
RECOVER

chmod +x /usr/local/sbin/homelab-recover-stack.sh

cat > /etc/systemd/system/homelab-recover-stack.service <<SERVICE
[Unit]
Description=HomeLab Docker recovery
After=network-online.target remote-fs.target docker.service
Wants=network-online.target remote-fs.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-recover-stack.sh "$STACK_DIR" "$NEED_MEDIA" "$NEED_PHOTOS"

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable homelab-recover-stack.service
EOS
}

prepare_vm "$ARR_IP" yes no "/home/$SSH_USER/docker/arr"
prepare_vm "$NET_IP" no no "/home/$SSH_USER/docker/network"
prepare_vm "$NEXTCLOUD_IP" no no "/home/$SSH_USER/docker/nextcloud"
prepare_vm "$HA_IP" no no "/home/$SSH_USER/docker/homeassistant"
prepare_vm "$MEDIA_IP" yes yes "/home/$SSH_USER/docker/media"

echo "🎬 VM102 docker-arr stack kuruluyor..."

run_remote "$ARR_IP" <<'EOS'
set -e

USER_HOME="/home/bacmaster"

mkdir -p "$USER_HOME/docker/arr"/{qbittorrent,prowlarr,sonarr,radarr,bazarr,jellyseerr,recyclarr}

mkdir -p /mnt/media/downloads
mkdir -p /mnt/media/downloads/torrents
mkdir -p /mnt/media/downloads/usenet
mkdir -p /mnt/media/downloads/sonarr
mkdir -p /mnt/media/downloads/radarr
mkdir -p /mnt/media/movies
mkdir -p /mnt/media/series
mkdir -p /mnt/media/music

cat > "$USER_HOME/docker/arr/docker-compose.yml" <<'YAML'
services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Istanbul
      - WEBUI_PORT=8080
      - TORRENTING_PORT=6881
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

chown -R bacmaster:bacmaster "$USER_HOME/docker/arr"

mount -a || true

cd "$USER_HOME/docker/arr"
docker compose up -d
EOS

echo "🌐 VM103 docker-network stack kuruluyor..."

run_remote "$NET_IP" <<EOS
set -e

USER_HOME="/home/bacmaster"

mkdir -p "\$USER_HOME/docker/network"/{adguard,uptime-kuma,flaresolverr,cloudflared}

cat > "\$USER_HOME/docker/network/.env" <<ENV
CLOUDFLARED_TOKEN=${CLOUDFLARED_TOKEN}
ENV

cat > "\$USER_HOME/docker/network/docker-compose.yml" <<'YAML'
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
    command: tunnel --no-autoupdate run --token ${CLOUDFLARED_TOKEN}
    restart: unless-stopped
YAML

chown -R bacmaster:bacmaster "\$USER_HOME/docker/network"

cd "\$USER_HOME/docker/network"
docker compose up -d
EOS

echo "☁️ VM104 nextcloud stack kuruluyor..."

run_remote "$NEXTCLOUD_IP" <<'EOS'
set -e

USER_HOME="/home/bacmaster"

mkdir -p "$USER_HOME/docker/nextcloud"/{nextcloud,db,redis}

cat > "$USER_HOME/docker/nextcloud/docker-compose.yml" <<'YAML'
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

chown -R bacmaster:bacmaster "$USER_HOME/docker/nextcloud"

cd "$USER_HOME/docker/nextcloud"
docker compose up -d
EOS

echo "🏠 VM105 Home Assistant stack kuruluyor..."

run_remote "$HA_IP" <<'EOS'
set -e

USER_HOME="/home/bacmaster"

mkdir -p "$USER_HOME/docker/homeassistant/config"

cat > "$USER_HOME/docker/homeassistant/docker-compose.yml" <<'YAML'
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

chown -R bacmaster:bacmaster "$USER_HOME/docker/homeassistant"

cd "$USER_HOME/docker/homeassistant"
docker compose up -d
EOS

echo "🎞️ VM106 media stack kuruluyor..."

run_remote "$MEDIA_IP" <<'EOS'
set -e

USER_HOME="/home/bacmaster"

mkdir -p "$USER_HOME/docker/media"/{jellyfin,ollama,open-webui,immich}

mkdir -p /mnt/photos
mount -a || true

cat > "$USER_HOME/docker/media/docker-compose.yml" <<'YAML'
services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Istanbul
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "video"
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

cd "$USER_HOME/docker/media/immich"

if [[ ! -f docker-compose.yml ]]; then
  curl -L https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml -o docker-compose.yml
  curl -L https://github.com/immich-app/immich/releases/latest/download/example.env -o .env
fi

grep -q '^UPLOAD_LOCATION=' .env \
  && sed -i 's|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=/mnt/photos|' .env \
  || echo 'UPLOAD_LOCATION=/mnt/photos' >> .env

grep -q '^DB_PASSWORD=' .env \
  && sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD=passkey1|' .env \
  || echo 'DB_PASSWORD=passkey1' >> .env

grep -q '^TZ=' .env \
  && sed -i 's|^TZ=.*|TZ=Europe/Istanbul|' .env \
  || echo 'TZ=Europe/Istanbul' >> .env

chown -R bacmaster:bacmaster "$USER_HOME/docker/media"

mount -a || true

cd "$USER_HOME/docker/media"
docker compose up -d || true

cd "$USER_HOME/docker/media/immich"
docker compose up -d || true
EOS

echo
echo "⏳ Servislerin oturması için bekleniyor..."
sleep 15

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

echo
echo "🖼 Immich özel healthcheck başlıyor..."

wait_for_url "Immich" "http://192.168.50.106:2283" 120 5 || {
  echo
  echo "⚠️ Immich hâlâ hazır görünmüyor."
  echo "VM106 içinde:"
  echo "cd ~/docker/media/immich"
  echo "docker compose logs --tail=100 immich-server"
}

echo
echo "📦 Mount kontrolü..."

run_remote "$MEDIA_IP" <<'EOS'
echo
echo "=== /mnt/media ==="
df -h /mnt/media || true

echo
echo "=== /mnt/photos ==="
df -h /mnt/photos || true

echo
echo "=== test write ==="
touch /mnt/photos/test-write
rm -f /mnt/photos/test-write

echo "✅ photos write test başarılı"
EOS

echo
echo "✅ PART3 Docker stack tamamlandı."
