#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

export ARR_DIR="/home/bacmaster/docker/arr"

export ARR_IP="192.168.50.102"
export NET_IP="192.168.50.103"

export SONARR_URL="http://192.168.50.102:8989"
export RADARR_URL="http://192.168.50.102:7878"
export PROWLARR_URL="http://192.168.50.102:9696"
export BAZARR_URL="http://192.168.50.102:6767"
export FLARESOLVERR_URL="http://192.168.50.103:8191"

export SONARR_CFG="$ARR_DIR/sonarr/config.xml"
export RADARR_CFG="$ARR_DIR/radarr/config.xml"
export PROWLARR_CFG="$ARR_DIR/prowlarr/config.xml"

log() { echo; echo ">>> $1"; }
ok() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

apt update
apt install -y curl python3

chmod +x "$BASE_DIR"/*.sh

echo "🚀 HomeLab Part4 modular post-install başlıyor..."

for module in \
  arr-core.sh \
  prowlarr-flaresolverr.sh \
  bazarr.sh \
  recyclarr.sh \
  healthcheck.sh
do
  echo
  echo "=============================="
  echo "▶️ Modül: $module"
  echo "=============================="

  if bash "$BASE_DIR/$module"; then
    echo "✅ Modül tamamlandı: $module"
  else
    echo "⚠️ Modül hata verdi ama kurulum devam ediyor: $module"
  fi
done

echo
echo "🎯 Modular post-install tamamlandı."
