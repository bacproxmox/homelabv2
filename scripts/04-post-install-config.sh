#!/usr/bin/env bash
set -euo pipefail

export TERM=xterm

SECRETS_DIR="/root/.secrets"
USERS_ENV="$SECRETS_DIR/users.env"
POST_ENV="$SECRETS_DIR/postinstall.env"

[[ -f "$USERS_ENV" ]] || {
  echo "❌ users.env yok. Önce Part1 çalışmalı."
  exit 1
}

source "$USERS_ENV"

SSH_USER="$BACMASTER_USER"
SSH_PASS="$BACMASTER_PASS"
ARR_IP="192.168.50.102"

LOCAL_MODULE_DIR="/root/homelab/scripts/post-install"
REMOTE_DIR="/home/bacmaster/homelab-post-install"

ask_visible_into() {
  local __var="$1"
  local prompt="$2"
  local default="${3:-}"
  local input=""

  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " input
    input="${input:-$default}"
  else
    while true; do
      read -r -p "$prompt: " input
      [[ -n "$input" ]] && break
      echo "Boş bırakılamaz."
    done
  fi

  printf -v "$__var" "%s" "$input"
}

shell_quote() {
  printf "%q" "$1"
}

if [[ ! -f "$POST_ENV" ]]; then
  echo
  echo "🔐 Post-install servis bilgileri alınacak."
  echo "⚠️ Şifreler bu kurulum sırasında ekranda görünecek."
  echo

  ask_visible_into QBIT_USER "qBittorrent user" "admin"
  ask_visible_into QBIT_PASS "qBittorrent password"

  ask_visible_into ARR_ADMIN_USER "Sonarr/Radarr/Prowlarr admin user" "$BACMASTER_USER"
  ask_visible_into ARR_ADMIN_PASS "Sonarr/Radarr/Prowlarr admin password"

  cat > "$POST_ENV" <<EOF
QBIT_USER="$QBIT_USER"
QBIT_PASS="$QBIT_PASS"
ARR_ADMIN_USER="$ARR_ADMIN_USER"
ARR_ADMIN_PASS="$ARR_ADMIN_PASS"
EOF

  chmod 600 "$POST_ENV"
fi

source "$POST_ENV"

apt update
apt install -y sshpass curl rsync

echo "⏳ SSH bekleniyor: $ARR_IP"

until sshpass -p "$SSH_PASS" ssh \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=5 \
  "$SSH_USER@$ARR_IP" "echo ok" >/dev/null 2>&1; do
  sleep 5
done

echo "✅ SSH hazır: $ARR_IP"

[[ -d "$LOCAL_MODULE_DIR" ]] || {
  echo "❌ Modül klasörü yok: $LOCAL_MODULE_DIR"
  exit 1
}

echo "📦 Post-install modülleri VM102'ye kopyalanıyor..."

sshpass -p "$SSH_PASS" ssh \
  -o StrictHostKeyChecking=no \
  "$SSH_USER@$ARR_IP" \
  "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"

sshpass -p "$SSH_PASS" rsync -av \
  -e "ssh -o StrictHostKeyChecking=no" \
  "$LOCAL_MODULE_DIR/" \
  "$SSH_USER@$ARR_IP:$REMOTE_DIR/"

QBIT_USER_Q="$(shell_quote "$QBIT_USER")"
QBIT_PASS_Q="$(shell_quote "$QBIT_PASS")"
ARR_ADMIN_USER_Q="$(shell_quote "$ARR_ADMIN_USER")"
ARR_ADMIN_PASS_Q="$(shell_quote "$ARR_ADMIN_PASS")"
SSH_PASS_Q="$(shell_quote "$SSH_PASS")"

echo "🚀 VM102 post-install modülleri çalıştırılıyor..."

sshpass -p "$SSH_PASS" ssh \
  -o StrictHostKeyChecking=no \
  "$SSH_USER@$ARR_IP" \
  "echo $SSH_PASS_Q | sudo -S -p '' env QBIT_USER=$QBIT_USER_Q QBIT_PASS=$QBIT_PASS_Q ARR_ADMIN_USER=$ARR_ADMIN_USER_Q ARR_ADMIN_PASS=$ARR_ADMIN_PASS_Q bash '$REMOTE_DIR/run-all.sh'"

echo
echo "✅ PART4 post-install config tamamlandı."
