#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/common.sh"

require_var PROWLARR_URL
require_var PROWLARR_API_KEY
require_var SONARR_URL
require_var SONARR_API_KEY
require_var RADARR_URL
require_var RADARR_API_KEY

wait_for_url "$PROWLARR_URL" "Prowlarr"

log "Checking existing Prowlarr applications"

EXISTING_APPS="$(curl -fsS \
  -H "X-Api-Key: $PROWLARR_API_KEY" \
  "$PROWLARR_URL/api/v1/applications")"

if echo "$EXISTING_APPS" | grep -q '"name": "Sonarr"'; then
  ok "Prowlarr Sonarr application already exists"
else
  log "Adding Sonarr application to Prowlarr"

  SONARR_PAYLOAD=$(cat <<EOF
{
  "name": "Sonarr",
  "syncLevel": "fullSync",
  "implementation": "Sonarr",
  "configContract": "SonarrSettings",
  "fields": [
    { "name": "prowlarrUrl", "value": "$PROWLARR_URL" },
    { "name": "baseUrl", "value": "$SONARR_URL" },
    { "name": "apiKey", "value": "$SONARR_API_KEY" },
    { "name": "syncCategories", "value": [5000, 5030, 5040] },
    { "name": "animeSyncCategories", "value": [5070] }
  ]
}
EOF
)

  curl -fsS \
    -H "X-Api-Key: $PROWLARR_API_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$SONARR_PAYLOAD" \
    "$PROWLARR_URL/api/v1/applications" >/dev/null

  ok "Prowlarr Sonarr application added"
fi

if echo "$EXISTING_APPS" | grep -q '"name": "Radarr"'; then
  ok "Prowlarr Radarr application already exists"
else
  log "Adding Radarr application to Prowlarr"

  RADARR_PAYLOAD=$(cat <<EOF
{
  "name": "Radarr",
  "syncLevel": "fullSync",
  "implementation": "Radarr",
  "configContract": "RadarrSettings",
  "fields": [
    { "name": "prowlarrUrl", "value": "$PROWLARR_URL" },
    { "name": "baseUrl", "value": "$RADARR_URL" },
    { "name": "apiKey", "value": "$RADARR_API_KEY" },
    { "name": "syncCategories", "value": [2000] }
  ]
}
EOF
)

  curl -fsS \
    -H "X-Api-Key: $PROWLARR_API_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$RADARR_PAYLOAD" \
    "$PROWLARR_URL/api/v1/applications" >/dev/null

  ok "Prowlarr Radarr application added"
fi

ok "Prowlarr configured"
