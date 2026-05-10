#!/usr/bin/env bash
set -euo pipefail

log() { echo; echo ">>> $1"; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

[[ -f /tmp/homelab-arr-keys.env ]] && source /tmp/homelab-arr-keys.env

BAZARR_CONFIG_DIR="$ARR_DIR/bazarr/config"

log "Bazarr temel klasör/config kontrolü..."

mkdir -p "$BAZARR_CONFIG_DIR"

docker restart bazarr >/dev/null 2>&1 || true
sleep 10

if curl -fsS --max-time 5 "$BAZARR_URL" >/dev/null 2>&1; then
  ok "Bazarr erişilebilir"
else
  warn "Bazarr erişilemiyor"
fi

log "Bazarr Sonarr/Radarr bağlantı notları yazılıyor..."

cat > "$ARR_DIR/bazarr/homelab-bazarr-settings.txt" <<EOF
Bazarr otomasyon notu:

Sonarr:
  URL: http://192.168.50.102:8989
  API Key: ${SONARR_KEY:-YOK}

Radarr:
  URL: http://192.168.50.102:7878
  API Key: ${RADARR_KEY:-YOK}

Diller:
  Turkish / German / English

Not:
Bazarr API/config formatı sürüme göre değişebildiği için bu modül şu an güvenli hazırlık yapar.
Sonraki iterasyonda config.yaml formatı netleşince otomatik provider/dil ayarı basılacak.
EOF

chown -R 1000:1000 "$ARR_DIR/bazarr" || true

ok "Bazarr hazırlık tamam"
