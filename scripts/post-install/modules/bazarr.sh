#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/common.sh"

require_var BAZARR_URL
require_var BAZARR_API_KEY
require_var SONARR_URL
require_var SONARR_API_KEY
require_var RADARR_URL
require_var RADARR_API_KEY

wait_for_url "$BAZARR_URL" "Bazarr"

log "Checking Bazarr API"

curl -fsS \
  -H "X-API-KEY: $BAZARR_API_KEY" \
  "$BAZARR_URL/api/system/status" >/dev/null || {
    warn "Bazarr API status endpoint failed. Bazarr may use a different API endpoint/version."
    exit 0
  }

ok "Bazarr API reachable"

warn "Bazarr Sonarr/Radarr binding will be added after checking your Bazarr API version."
ok "Bazarr basic check completed"
