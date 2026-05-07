#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/common.sh"

require_var QBIT_URL
require_var QBIT_USER
require_var QBIT_PASS
require_var DOWNLOADS_PATH
require_var SONARR_CATEGORY
require_var RADARR_CATEGORY

wait_for_url "$QBIT_URL" "qBittorrent"

COOKIE_FILE="$(mktemp)"

log "Logging into qBittorrent"

LOGIN_RESPONSE="$(curl -fsS \
  -c "$COOKIE_FILE" \
  --data "username=$QBIT_USER&password=$QBIT_PASS" \
  "$QBIT_URL/api/v2/auth/login")"

if [[ "$LOGIN_RESPONSE" != "Ok." ]]; then
  rm -f "$COOKIE_FILE"
  fail "qBittorrent login failed. Check QBIT_USER and QBIT_PASS."
fi

ok "qBittorrent login successful"

log "Creating qBittorrent categories"

curl -fsS -b "$COOKIE_FILE" \
  --data-urlencode "category=$SONARR_CATEGORY" \
  --data-urlencode "savePath=${DOWNLOADS_PATH}/${SONARR_CATEGORY}" \
  "$QBIT_URL/api/v2/torrents/createCategory" >/dev/null || true

curl -fsS -b "$COOKIE_FILE" \
  --data-urlencode "category=$RADARR_CATEGORY" \
  --data-urlencode "savePath=${DOWNLOADS_PATH}/${RADARR_CATEGORY}" \
  "$QBIT_URL/api/v2/torrents/createCategory" >/dev/null || true

ok "qBittorrent categories created"

log "Setting qBittorrent preferences"

PREFS=$(cat <<EOF
{
  "save_path": "${DOWNLOADS_PATH}/",
  "temp_path_enabled": false,
  "create_subfolder_enabled": true
}
EOF
)

curl -fsS -b "$COOKIE_FILE" \
  --data-urlencode "json=$PREFS" \
  "$QBIT_URL/api/v2/app/setPreferences" >/dev/null

rm -f "$COOKIE_FILE"

ok "qBittorrent configured"
