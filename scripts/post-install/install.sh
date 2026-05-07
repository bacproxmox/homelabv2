#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BASE_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env file not found."
  echo ""
  echo "Create it first:"
  echo "cp $BASE_DIR/.env.example $BASE_DIR/.env"
  echo "nano $BASE_DIR/.env"
  exit 1
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
    echo "Usage:"
    echo "  ./install.sh arr"
    echo "  ./install.sh all"
    echo "  ./install.sh qbittorrent"
    echo "  ./install.sh sonarr"
    echo "  ./install.sh radarr"
    echo "  ./install.sh prowlarr"
    echo "  ./install.sh bazarr"
    exit 1
    ;;
esac

echo ""
echo "✅ Post-install configuration completed."
