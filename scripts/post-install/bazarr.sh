#!/usr/bin/env bash
set -euo pipefail

log() { echo; echo ">>> $1"; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

[[ -f /tmp/homelab-arr-keys.env ]] && source /tmp/homelab-arr-keys.env

BAZARR_DIR="$ARR_DIR/bazarr"

log "Bazarr erişim kontrolü..."

docker restart bazarr >/dev/null 2>&1 || true
sleep 10

if curl -fsS --max-time 5 "$BAZARR_URL" >/dev/null 2>&1; then
  ok "Bazarr erişilebilir"
else
  warn "Bazarr erişilemiyor"
fi

log "Bazarr Sonarr/Radarr bağlantı bilgileri yazılıyor..."

cat > "$BAZARR_DIR/homelab-bazarr-settings.txt" <<EOF
Sonarr:
  URL: http://192.168.50.102:8989
  API Key: ${SONARR_KEY:-YOK}

Radarr:
  URL: http://192.168.50.102:7878
  API Key: ${RADARR_KEY:-YOK}

Language profile hedefi:
  Turkish
  German
  English
EOF

chown -R 1000:1000 "$BAZARR_DIR" || true

ok "Bazarr hazırlık tamam"
