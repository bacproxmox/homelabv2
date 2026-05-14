#!/usr/bin/env bash
set -euo pipefail

export PROWLARR_URL="${PROWLARR_URL:-http://192.168.50.102:9696}"
export SONARR_URL="${SONARR_URL:-http://192.168.50.102:8989}"
export RADARR_URL="${RADARR_URL:-http://192.168.50.102:7878}"
export FLARESOLVERR_URL="${FLARESOLVERR_URL:-http://192.168.50.103:8191/}"

# Prowlarr Applications ekranında kullanılacak container içi URL'ler
export PROWLARR_INTERNAL_URL="${PROWLARR_INTERNAL_URL:-http://prowlarr:9696}"
export SONARR_INTERNAL_URL="${SONARR_INTERNAL_URL:-http://sonarr:8989}"
export RADARR_INTERNAL_URL="${RADARR_INTERNAL_URL:-http://radarr:7878}"

KEYS_FILE="/tmp/homelab-arr-keys.env"

log() { echo; echo ">>> $1"; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

[[ -f "$KEYS_FILE" ]] && source "$KEYS_FILE"

if [[ -z "${PROWLARR_KEY:-}" ]]; then
  warn "Prowlarr API key yok. Önce arr-core.sh çalışmalı."
  exit 0
fi

api_get() {
  curl -fsS -H "X-Api-Key: $PROWLARR_KEY" "$PROWLARR_URL$1"
}

api_post() {
  curl -fsS \
    -H "X-Api-Key: $PROWLARR_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$2" \
    "$PROWLARR_URL$1"
}

api_delete() {
  curl -fsS \
    -H "X-Api-Key: $PROWLARR_KEY" \
    -X DELETE \
    "$PROWLARR_URL$1"
}

wait_for_prowlarr() {
  log "Prowlarr API bekleniyor..."

  for i in {1..60}; do
    if api_get "/api/v1/system/status" >/dev/null 2>&1; then
      ok "Prowlarr API hazır"
      return 0
    fi
    sleep 2
  done

  warn "Prowlarr API erişilemedi"
  exit 0
}

get_or_create_tag() {
  local label="$1"
  local tag_id=""

  tag_id="$(api_get "/api/v1/tag" | jq -r --arg label "$label" '.[] | select(.label==$label) | .id' | head -n1 || true)"

  if [[ -n "$tag_id" && "$tag_id" != "null" ]]; then
    echo "$tag_id"
    return 0
  fi

  tag_id="$(api_post "/api/v1/tag" "{\"label\":\"${label}\"}" | jq -r '.id // empty' || true)"
  echo "$tag_id"
}

delete_existing_flaresolverr_proxy() {
  local ids=""

  ids="$(api_get "/api/v1/indexerproxy" | jq -r '.[] | select(.name=="FlareSolverr" or .implementation=="FlareSolverr") | .id' || true)"

  while read -r id; do
    [[ -z "$id" || "$id" == "null" ]] && continue
    warn "Eski/yanlış FlareSolverr proxy siliniyor: ID $id"
    api_delete "/api/v1/indexerproxy/$id" >/dev/null || true
  done <<< "$ids"
}

add_flaresolverr_proxy() {
  log "FlareSolverr proxy ayarlanıyor..."

  TAG_ID="$(get_or_create_tag "cl")"

  if [[ -z "${TAG_ID:-}" || "$TAG_ID" == "null" ]]; then
    warn "cl tag oluşturulamadı, proxy tags olmadan eklenecek"
    TAG_JSON="[]"
  else
    TAG_JSON="[$TAG_ID]"
  fi

  delete_existing_flaresolverr_proxy

  PAYLOAD="$(cat <<EOF
{
  "name": "FlareSolverr",
  "implementation": "FlareSolverr",
  "configContract": "FlareSolverrSettings",
  "tags": ${TAG_JSON},
  "fields": [
    {
      "name": "host",
      "value": "${FLARESOLVERR_URL}"
    }
  ]
}
EOF
)"

  if api_post "/api/v1/indexerproxy" "$PAYLOAD" >/tmp/prowlarr-flaresolverr-create.json 2>/tmp/prowlarr-flaresolverr-create.err; then
    ok "FlareSolverr proxy eklendi: ${FLARESOLVERR_URL} tag=cl"
  else
    warn "FlareSolverr proxy eklenemedi"
    cat /tmp/prowlarr-flaresolverr-create.json 2>/dev/null || true
    cat /tmp/prowlarr-flaresolverr-create.err 2>/dev/null || true
  fi
}

delete_existing_app_by_name() {
  local app_name="$1"
  local ids=""

  ids="$(api_get "/api/v1/applications" | jq -r --arg name "$app_name" '.[] | select(.name==$name) | .id' || true)"

  while read -r id; do
    [[ -z "$id" || "$id" == "null" ]] && continue
    warn "Eski uygulama siliniyor: $app_name ID $id"
    api_delete "/api/v1/applications/$id" >/dev/null || true
  done <<< "$ids"
}

add_sonarr_app() {
  [[ -n "${SONARR_KEY:-}" ]] || {
    warn "Sonarr API key yok, Sonarr app sync atlandı"
    return 0
  }

  log "Prowlarr → Sonarr app sync ayarlanıyor..."

  delete_existing_app_by_name "Sonarr"

  PAYLOAD="$(cat <<EOF
{
  "name": "Sonarr",
  "syncLevel": "fullSync",
  "implementation": "Sonarr",
  "configContract": "SonarrSettings",
  "fields": [
    {
      "name": "prowlarrUrl",
      "value": "${PROWLARR_INTERNAL_URL}"
    },
    {
      "name": "baseUrl",
      "value": "${SONARR_INTERNAL_URL}"
    },
    {
      "name": "apiKey",
      "value": "${SONARR_KEY}"
    },
    {
      "name": "syncCategories",
      "value": [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080]
    },
    {
      "name": "animeSyncCategories",
      "value": [5070]
    }
  ]
}
EOF
)"

  if api_post "/api/v1/applications" "$PAYLOAD" >/tmp/prowlarr-sonarr-app.json 2>/tmp/prowlarr-sonarr-app.err; then
    ok "Prowlarr Sonarr app sync eklendi"
  else
    warn "Prowlarr Sonarr app eklenemedi"
    echo "--- response ---"
    cat /tmp/prowlarr-sonarr-app.json 2>/dev/null || true
    echo "--- error ---"
    cat /tmp/prowlarr-sonarr-app.err 2>/dev/null || true
  fi
}

add_radarr_app() {
  [[ -n "${RADARR_KEY:-}" ]] || {
    warn "Radarr API key yok, Radarr app sync atlandı"
    return 0
  }

  log "Prowlarr → Radarr app sync ayarlanıyor..."

  delete_existing_app_by_name "Radarr"

  PAYLOAD="$(cat <<EOF
{
  "name": "Radarr",
  "syncLevel": "fullSync",
  "implementation": "Radarr",
  "configContract": "RadarrSettings",
  "fields": [
    {
      "name": "prowlarrUrl",
      "value": "${PROWLARR_INTERNAL_URL}"
    },
    {
      "name": "baseUrl",
      "value": "${RADARR_INTERNAL_URL}"
    },
    {
      "name": "apiKey",
      "value": "${RADARR_KEY}"
    },
    {
      "name": "syncCategories",
      "value": [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080]
    }
  ]
}
EOF
)"

  if api_post "/api/v1/applications" "$PAYLOAD" >/tmp/prowlarr-radarr-app.json 2>/tmp/prowlarr-radarr-app.err; then
    ok "Prowlarr Radarr app sync eklendi"
  else
    warn "Prowlarr Radarr app eklenemedi"
    echo "--- response ---"
    cat /tmp/prowlarr-radarr-app.json 2>/dev/null || true
    echo "--- error ---"
    cat /tmp/prowlarr-radarr-app.err 2>/dev/null || true
  fi
}

trigger_app_sync() {
  log "Prowlarr app indexer sync tetikleniyor..."

  api_post "/api/v1/command" '{"name":"ApplicationIndexerSync"}' >/tmp/prowlarr-sync-command.json 2>/tmp/prowlarr-sync-command.err || true

  ok "Prowlarr sync komutu denendi"
}

verify_apps() {
  log "Prowlarr Applications doğrulanıyor..."

  APPS="$(api_get "/api/v1/applications" || echo "[]")"

  if echo "$APPS" | jq -e '.[] | select(.name=="Sonarr")' >/dev/null 2>&1; then
    ok "Sonarr application var"
  else
    warn "Sonarr application hâlâ yok"
  fi

  if echo "$APPS" | jq -e '.[] | select(.name=="Radarr")' >/dev/null 2>&1; then
    ok "Radarr application var"
  else
    warn "Radarr application hâlâ yok"
  fi
}

wait_for_prowlarr
add_flaresolverr_proxy
add_sonarr_app
add_radarr_app
trigger_app_sync
verify_apps

ok "Prowlarr + FlareSolverr + Applications modülü tamamlandı"
