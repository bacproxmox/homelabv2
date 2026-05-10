#!/usr/bin/env bash
set -euo pipefail

log() { echo; echo ">>> $1"; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

[[ -f /tmp/homelab-arr-keys.env ]] && source /tmp/homelab-arr-keys.env

RECYCLARR_DIR="$ARR_DIR/recyclarr"
RECYCLARR_CONFIG="$RECYCLARR_DIR/recyclarr.yml"

mkdir -p "$RECYCLARR_DIR"

log "Recyclarr config oluşturuluyor..."

cat > "$RECYCLARR_CONFIG" <<EOF
sonarr:
  bac-sonarr:
    base_url: http://sonarr:8989
    api_key: ${SONARR_KEY:-}
    delete_old_custom_formats: false
    replace_existing_custom_formats: false

radarr:
  bac-radarr:
    base_url: http://radarr:7878
    api_key: ${RADARR_KEY:-}
    delete_old_custom_formats: false
    replace_existing_custom_formats: false
EOF

chown -R 1000:1000 "$RECYCLARR_DIR" || true

ok "Recyclarr config yazıldı: $RECYCLARR_CONFIG"

log "Recyclarr container kontrol ediliyor..."

if docker ps --format '{{.Names}}' | grep -qx recyclarr; then
  ok "Recyclarr container çalışıyor"
else
  warn "Recyclarr container çalışmıyor, compose up deneniyor"
  cd "$ARR_DIR"
  docker compose up -d recyclarr || true
fi

log "Recyclarr dry validation deneniyor..."

cd "$ARR_DIR"

docker compose run --rm recyclarr list custom-formats sonarr >/tmp/recyclarr-sonarr-list.log 2>&1 || true
docker compose run --rm recyclarr list custom-formats radarr >/tmp/recyclarr-radarr-list.log 2>&1 || true

ok "Recyclarr temel hazırlık tamam"
