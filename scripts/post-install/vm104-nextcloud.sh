#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/nextcloud"
DATA_MOUNT="/mnt/nextcloud"
TRUENAS_IP="192.168.50.101"
NFS_SHARE="/mnt/tank/nextcloud"
VM_IP="192.168.50.104"
DOMAIN="cloud.bacmastercloud.com"
API_DOMAIN="cloud-api.bacmastercloud.com"
TZ="Europe/Istanbul"

log() { echo; echo ">>> $1"; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Bu script root ile çalışmalı:"
    echo "sudo bash $0"
    exit 1
  fi
}

ask_secret() {
  local var_name="$1"
  local prompt="$2"
  local value=""
  while [[ -z "$value" ]]; do
    read -rsp "$prompt: " value
    echo
  done
  printf -v "$var_name" '%s' "$value"
}

ask_value() {
  local var_name="$1"
  local prompt="$2"
  local default="$3"
  local value=""
  read -rp "$prompt [$default]: " value
  value="${value:-$default}"
  printf -v "$var_name" '%s' "$value"
}

require_root

log "VM 104 Nextcloud otomatik kurulum başlıyor"

ask_value NEXTCLOUD_ADMIN_USER "Nextcloud admin kullanıcı adı" "bacmaster"
ask_secret NEXTCLOUD_ADMIN_PASS "Nextcloud admin şifresi"
ask_secret MYSQL_ROOT_PASSWORD "MariaDB root şifresi"
ask_secret MYSQL_PASSWORD "Nextcloud DB şifresi"

log "Sistem paketleri kuruluyor"
apt update
apt install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  nfs-common \
  ufw \
  jq

if ! command -v docker >/dev/null 2>&1; then
  log "Docker kuruluyor"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

systemctl enable --now docker
ok "Docker hazır"

log "TrueNAS NFS mount hazırlanıyor"
mkdir -p "$DATA_MOUNT"

if ! grep -q "$DATA_MOUNT" /etc/fstab; then
  echo "${TRUENAS_IP}:${NFS_SHARE} ${DATA_MOUNT} nfs defaults,_netdev,x-systemd.automount,nofail 0 0" >> /etc/fstab
fi

systemctl daemon-reload
mount "$DATA_MOUNT" || true

if mountpoint -q "$DATA_MOUNT"; then
  ok "NFS mount aktif: $DATA_MOUNT"
else
  warn "NFS mount aktif değil. TrueNAS tarafında ${NFS_SHARE} export hazır mı kontrol et."
fi

log "Klasörler hazırlanıyor"
mkdir -p "$APP_DIR"
mkdir -p "$DATA_MOUNT/data"
mkdir -p "$APP_DIR/db"
mkdir -p "$APP_DIR/redis"

cat > "$APP_DIR/.env" <<EOF
TZ=${TZ}
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER}
NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASS}
NEXTCLOUD_TRUSTED_DOMAINS=${DOMAIN} ${API_DOMAIN} ${VM_IP}
EOF

chmod 600 "$APP_DIR/.env"

log "Docker Compose dosyası yazılıyor"

cat > "$APP_DIR/docker-compose.yml" <<'EOF'
services:
  db:
    image: mariadb:11
    container_name: nextcloud-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
    env_file:
      - .env
    volumes:
      - ./db:/var/lib/mysql

  redis:
    image: redis:alpine
    container_name: nextcloud-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - ./redis:/data

  app:
    image: nextcloud:apache
    container_name: nextcloud-app
    restart: unless-stopped
    depends_on:
      - db
      - redis
    ports:
      - "8080:80"
    env_file:
      - .env
    environment:
      MYSQL_HOST: db
      REDIS_HOST: redis
      PHP_MEMORY_LIMIT: 2048M
      PHP_UPLOAD_LIMIT: 32G
      APACHE_DISABLE_REWRITE_IP: 1
      TRUSTED_PROXIES: 172.16.0.0/12 192.168.50.0/24
      OVERWRITEPROTOCOL: https
      OVERWRITEHOST: cloud.bacmastercloud.com
      OVERWRITECLIURL: https://cloud.bacmastercloud.com
    volumes:
      - ./html:/var/www/html
      - /mnt/nextcloud/data:/var/www/html/data

  cron:
    image: nextcloud:apache
    container_name: nextcloud-cron
    restart: unless-stopped
    depends_on:
      - app
    env_file:
      - .env
    entrypoint: /cron.sh
    volumes:
      - ./html:/var/www/html
      - /mnt/nextcloud/data:/var/www/html/data
EOF

log "Nextcloud containerları başlatılıyor"
cd "$APP_DIR"
docker compose up -d

log "Nextcloud ilk kurulumun tamamlanması bekleniyor"
sleep 30

log "Nextcloud ayarları uygulanıyor"

docker exec -u www-data nextcloud-app php occ config:system:set trusted_domains 0 --value="$DOMAIN" || true
docker exec -u www-data nextcloud-app php occ config:system:set trusted_domains 1 --value="$API_DOMAIN" || true
docker exec -u www-data nextcloud-app php occ config:system:set trusted_domains 2 --value="$VM_IP" || true

docker exec -u www-data nextcloud-app php occ config:system:set trusted_proxies 0 --value="172.16.0.0/12" || true
docker exec -u www-data nextcloud-app php occ config:system:set trusted_proxies 1 --value="192.168.50.0/24" || true

docker exec -u www-data nextcloud-app php occ config:system:set overwritehost --value="$DOMAIN" || true
docker exec -u www-data nextcloud-app php occ config:system:set overwriteprotocol --value="https" || true
docker exec -u www-data nextcloud-app php occ config:system:set overwrite.cli.url --value="https://${DOMAIN}" || true

docker exec -u www-data nextcloud-app php occ config:system:set default_phone_region --value="TR" || true

docker exec -u www-data nextcloud-app php occ config:system:set memcache.local --value='\OC\Memcache\APCu' || true
docker exec -u www-data nextcloud-app php occ config:system:set memcache.locking --value='\OC\Memcache\Redis' || true
docker exec -u www-data nextcloud-app php occ config:system:set redis host --value="redis" || true
docker exec -u www-data nextcloud-app php occ config:system:set redis port --type=integer --value=6379 || true

docker exec -u www-data nextcloud-app php occ background:cron || true
docker exec -u www-data nextcloud-app php occ maintenance:repair --include-expensive || true

log "Firewall ayarlanıyor"
ufw allow 22/tcp || true
ufw allow 8080/tcp || true
ufw --force enable || true

log "Durum kontrolü"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo
ok "VM 104 Nextcloud kurulumu tamamlandı"
echo
echo "Local erişim:"
echo "  http://${VM_IP}:8080"
echo
echo "Cloudflare erişim:"
echo "  https://${DOMAIN}"
echo
echo "Kurulum klasörü:"
echo "  ${APP_DIR}"
echo
echo "Data klasörü:"
echo "  ${DATA_MOUNT}/data"
