cat > scripts/02-full-auto-part2.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/root/.part2-state"
SECRETS_DIR="/root/.secrets"
PART2_ENV="$SECRETS_DIR/part2.env"
USERS_ENV="$SECRETS_DIR/users.env"

mkdir -p "$STATE_DIR" "$SECRETS_DIR"

done_step() { [[ -f "$STATE_DIR/$1.done" ]]; }
mark_step() { touch "$STATE_DIR/$1.done"; }

ask_secret() {
  local prompt="$1"
  local var
  read -rsp "$prompt: " var
  echo
  printf "%s" "$var"
}

echo "🚀 Part2: TrueNAS API + VM oluşturma"

if [[ ! -f "$USERS_ENV" ]]; then
  echo "❌ $USERS_ENV yok. Önce Part1 çalışmalı."
  exit 1
fi

source "$USERS_ENV"

if [[ ! -f "$PART2_ENV" ]]; then
  echo
  echo "TrueNAS API key oluşturmak için TrueNAS Shell:"
  echo "midclt call api_key.create '{\"name\": \"bacmaster-installer\", \"username\": \"truenas_admin\"}'"
  echo
  TRUENAS_KEY="$(ask_secret "TrueNAS API key yapıştır")"

cat > "$PART2_ENV" <<EOL
TRUENAS_IP="192.168.50.101"
TRUENAS_API_KEY="$TRUENAS_KEY"

VM_STORAGE="nvme-vm"
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMAGE_FILE="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"

CI_USER="$BACMASTER_USER"
CI_PASS="$BACMASTER_PASS"
GW="192.168.50.1"
DNS="1.1.1.1"
EOL

chmod 600 "$PART2_ENV"
fi

source "$PART2_ENV"

TN_API="http://${TRUENAS_IP}/api/v2.0"

tn_get() {
  curl -sk -H "Authorization: Bearer ${TRUENAS_API_KEY}" "$TN_API/$1"
}

tn_post() {
  curl -sk -X POST \
    -H "Authorization: Bearer ${TRUENAS_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$2" \
    "$TN_API/$1"
}

tn_put() {
  curl -sk -X PUT \
    -H "Authorization: Bearer ${TRUENAS_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$2" \
    "$TN_API/$1"
}

# =========================
# TRUENAS API CHECK
# =========================
if ! done_step "truenas_api"; then
  tn_get "system/info" >/tmp/truenas-info.json
  mark_step "truenas_api"
fi

# =========================
# TRUENAS DATASETS/NFS
# =========================
if ! done_step "truenas_datasets"; then
  tn_post "user" "{
    \"username\": \"${MEDIA_USER}\",
    \"full_name\": \"Media User\",
    \"group_create\": true,
    \"uid\": ${MEDIA_UID},
    \"password\": \"${MEDIA_PASS}\",
    \"smb\": false
  }" >/dev/null || true

  for ds in \
    "tank/media" \
    "tank/media/downloads" \
    "tank/media/movies" \
    "tank/media/series" \
    "tank/media/music" \
    "tank/photos" \
    "tank/temp" \
    "private/documents" \
    "private/photos" \
    "private/timemachine"
  do
    tn_post "pool/dataset" "{\"name\": \"${ds}\", \"share_type\": \"GENERIC\"}" >/dev/null || true
  done

  tn_post "sharing/nfs" "{
    \"paths\": [\"/mnt/tank/media\"],
    \"comment\": \"tank media NFS\",
    \"enabled\": true,
    \"mapall_user\": \"${MEDIA_USER}\",
    \"mapall_group\": \"${MEDIA_USER}\"
  }" >/dev/null || true

  tn_put "service/id/nfs" "{\"enable\": true}" >/dev/null || true
  tn_post "service/start" "{\"service\": \"nfs\"}" >/dev/null || true

  mark_step "truenas_datasets"
fi

# =========================
# UBUNTU IMAGE
# =========================
if ! done_step "ubuntu_image"; then
  mkdir -p /var/lib/vz/template/iso
  wget -nc -O "$UBUNTU_IMAGE_FILE" "$UBUNTU_IMAGE_URL"
  mark_step "ubuntu_image"
fi

# =========================
# TEMPLATE 9000
# =========================
if ! done_step "ubuntu_template"; then
  if ! qm status 9000 &>/dev/null; then
    qm create 9000 \
      --name ubuntu-template \
      --memory 2048 \
      --cores 2 \
      --cpu host \
      --net0 virtio,bridge=vmbr0 \
      --scsihw virtio-scsi-single \
      --agent enabled=1

    qm importdisk 9000 "$UBUNTU_IMAGE_FILE" "$VM_STORAGE"
    qm set 9000 --scsi0 "$VM_STORAGE":vm-9000-disk-0,discard=on,ssd=1,iothread=1
    qm set 9000 --ide2 "$VM_STORAGE":cloudinit
    qm set 9000 --boot order=scsi0
    qm set 9000 --serial0 socket
    qm set 9000 --vga serial0
    qm set 9000 --ciuser "$CI_USER"
    qm set 9000 --cipassword "$CI_PASS"
    qm set 9000 --nameserver "$DNS"
    qm template 9000
  fi

  mark_step "ubuntu_template"
fi

# =========================
# SNIPPET
# =========================
if ! done_step "snippets"; then
  mkdir -p /var/lib/vz/snippets

cat > /var/lib/vz/snippets/bacmaster-docker.yaml <<EOL
#cloud-config
package_update: true
package_upgrade: true

packages:
  - qemu-guest-agent
  - nfs-common
  - curl
  - wget
  - nano
  - htop
  - git
  - ca-certificates

runcmd:
  - systemctl enable --now qemu-guest-agent
  - curl -fsSL https://get.docker.com | sh
  - usermod -aG docker $CI_USER
  - mkdir -p /mnt/media
  - echo '192.168.50.101:/mnt/tank/media /mnt/media nfs defaults,_netdev,x-systemd.automount,noatime 0 0' >> /etc/fstab
  - systemctl daemon-reload
  - mount -a || true
  - mkdir -p /home/$CI_USER/docker
  - chown -R $CI_USER:$CI_USER /home/$CI_USER/docker
EOL

  mark_step "snippets"
fi

create_vm() {
  local ID="$1"
  local NAME="$2"
  local IP="$3"
  local RAM="$4"
  local CORES="$5"
  local DISK="$6"

  if qm status "$ID" &>/dev/null; then
    echo "✅ VM $ID $NAME zaten var"
    return
  fi

  qm clone 9000 "$ID" --name "$NAME" --full true --storage "$VM_STORAGE"
  qm set "$ID" --memory "$RAM" --cores "$CORES" --cpu host
  qm resize "$ID" scsi0 "$DISK"
  qm set "$ID" --ipconfig0 ip="${IP}/24,gw=${GW}"
  qm set "$ID" --nameserver "$DNS"
  qm set "$ID" --cicustom "user=local:snippets/bacmaster-docker.yaml"
  qm set "$ID" --onboot 1
}

if ! done_step "vms"; then
  create_vm 103 docker-network 192.168.50.103 4096 2 32G
  create_vm 102 docker-arr     192.168.50.102 8192 4 64G
  create_vm 104 nextcloud      192.168.50.104 8192 4 64G
  create_vm 105 homeassistant  192.168.50.105 4096 2 32G
  create_vm 106 docker-media   192.168.50.106 24576 6 128G
  create_vm 107 chia-farmer    192.168.50.107 8192 4 64G
  create_vm 110 backup-server  192.168.50.110 8192 4 64G

  mark_step "vms"
fi

if ! done_step "start_vms"; then
  for id in 102 103 104 105 106 107 110; do
    qm start "$id" || true
  done

  mark_step "start_vms"
fi

echo "✅ PART2 tamamlandı."
EOF

chmod +x scripts/02-full-auto-part2.sh
