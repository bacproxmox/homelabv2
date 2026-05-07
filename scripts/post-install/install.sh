#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="$BASE_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env file not found."
  echo "Create it from .env.example first:"
  echo "cp $BASE_DIR/.env.example $BASE_DIR/.env"
  exit 1
fi

source "$ENV_FILE"
source "$BASE_DIR/lib/common.sh"

echo "======================================"
echo " HomeLab v2 - Post Install Config"
echo "======================================"
echo ""

run_module() {
  local module="$1"

  echo ""
  echo ">>> Running module: $module"
  bash "$BASE_DIR/modules/$module.sh"
}

case "${1:-all}" in
  chia)
    run_module chia
    ;;

  arr)
    run_module qbittorrent
    run_module prowlarr
    run_module sonarr
    run_module radarr
    run_module bazarr
    run_module jellyseerr
    ;;

  network)
    run_module cloudflared
    ;;

  all)
    run_module qbittorrent
    run_module prowlarr
    run_module sonarr
    run_module radarr
    run_module bazarr
    run_module jellyseerr
    run_module cloudflared
    run_module chia
    ;;

  *)
    echo "Usage:"
    echo "  ./install.sh all"
    echo "  ./install.sh arr"
    echo "  ./install.sh chia"
    echo "  ./install.sh network"
    exit 1
    ;;
esac

echo ""
echo "Post-install configuration completed."
