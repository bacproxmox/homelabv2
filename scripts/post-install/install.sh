#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BASE_DIR/.env"

create_env() {

cat > "$ENV_FILE" <<EOF
# ==============================
# HomeLab v2 - Post Install ENV
# ==============================

TZ=Europe/Istanbul

# ARR VM
ARR_HOST=192.168.50.102

# qBittorrent
QBIT_URL=http://192.168.50.102:8080
QBIT_HOST=192.168.50.102
QBIT_PORT=8080
QBIT_USER=admin
QBIT_PASS=CHANGE_ME

# Prowlarr
PROWLARR_URL=http://192.168.50.102:9696
PROWLARR_API_KEY=CHANGE_ME

# Sonarr
SONARR_URL=http://192.168.50.102:8989
SONARR_API_KEY=CHANGE_ME

# Radarr
RADARR_URL=http://192.168.50.102:7878
RADARR_API_KEY=CHANGE_ME

# Bazarr
BAZARR_URL=http://192.168.50.102:6767
BAZARR_API_KEY=CHANGE_ME

# Paths inside containers
DOWNLOADS_PATH=/downloads
MOVIES_PATH=/movies
SERIES_PATH=/series

# qBittorrent categories
SONARR_CATEGORY=sonarr
RADARR_CATEGORY=radarr
EOF

echo ""
echo "✅ .env file created:"
echo "   $ENV_FILE"
echo ""
echo "Edit it before continuing:"
echo ""
echo "nano $ENV_FILE"
echo ""

exit 0
}

if [[ ! -f "$ENV_FILE" ]]; then
  echo ""
  echo "⚠️  .env file not found."
  echo "Creating default .env ..."
  create_env
fi

set -a
source "$ENV_FILE"
set +a

source "$BASE_DIR/lib/common.sh"

echo ""
echo "======================================"
echo " HomeLab v2 - Post Install Config"
echo "======================================"
echo ""

run_module() {
  local module="$1"

  echo ""
  echo "--------------------------------------"
  echo "Running module: $module"
  echo "--------------------------------------"

  bash "$BASE_DIR/modules/$module.sh"
}

case "${1:-all}" in

  arr)
    run_module qbittorrent
    run_module sonarr
    run_module radarr
    run_module prowlarr
    run_module bazarr
    ;;

  qbittorrent)
    run_module qbittorrent
    ;;

  sonarr)
    run_module sonarr
    ;;

  radarr)
    run_module radarr
    ;;

  prowlarr)
    run_module prowlarr
    ;;

  bazarr)
    run_module bazarr
    ;;

  all)
    run_module qbittorrent
    run_module sonarr
    run_module radarr
    run_module prowlarr
    run_module bazarr
    ;;

  *)
    echo ""
    echo "Usage:"
    echo ""
    echo "  ./install.sh arr"
    echo "  ./install.sh all"
    echo "  ./install.sh qbittorrent"
    echo "  ./install.sh sonarr"
    echo "  ./install.sh radarr"
    echo "  ./install.sh prowlarr"
    echo "  ./install.sh bazarr"
    echo ""
    exit 1
    ;;
esac

echo ""
echo "✅ Post-install configuration completed."
