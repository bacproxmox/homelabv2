#!/usr/bin/env bash
set -euo pipefail

export TERM=xterm

SECRETS_DIR="/root/.secrets"
USERS_ENV="$SECRETS_DIR/users.env"
POST_ENV="$SECRETS_DIR/postinstall.env"

[[ -f "$USERS_ENV" ]] || {
  echo "❌ users.env yok. Önce Part1 çalışmalı."
  exit 1
}

source "$USERS_ENV"

SSH_USER="$BACMASTER_USER"
SSH_PASS="$BACMASTER_PASS"

ARR_IP="192.168.50.102"

ask_visible_into() {
  local __var="$1"
  local prompt="$2"
  local default="${3:-}"
  local input=""

  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " input
    input="${input:-$default}"
  else
    while true; do
      read -r -p "$prompt: " input
      [[ -n "$input" ]] && break
      echo "Boş bırakılamaz."
    done
  fi

  printf -v "$__var" "%s" "$input"
}

if [[ ! -f "$POST_ENV" ]]; then
  echo
  echo "🔐 Post-install servis bilgileri alınacak."
  echo "⚠️ Şifreler bu kurulum sırasında ekranda görünecek."
  echo

  ask_visible_into QBIT_USER "qBittorrent user" "admin"
  ask_visible_into QBIT_PASS "qBittorrent password"

  ask_visible_into ARR_ADMIN_USER "Sonarr/Radarr/Prowlarr admin user" "admin"
  ask_visible_into ARR_ADMIN_PASS "Sonarr/Radarr/Prowlarr admin password"

  cat > "$POST_ENV" <<EOF
QBIT_USER="$QBIT_USER"
QBIT_PASS="$QBIT_PASS"
ARR_ADMIN_USER="$ARR_ADMIN_USER"
ARR_ADMIN_PASS="$ARR_ADMIN_PASS"
EOF

  chmod 600 "$POST_ENV"
fi

source "$POST_ENV"

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

wait_ssh "$ARR_IP"

echo "🎬 VM102 ARR servis içi ayarlar başlıyor..."

run_remote "$ARR_IP" <<EOS
set -euo pipefail

QBIT_USER="$QBIT_USER"
QBIT_PASS="$QBIT_PASS"
ARR_ADMIN_USER="$ARR_ADMIN_USER"
ARR_ADMIN_PASS="$ARR_ADMIN_PASS"

ARR_DIR="/home/bacmaster/docker/arr"

QBIT_URL="http://127.0.0.1:8080"
SONARR_URL="http://127.0.0.1:8989"
RADARR_URL="http://127.0.0.1:7878"
PROWLARR_URL="http://127.0.0.1:9696"
BAZARR_URL="http://127.0.0.1:6767"

SONARR_CFG="\$ARR_DIR/sonarr/config.xml"
RADARR_CFG="\$ARR_DIR/radarr/config.xml"
PROWLARR_CFG="\$ARR_DIR/prowlarr/config.xml"

log() { echo; echo ">>> \$1"; }
ok() { echo "✅ \$1"; }
warn() { echo "⚠️ \$1"; }

wait_url() {
  local name="\$1"
  local url="\$2"

  log "\$name bekleniyor: \$url"

  for i in {1..60}; do
    if curl -fsS --max-time 5 "\$url" >/dev/null 2>&1; then
      ok "\$name erişilebilir"
      return 0
    fi
    sleep 2
  done

  warn "\$name erişilemedi: \$url"
  return 1
}

get_xml_value() {
  local file="\$1"
  local key="\$2"

  grep -oP "<\${key}>\\K.*(?=</\${key}>)" "\$file" | head -n1 || true
}

set_xml_value() {
  local file="\$1"
  local key="\$2"
  local value="\$3"

  if [[ ! -f "\$file" ]]; then
    warn "Config yok: \$file"
    return 0
  fi

  cp "\$file" "\$file.bak.\$(date +%Y%m%d-%H%M%S)" || true

  if grep -q "<\${key}>" "\$file"; then
    sed -i "s|<\${key}>.*</\${key}>|<\${key}>\${value}</\${key}>|g" "\$file"
  else
    sed -i "s|</Config>|  <\${key}>\${value}</\${key}>\\n</Config>|g" "\$file"
  fi
}

echo "🔎 Container durumları:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true

wait_url "qBittorrent" "\$QBIT_URL" || true
wait_url "Sonarr" "\$SONARR_URL" || true
wait_url "Radarr" "\$RADARR_URL" || true
wait_url "Prowlarr" "\$PROWLARR_URL" || true
wait_url "Bazarr" "\$BAZARR_URL" || true

echo
echo "🔐 ARR auth config hazırlanıyor..."

for app in sonarr radarr prowlarr; do
  cfg="\$ARR_DIR/\$app/config.xml"

  if [[ -f "\$cfg" ]]; then
    set_xml_value "\$cfg" "AuthenticationMethod" "Forms"
    set_xml_value "\$cfg" "AuthenticationRequired" "Enabled"
    set_xml_value "\$cfg" "Username" "\$ARR_ADMIN_USER"
    set_xml_value "\$cfg" "Password" "\$ARR_ADMIN_PASS"
    ok "\$app auth config güncellendi"
  else
    warn "\$app config bulunamadı: \$cfg"
  fi
done

docker restart sonarr radarr prowlarr >/dev/null 2>&1 || true
sleep 15

SONARR_KEY="\$(get_xml_value "\$SONARR_CFG" "ApiKey")"
RADARR_KEY="\$(get_xml_value "\$RADARR_CFG" "ApiKey")"
PROWLARR_KEY="\$(get_xml_value "\$PROWLARR_CFG" "ApiKey")"

echo
echo "🔑 API key kontrolü:"
[[ -n "\$SONARR_KEY" ]] && ok "Sonarr API key bulundu" || warn "Sonarr API key yok"
[[ -n "\$RADARR_KEY" ]] && ok "Radarr API key bulundu" || warn "Radarr API key yok"
[[ -n "\$PROWLARR_KEY" ]] && ok "Prowlarr API key bulundu" || warn "Prowlarr API key yok"

echo
echo "⬇️ qBittorrent ayarlanıyor..."

COOKIE_FILE="\$(mktemp)"

LOGIN_RESPONSE="\$(curl -fsS -c "\$COOKIE_FILE" \
  --data "username=\$QBIT_USER&password=\$QBIT_PASS" \
  "\$QBIT_URL/api/v2/auth/login" || true)"

if [[ "\$LOGIN_RESPONSE" != "Ok." ]]; then
  warn "qBittorrent login başarısız."
  warn "Geçici şifre için:"
  echo "docker logs qbittorrent | grep -i password"
else
  curl -fsS -b "\$COOKIE_FILE" \
    --data-urlencode "category=sonarr" \
    --data-urlencode "savePath=/downloads/sonarr" \
    "\$QBIT_URL/api/v2/torrents/createCategory" >/dev/null || true

  curl -fsS -b "\$COOKIE_FILE" \
    --data-urlencode "category=radarr" \
    --data-urlencode "savePath=/downloads/radarr" \
    "\$QBIT_URL/api/v2/torrents/createCategory" >/dev/null || true

  PREFS='{"save_path":"/downloads/","temp_path_enabled":false,"create_subfolder_enabled":true}'

  curl -fsS -b "\$COOKIE_FILE" \
    --data-urlencode "json=\$PREFS" \
    "\$QBIT_URL/api/v2/app/setPreferences" >/dev/null || true

  ok "qBittorrent kategori/path ayarları tamam"
fi

rm -f "\$COOKIE_FILE"

echo
echo "📁 Root folder ayarları deneniyor..."

if [[ -n "\$SONARR_KEY" ]]; then
  curl -fsS \
    -H "X-Api-Key: \$SONARR_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"path":"/series"}' \
    "\$SONARR_URL/api/v3/rootfolder" >/dev/null 2>&1 || true

  ok "Sonarr root folder denendi: /series"
fi

if [[ -n "\$RADARR_KEY" ]]; then
  curl -fsS \
    -H "X-Api-Key: \$RADARR_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"path":"/movies"}' \
    "\$RADARR_URL/api/v3/rootfolder" >/dev/null 2>&1 || true

  ok "Radarr root folder denendi: /movies"
fi

echo
echo "🔗 Sonarr/Radarr → qBittorrent bağlantısı kuruluyor..."

if [[ -n "\$SONARR_KEY" ]]; then
  EXISTING="\$(curl -fsS -H "X-Api-Key: \$SONARR_KEY" "\$SONARR_URL/api/v3/downloadclient" || true)"

  if echo "\$EXISTING" | grep -q '"name": "qBittorrent"'; then
    ok "Sonarr qBittorrent zaten var"
  else
    SONARR_PAYLOAD="\$(cat <<EOF
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "qBittorrent",
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    { "name": "host", "value": "192.168.50.102" },
    { "name": "port", "value": 8080 },
    { "name": "useSsl", "value": false },
    { "name": "urlBase", "value": "" },
    { "name": "username", "value": "\$QBIT_USER" },
    { "name": "password", "value": "\$QBIT_PASS" },
    { "name": "category", "value": "sonarr" },
    { "name": "recentTvPriority", "value": 0 },
    { "name": "olderTvPriority", "value": 0 },
    { "name": "initialState", "value": 0 }
  ]
}
EOF
)"

    curl -fsS \
      -H "X-Api-Key: \$SONARR_KEY" \
      -H "Content-Type: application/json" \
      -X POST \
      -d "\$SONARR_PAYLOAD" \
      "\$SONARR_URL/api/v3/downloadclient" >/dev/null || warn "Sonarr qBittorrent ekleme başarısız"

    ok "Sonarr qBittorrent bağlantısı denendi"
  fi
fi

if [[ -n "\$RADARR_KEY" ]]; then
  EXISTING="\$(curl -fsS -H "X-Api-Key: \$RADARR_KEY" "\$RADARR_URL/api/v3/downloadclient" || true)"

  if echo "\$EXISTING" | grep -q '"name": "qBittorrent"'; then
    ok "Radarr qBittorrent zaten var"
  else
    RADARR_PAYLOAD="\$(cat <<EOF
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "qBittorrent",
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    { "name": "host", "value": "192.168.50.102" },
    { "name": "port", "value": 8080 },
    { "name": "useSsl", "value": false },
    { "name": "urlBase", "value": "" },
    { "name": "username", "value": "\$QBIT_USER" },
    { "name": "password", "value": "\$QBIT_PASS" },
    { "name": "category", "value": "radarr" },
    { "name": "recentMoviePriority", "value": 0 },
    { "name": "olderMoviePriority", "value": 0 },
    { "name": "initialState", "value": 0 }
  ]
}
EOF
)"

    curl -fsS \
      -H "X-Api-Key: \$RADARR_KEY" \
      -H "Content-Type: application/json" \
      -X POST \
      -d "\$RADARR_PAYLOAD" \
      "\$RADARR_URL/api/v3/downloadclient" >/dev/null || warn "Radarr qBittorrent ekleme başarısız"

    ok "Radarr qBittorrent bağlantısı denendi"
  fi
fi

echo
echo "🧲 Prowlarr → Sonarr/Radarr app sync ayarlanıyor..."

if [[ -n "\$PROWLARR_KEY" && -n "\$SONARR_KEY" ]]; then
  EXISTING="\$(curl -fsS -H "X-Api-Key: \$PROWLARR_KEY" "\$PROWLARR_URL/api/v1/applications" || true)"

  if echo "\$EXISTING" | grep -q '"name": "Sonarr"'; then
    ok "Prowlarr Sonarr app zaten var"
  else
    SONARR_APP="\$(cat <<EOF
{
  "name": "Sonarr",
  "syncLevel": "fullSync",
  "implementation": "Sonarr",
  "configContract": "SonarrSettings",
  "fields": [
    { "name": "prowlarrUrl", "value": "http://192.168.50.102:9696" },
    { "name": "baseUrl", "value": "http://192.168.50.102:8989" },
    { "name": "apiKey", "value": "\$SONARR_KEY" },
    { "name": "syncCategories", "value": [5000, 5030, 5040] },
    { "name": "animeSyncCategories", "value": [5070] }
  ]
}
EOF
)"

    curl -fsS \
      -H "X-Api-Key: \$PROWLARR_KEY" \
      -H "Content-Type: application/json" \
      -X POST \
      -d "\$SONARR_APP" \
      "\$PROWLARR_URL/api/v1/applications" >/dev/null || warn "Prowlarr Sonarr app ekleme başarısız"

    ok "Prowlarr Sonarr app sync denendi"
  fi
fi

if [[ -n "\$PROWLARR_KEY" && -n "\$RADARR_KEY" ]]; then
  EXISTING="\$(curl -fsS -H "X-Api-Key: \$PROWLARR_KEY" "\$PROWLARR_URL/api/v1/applications" || true)"

  if echo "\$EXISTING" | grep -q '"name": "Radarr"'; then
    ok "Prowlarr Radarr app zaten var"
  else
    RADARR_APP="\$(cat <<EOF
{
  "name": "Radarr",
  "syncLevel": "fullSync",
  "implementation": "Radarr",
  "configContract": "RadarrSettings",
  "fields": [
    { "name": "prowlarrUrl", "value": "http://192.168.50.102:9696" },
    { "name": "baseUrl", "value": "http://192.168.50.102:7878" },
    { "name": "apiKey", "value": "\$RADARR_KEY" },
    { "name": "syncCategories", "value": [2000] }
  ]
}
EOF
)"

    curl -fsS \
      -H "X-Api-Key: \$PROWLARR_KEY" \
      -H "Content-Type: application/json" \
      -X POST \
      -d "\$RADARR_APP" \
      "\$PROWLARR_URL/api/v1/applications" >/dev/null || warn "Prowlarr Radarr app ekleme başarısız"

    ok "Prowlarr Radarr app sync denendi"
  fi
fi

echo
echo "✅ VM102 ARR post-install ayarları tamamlandı."
EOS

echo
echo "✅ PART4 post-install config tamamlandı."
echo
echo "Kontrol:"
echo "qBittorrent : http://192.168.50.102:8080"
echo "Prowlarr    : http://192.168.50.102:9696"
echo "Sonarr      : http://192.168.50.102:8989"
echo "Radarr      : http://192.168.50.102:7878"
echo "Bazarr      : http://192.168.50.102:6767"
echo
