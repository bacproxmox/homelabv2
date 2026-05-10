#!/usr/bin/env bash
set -euo pipefail

log() { echo; echo ">>> $1"; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

get_xml_value() {
  local file="$1"
  local key="$2"
  grep -oP "<${key}>\K.*(?=</${key}>)" "$file" | head -n1 || true
}

set_xml_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  [[ -f "$file" ]] || {
    warn "Config yok: $file"
    return 0
  }

  cp "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)" || true

  if grep -q "<${key}>" "$file"; then
    sed -i "s|<${key}>.*</${key}>|<${key}>${value}</${key}>|g" "$file"
  else
    sed -i "s|</Config>|  <${key}>${value}</${key}>\\n</Config>|g" "$file"
  fi
}

wait_url() {
  local name="$1"
  local url="$2"

  log "$name bekleniyor: $url"

  for i in {1..60}; do
    if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
      ok "$name erişilebilir"
      return 0
    fi
    sleep 2
  done

  warn "$name erişilemedi: $url"
  return 1
}

echo "🔎 Container durumları:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true

wait_url "qBittorrent" "$QBIT_URL" || true
wait_url "Sonarr" "$SONARR_URL" || true
wait_url "Radarr" "$RADARR_URL" || true
wait_url "Prowlarr" "$PROWLARR_URL" || true
wait_url "Bazarr" "$BAZARR_URL" || true

log "ARR auth config hazırlanıyor..."

for app in sonarr radarr prowlarr; do
  cfg="$ARR_DIR/$app/config.xml"

  if [[ -f "$cfg" ]]; then
    set_xml_value "$cfg" "AuthenticationMethod" "Forms"
    set_xml_value "$cfg" "AuthenticationRequired" "Enabled"
    set_xml_value "$cfg" "Username" "$ARR_ADMIN_USER"
    set_xml_value "$cfg" "Password" "$ARR_ADMIN_PASS"
    ok "$app auth config güncellendi"
  else
    warn "$app config bulunamadı: $cfg"
  fi
done

docker restart sonarr radarr prowlarr >/dev/null 2>&1 || true
sleep 15

SONARR_KEY="$(get_xml_value "$SONARR_CFG" "ApiKey")"
RADARR_KEY="$(get_xml_value "$RADARR_CFG" "ApiKey")"
PROWLARR_KEY="$(get_xml_value "$PROWLARR_CFG" "ApiKey")"

export SONARR_KEY RADARR_KEY PROWLARR_KEY

echo
echo "🔑 API key kontrolü:"
[[ -n "$SONARR_KEY" ]] && ok "Sonarr API key bulundu" || warn "Sonarr API key yok"
[[ -n "$RADARR_KEY" ]] && ok "Radarr API key bulundu" || warn "Radarr API key yok"
[[ -n "$PROWLARR_KEY" ]] && ok "Prowlarr API key bulundu" || warn "Prowlarr API key yok"

log "qBittorrent ayarlanıyor..."

QBIT_CONF="/home/bacmaster/docker/arr/qbittorrent/qBittorrent/qBittorrent.conf"

echo "🛑 qBittorrent durduruluyor..."
docker stop qbittorrent >/dev/null 2>&1 || true

echo "🛠 qBittorrent config yazılıyor..."

python3 - <<'PY'
from pathlib import Path

conf = Path("/home/bacmaster/docker/arr/qbittorrent/qBittorrent/qBittorrent.conf")
conf.parent.mkdir(parents=True, exist_ok=True)

text = conf.read_text() if conf.exists() else ""

if "[Preferences]" not in text:
    text += "\n[Preferences]\n"

settings = {
    r"WebUI\HostHeaderValidation": "false",
    r"WebUI\CSRFProtection": "false",
    r"WebUI\LocalHostAuth": "false",
    r"WebUI\AuthSubnetWhitelistEnabled": "true",
    r"WebUI\AuthSubnetWhitelist": "127.0.0.1, 192.168.50.0/24",
    r"WebUI\Username": "admin",
}

lines = text.splitlines()
out = []
seen = set()

for line in lines:
    replaced = False
    for k, v in settings.items():
        if line.startswith(k + "="):
            out.append(f"{k}={v}")
            seen.add(k)
            replaced = True
            break
    if not replaced:
        out.append(line)

for k, v in settings.items():
    if k not in seen:
        out.append(f"{k}={v}")

conf.write_text("\n".join(out) + "\n")
PY

chown -R 1000:1000 "$ARR_DIR/qbittorrent" || true

echo "▶️ qBittorrent başlatılıyor..."
docker start qbittorrent >/dev/null 2>&1 || true
sleep 20

if curl -fsS --max-time 5 "$QBIT_URL/api/v2/app/version" >/dev/null 2>&1; then
  ok "qBittorrent API erişilebilir: $QBIT_URL"
else
  warn "qBittorrent API hâlâ erişimsiz olabilir: $QBIT_URL"
fi

QBIT_PREFS="$(cat <<EOF
{
  "web_ui_username": "$QBIT_USER",
  "web_ui_password": "$QBIT_PASS",
  "save_path": "/downloads/",
  "temp_path_enabled": false,
  "create_subfolder_enabled": true
}
EOF
)"

curl -fsS \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "json=$QBIT_PREFS" \
  "$QBIT_URL/api/v2/app/setPreferences" >/dev/null || warn "qBittorrent preferences basılamadı"

curl -fsS \
  --data-urlencode "category=sonarr" \
  --data-urlencode "savePath=/downloads/sonarr" \
  "$QBIT_URL/api/v2/torrents/createCategory" >/dev/null || true

curl -fsS \
  --data-urlencode "category=radarr" \
  --data-urlencode "savePath=/downloads/radarr" \
  "$QBIT_URL/api/v2/torrents/createCategory" >/dev/null || true

docker restart qbittorrent >/dev/null 2>&1 || true
sleep 12

ok "qBittorrent config/preference işlemi tamamlandı"

log "Root folder ayarları uygulanıyor..."

add_root_folder() {
  local app="$1"
  local url="$2"
  local key="$3"
  local path="$4"

  [[ -n "$key" ]] || {
    warn "$app API key yok, root folder atlandı"
    return 0
  }

  EXISTING="$(curl -fsS -H "X-Api-Key: $key" "$url/api/v3/rootfolder" || true)"

  if echo "$EXISTING" | grep -q "\"path\":\"$path\""; then
    ok "$app root folder zaten var: $path"
    return 0
  fi

  RESP="$(curl -sS \
    -H "X-Api-Key: $key" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"path\":\"$path\"}" \
    "$url/api/v3/rootfolder" || true)"

  if echo "$RESP" | grep -qi "error\|exception\|validation"; then
    warn "$app root folder ekleme cevabı: $RESP"
  else
    ok "$app root folder eklendi: $path"
  fi
}

add_root_folder "Sonarr" "$SONARR_URL" "$SONARR_KEY" "/series"
add_root_folder "Radarr" "$RADARR_URL" "$RADARR_KEY" "/movies"

if [[ -n "${SONARR_KEY:-}" ]]; then
  curl -fsS \
    -H "X-Api-Key: $SONARR_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"path":"/series"}' \
    "$SONARR_URL/api/v3/rootfolder" >/dev/null 2>&1 || true

  ok "Sonarr root folder denendi: /series"
fi

if [[ -n "${RADARR_KEY:-}" ]]; then
  curl -fsS \
    -H "X-Api-Key: $RADARR_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"path":"/movies"}' \
    "$RADARR_URL/api/v3/rootfolder" >/dev/null 2>&1 || true

  ok "Radarr root folder denendi: /movies"
fi

log "Sonarr/Radarr → qBittorrent bağlantısı kuruluyor..."

add_qbit_to_sonarr() {
  [[ -n "${SONARR_KEY:-}" ]] || return 0

  EXISTING="$(curl -fsS -H "X-Api-Key: $SONARR_KEY" "$SONARR_URL/api/v3/downloadclient" || true)"

  if echo "$EXISTING" | grep -q '"name": "qBittorrent"'; then
    ok "Sonarr qBittorrent zaten var"
    return 0
  fi

  PAYLOAD="$(cat <<EOF
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
    { "name": "username", "value": "$QBIT_USER" },
    { "name": "password", "value": "$QBIT_PASS" },
    { "name": "category", "value": "sonarr" },
    { "name": "recentTvPriority", "value": 0 },
    { "name": "olderTvPriority", "value": 0 },
    { "name": "initialState", "value": 0 }
  ]
}
EOF
)"

  RESP="$(curl -sS \
    -H "X-Api-Key: $SONARR_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$PAYLOAD" \
    "$SONARR_URL/api/v3/downloadclient" || true)"

  if echo "$RESP" | grep -qi "error\|invalid\|exception"; then
    warn "Sonarr qBittorrent ekleme cevabı: $RESP"
  else
    ok "Sonarr qBittorrent bağlantısı denendi"
  fi
}

add_qbit_to_radarr() {
  [[ -n "${RADARR_KEY:-}" ]] || return 0

  EXISTING="$(curl -fsS -H "X-Api-Key: $RADARR_KEY" "$RADARR_URL/api/v3/downloadclient" || true)"

  if echo "$EXISTING" | grep -q '"name": "qBittorrent"'; then
    ok "Radarr qBittorrent zaten var"
    return 0
  fi

  PAYLOAD="$(cat <<EOF
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
    { "name": "username", "value": "$QBIT_USER" },
    { "name": "password", "value": "$QBIT_PASS" },
    { "name": "category", "value": "radarr" },
    { "name": "recentMoviePriority", "value": 0 },
    { "name": "olderMoviePriority", "value": 0 },
    { "name": "initialState", "value": 0 }
  ]
}
EOF
)"

  RESP="$(curl -sS \
    -H "X-Api-Key: $RADARR_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$PAYLOAD" \
    "$RADARR_URL/api/v3/downloadclient" || true)"

  if echo "$RESP" | grep -qi "error\|invalid\|exception"; then
    warn "Radarr qBittorrent ekleme cevabı: $RESP"
  else
    ok "Radarr qBittorrent bağlantısı denendi"
  fi
}

add_qbit_to_sonarr
add_qbit_to_radarr

cat > /tmp/homelab-arr-keys.env <<EOF
SONARR_KEY="$SONARR_KEY"
RADARR_KEY="$RADARR_KEY"
PROWLARR_KEY="$PROWLARR_KEY"
EOF

ok "ARR core tamam"
