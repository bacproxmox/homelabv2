#!/usr/bin/env bash
set -euo pipefail

export ARR_DIR="${ARR_DIR:-/home/bacmaster/docker/arr}"
export BAZARR_URL="${BAZARR_URL:-http://192.168.50.102:6767}"

log() { echo; echo ">>> $1"; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

[[ -f /tmp/homelab-arr-keys.env ]] && source /tmp/homelab-arr-keys.env

BAZARR_DIR="$ARR_DIR/bazarr"

wait_for_bazarr() {
  log "Bazarr erişim kontrolü: $BAZARR_URL"

  docker restart bazarr >/dev/null 2>&1 || true
  sleep 10

  for i in {1..60}; do
    if curl -fsS --max-time 5 "$BAZARR_URL" >/dev/null 2>&1; then
      ok "Bazarr erişilebilir"
      return 0
    fi
    sleep 2
  done

  warn "Bazarr erişilemiyor ama final healthcheck tekrar kontrol edecek"
  return 0
}

wait_for_bazarr

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

Not:
Bazarr API/config formatı sürüme göre değişebildiği için bu modül güvenli hazırlık yapar.
EOF

chown -R 1000:1000 "$BAZARR_DIR" || true

ok "Bazarr hazırlık tamam"
