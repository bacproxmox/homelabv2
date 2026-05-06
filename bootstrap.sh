#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/bacproxmox/homelabv2.git"
TARGET_DIR="/root/homelab"

echo "🚀 Bacmaster bootstrap başlıyor..."

echo "🔧 Enterprise repo kapatılıyor..."

rm -f /etc/apt/sources.list.d/pve-enterprise.sources
rm -f /etc/apt/sources.list.d/ceph.sources
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/ceph.list

. /etc/os-release

echo "deb http://download.proxmox.com/debian/pve $VERSION_CODENAME pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list

apt update
apt install -y git curl wget nano

echo "📥 Repo indiriliyor..."

if [[ -d "$TARGET_DIR/.git" ]]; then
  cd "$TARGET_DIR"
  git fetch origin
  git reset --hard origin/main
else
  rm -rf "$TARGET_DIR"
  git clone "$REPO_URL" "$TARGET_DIR"
  cd "$TARGET_DIR"
fi

chmod +x install.sh
chmod +x scripts/*.sh

echo "✅ Bootstrap tamam."
echo
echo "Installer başlatılıyor..."
bash install.sh
