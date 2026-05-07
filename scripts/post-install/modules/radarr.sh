#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/common.sh"

require_var RADARR_URL
require_var RADARR_API_KEY
require_var QBIT_HOST
require_var QBIT_PORT
require_var QBIT_USER
require_var QBIT_PASS
require_var RADARR_CATEGORY

wait_for_url "$RADARR_URL" "Radarr"

log "Checking existing Radarr download clients"

EXISTING_CLIENTS="$(curl -fsS \
  -H "X-Api-Key: $RADARR_API_KEY" \
  "$RADARR_URL/api/v3/downloadclient")"

if echo "$EXISTING_CLIENTS" | grep -q '"name": "qBittorrent"'; then
  ok "Radarr qBittorrent download client already exists"
  exit 0
fi

log "Adding qBittorrent download client to Radarr"

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
    { "name": "category", "value": "$RADARR_CATEGORY" },
    { "name": "recentMoviePriority", "value": 0 },
    { "name": "olderMoviePriority", "value": 0 },
    { "name": "initialState", "value": 0 }
  ]
}
EOF
)

curl -fsS \
  -H "X-Api-Key: $RADARR_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST \
  -d "$PAYLOAD" \
  "$RADARR_URL/api/v3/downloadclient" >/dev/null

ok "Radarr configured"
