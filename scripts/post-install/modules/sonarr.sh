#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/common.sh"

require_var SONARR_URL
require_var SONARR_API_KEY
require_var QBIT_HOST
require_var QBIT_PORT
require_var QBIT_USER
require_var QBIT_PASS
require_var SONARR_CATEGORY

wait_for_url "$SONARR_URL" "Sonarr"

log "Checking existing Sonarr download clients"

EXISTING_CLIENTS="$(curl -fsS \
  -H "X-Api-Key: $SONARR_API_KEY" \
  "$SONARR_URL/api/v3/downloadclient")"

if echo "$EXISTING_CLIENTS" | grep -q '"name": "qBittorrent"'; then
  ok "Sonarr qBittorrent download client already exists"
  exit 0
fi

log "Adding qBittorrent download client to Sonarr"

PAYLOAD=$(cat <<EOF
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
    { "name": "host", "value": "$QBIT_HOST" },
    { "name": "port", "value": $QBIT_PORT },
    { "name": "useSsl", "value": false },
    { "name": "urlBase", "value": "" },
    { "name": "username", "value": "$QBIT_USER" },
    { "name": "password", "value": "$QBIT_PASS" },
    { "name": "category", "value": "$SONARR_CATEGORY" },
    { "name": "recentTvPriority", "value": 0 },
    { "name": "olderTvPriority", "value": 0 },
    { "name": "initialState", "value": 0 }
  ]
}
EOF
)

curl -fsS \
  -H "X-Api-Key: $SONARR_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST \
  -d "$PAYLOAD" \
  "$SONARR_URL/api/v3/downloadclient" >/dev/null

ok "Sonarr configured"
