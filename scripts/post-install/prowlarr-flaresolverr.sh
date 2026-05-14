#!/usr/bin/env bash
set -euo pipefail

export PROWLARR_URL="${PROWLARR_URL:-http://192.168.50.102:9696}"
export SONARR_URL="${SONARR_URL:-http://192.168.50.102:8989}"
export RADARR_URL="${RADARR_URL:-http://192.168.50.102:7878}"
export FLARESOLVERR_URL="${FLARESOLVERR_URL:-http://192.168.50.103:8191/}"

KEYS_FILE="/tmp/homelab-arr-keys.env"

log() { echo; echo ">>> $1"; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

[[ -f "$KEYS_FILE" ]] && source "$KEYS_FILE"

if [[ -z "${PROWLARR_KEY:-}" ]]; then
  warn "Prowlarr API key yok. Önce arr-core.sh çalışmalı."
  exit 0
fi

if [[ -z "${SONARR_KEY:-}" ]]; then
  warn "Sonarr API key yok. Sonarr app sync atlanacak."
fi

if [[ -z "${RADARR_KEY:-}" ]]; then
  warn "Radarr API key yok. Radarr app sync atlanacak."
fi

api_get() {
  local endpoint="$1"

  curl -fsS \
    -H "X-Api-Key: $PROWLARR_KEY" \
    "$PROWLARR_URL$endpoint"
}

api_post() {
  local endpoint="$1"
  local payload="$2"

  curl -fsS \
    -H "X-Api-Key: $PROWLARR_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "$PROWLARR_URL$endpoint"
}

api_put() {
  local endpoint="$1"
  local payload="$2"

  curl -fsS \
    -H "X-Api-Key: $PROWLARR_KEY" \
    -H "Content-Type: application/json" \
    -X PUT \
    -d "$payload" \
    "$PROWLARR_URL$endpoint"
}

api_delete() {
  local endpoint="$1"

  curl -fsS \
    -H "X-Api-Key: $PROWLARR_KEY" \
    -X DELETE \
    "$PROWLARR_URL$endpoint"
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

  if [[ -z "$tag_id" || "$tag_id" == "null" ]]; then
    warn "Tag oluşturulamadı: $label"
    echo ""
    return 0
  fi

  echo "$tag_id"
}

delete_existing_flaresolverr_proxy() {
  local ids=""

  ids="$(api_get "/api/v1/indexerproxy" | jq -r '.[] | select(.name=="FlareSolverr" or .implementation=="FlareSolverr") | .id' || true)"

  if [[ -z "$ids" ]]; then
    return 0
  fi

  while read -r id; do
    [[ -z "$id" || "$id" == "null" ]] && continue
    warn "Eski/yanlış FlareSolverr proxy siliniyor: ID $id"
    api_delete "/api/v1/indexerproxy/$id" >/dev/null || true
  done <<< "$ids"
}

add_flaresolverr_proxy() {
  log "FlareSolverr proxy ayarlanıyor..."

  local tag_id
  tag_id="$(get_or_create_tag "cl")"

  if [[ -z "$tag_id" ]]; then
    warn "cl tag oluşturulamadı, proxy tags olmadan eklenecek"
    tag_id=""
  fi

  delete_existing_flaresolverr_proxy

  local tags_json="[]"
  if [[ -n "$tag_id" ]]; then
    tags_json="[$tag_id]"
  fi

  local payload
  payload="$(cat <<EOF
{
  "name": "FlareSolverr",
  "implementation": "FlareSolverr",
  "configContract": "FlareSolverrSettings",
  "tags": ${tags_json},
  "fields": [
    {
      "name": "host",
      "value": "${FLARESOLVERR_URL}"
    }
  ]
}
EOF
)"

  if api_post "/api/v1/indexerproxy" "$payload" >/tmp/prowlarr-flaresolverr-create.json 2>/tmp/prowlarr-flaresolverr-create.err; then
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
  [[ -n "${SONARR_KEY:-}" ]] || return 0

  log "Prowlarr → Sonarr app sync ayarlanıyor..."

  delete_existing_app_by_name "Sonarr"

  local payload
  payload="$(cat <<EOF
{
  "name": "Sonarr",
  "syncLevel": "fullSync",
  "implementation": "Sonarr",
  "configContract": "SonarrSettings",
  "fields": [
    {
      "name": "prowlarrUrl",
      "value": "${PROWLARR_URL}"
    },
    {
      "name": "baseUrl",
      "value": "${SONARR_URL}"
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

  if api_post "/api/v1/applications" "$payload" >/tmp/prowlarr-sonarr-app.json 2>/tmp/prowlarr-sonarr-app.err; then
    ok "Prowlarr Sonarr app sync eklendi"
  else
    warn "Prowlarr Sonarr app eklenemedi"
    cat /tmp/prowlarr-sonarr-app.json 2>/dev/null || true
    cat /tmp/prowlarr-sonarr-app.err 2>/dev/null || true
  fi
}

add_radarr_app() {
  [[ -n "${RADARR_KEY:-}" ]] || return 0

  log "Prowlarr → Radarr app sync ayarlanıyor..."

  delete_existing_app_by_name "Radarr"

  local payload
  payload="$(cat <<EOF
{
  "name": "Radarr",
  "syncLevel": "fullSync",
  "implementation": "Radarr",
  "configContract": "RadarrSettings",
  "fields": [
    {
      "name": "prowlarrUrl",
      "value": "${PROWLARR_URL}"
    },
    {
      "name": "baseUrl",
      "value": "${RADARR_URL}"
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

  if api_post "/api/v1/applications" "$payload" >/tmp/prowlarr-radarr-app.json 2>/tmp/prowlarr-radarr-app.err; then
    ok "Prowlarr Radarr app sync eklendi"
  else
    warn "Prowlarr Radarr app eklenemedi"
    cat /tmp/prowlarr-radarr-app.json 2>/dev/null || true
    cat /tmp/prowlarr-radarr-app.err 2>/dev/null || true
  fi
}

wait_for_prowlarr
add_flaresolverr_proxy
add_sonarr_app
add_radarr_app

ok "Prowlarr + FlareSolverr modülü tamamlandı"
