#!/usr/bin/env bash
set -euo pipefail

log() { echo; echo ">>> $1"; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

[[ -f /tmp/homelab-arr-keys.env ]] && source /tmp/homelab-arr-keys.env

[[ -n "${PROWLARR_KEY:-}" ]] || {
  warn "Prowlarr API key yok, modül atlandı"
  exit 0
}

log "FlareSolverr erişimi kontrol ediliyor..."

if curl -fsS --max-time 5 "$FLARESOLVERR_URL" >/dev/null 2>&1; then
  ok "FlareSolverr erişilebilir: $FLARESOLVERR_URL"
else
  warn "FlareSolverr erişilemiyor: $FLARESOLVERR_URL"
fi

log "Prowlarr içine FlareSolverr proxy ekleniyor..."

EXISTING="$(curl -fsS -H "X-Api-Key: $PROWLARR_KEY" "$PROWLARR_URL/api/v1/indexerProxy" || true)"

if echo "$EXISTING" | grep -q '"name": "FlareSolverr"'; then
  ok "Prowlarr FlareSolverr proxy zaten var"
else
  PAYLOAD="$(cat <<EOF
{
  "name": "FlareSolverr",
  "implementation": "FlareSolverr",
  "configContract": "FlareSolverrSettings",
  "tags": [],
  "fields": [
    { "name": "host", "value": "192.168.50.103" },
    { "name": "port", "value": 8191 },
    { "name": "urlBase", "value": "" },
    { "name": "requestTimeout", "value": 60 }
  ]
}
EOF
)"

  RESP="$(curl -sS \
    -H "X-Api-Key: $PROWLARR_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$PAYLOAD" \
    "$PROWLARR_URL/api/v1/indexerProxy" || true)"

  if echo "$RESP" | grep -qi "error\|invalid\|exception"; then
    warn "FlareSolverr proxy ekleme cevabı: $RESP"
  else
    ok "Prowlarr FlareSolverr proxy eklendi/denendi"
  fi
fi

log "Prowlarr → Sonarr/Radarr app sync kontrol ediliyor..."

APPS="$(curl -fsS -H "X-Api-Key: $PROWLARR_KEY" "$PROWLARR_URL/api/v1/applications" || true)"

if ! echo "$APPS" | grep -q '"name": "Sonarr"'; then
  warn "Prowlarr Sonarr app yok. ARR core tekrar çalıştırılabilir."
else
  ok "Prowlarr Sonarr app var"
fi

if ! echo "$APPS" | grep -q '"name": "Radarr"'; then
  warn "Prowlarr Radarr app yok. ARR core tekrar çalıştırılabilir."
else
  ok "Prowlarr Radarr app var"
fi
