#!/usr/bin/env bash
set -euo pipefail

healthcheck() {
  local name="$1"
  local url="$2"

  if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
    echo "✅ $name : $url"
  else
    echo "❌ $name : $url"
  fi
}

echo
echo "🔍 Final healthcheck:"
echo

healthcheck "qBittorrent"   "http://192.168.50.102:8080"
healthcheck "Prowlarr"      "http://192.168.50.102:9696"
healthcheck "Sonarr"        "http://192.168.50.102:8989"
healthcheck "Radarr"        "http://192.168.50.102:7878"
healthcheck "Bazarr"        "http://192.168.50.102:6767"
healthcheck "Jellyseerr"    "http://192.168.50.102:5055"
healthcheck "Flaresolverr"  "http://192.168.50.103:8191"

echo
echo "📦 Docker container listesi:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
