#!/usr/bin/env bash
set -euo pipefail

export TERM=xterm

cd /root/homelab

echo "🚀 Bacmaster HomeLab Installer"
echo
echo "1) Part1 - Proxmox + TrueNAS VM"
echo "2) Part2 - TrueNAS API + Ubuntu ISO VM'ler"
echo "3) Part3 - Docker Stack"
echo
read -rp "Seçim: " CHOICE

case "$CHOICE" in
  1)
    bash scripts/01-bootstrap-truenas.sh
    ;;
  2)
    bash scripts/02-full-auto-part2.sh
    ;;
  3)
    bash scripts/03-full-docker-stack.sh
    ;;
  *)
    echo "Geçersiz seçim."
    exit 1
    ;;
esac
