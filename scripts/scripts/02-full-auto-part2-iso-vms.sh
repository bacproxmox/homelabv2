#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/root/.part2-iso-state"
SECRETS_DIR="/root/.secrets"
PART2_ENV="$SECRETS_DIR/part2.env"
USERS_ENV="$SECRETS_DIR/users.env"

mkdir -p "$STATE_DIR" "$SECRETS_DIR"

done_step() { [[ -f "$STATE_DIR/$1.done" ]]; }
mark_step() { touch "$STATE_DIR/$1.done"; }

ask_secret() {
  local prompt="$1"
  local var=""
  read -r -s -p "$prompt: " var </dev/tty
  echo "" >/dev/tty
  printf "%s" "$var"
}

echo "🚀 Part2 ISO Mode: TrueNAS API + Ubuntu ISO VM oluşturma"

if [[ ! -f "$USERS_ENV" ]]; then
  echo "❌ $USERS_ENV yok. Önce Part1 çalışmalı."
  exit 1
fi

source "$USERS_ENV"

if [[ ! -f "$PART2_ENV" ]]; then
  echo
  echo "TrueNAS API key oluşturmak için TrueNAS Shell:"
  echo "midclt call api_key.create '{\"name\":\"bacmaster-installer\",\"username\":\"truenas_admin\"}'"
  echo
  TRUENAS_KEY="$(ask_secret "TrueNAS API key yapıştır")"

cat > "$PART2_ENV" <<EOF
TRUENAS_IP="192.168.50.101"
TRUENAS_API_KEY="$TRUENAS_KEY"

VM_STORAGE="nvme-vm"
UBUNTU_ISO="local:iso/ubuntu-26.04-live-server-amd64.iso"

GW="192.168.50.1"
DNS="1.1.1.1"
EOF

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
# 1. TRUENAS API CHECK
# =========================
if ! done_step "truenas_api"; then
  echo "🔍 TrueNAS API kontrol ediliyor..."
  tn_get "system/info" >/tmp/truenas-info.json
  mark_step "truenas_api"
  echo "✅ TrueNAS API erişimi tamam"
fi

# =========================
# 2. TRUENAS DATASETS + NFS
# =========================
if ! done_step "truenas_datasets"; then
  echo "🧊 TrueNAS dataset/NFS hazırlanıyor..."

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
  echo "✅ TrueNAS dataset/NFS tamam"
fi

# =========================
# 3. CREATE VM FUNCTION
# =========================
create_iso_vm() {
  local ID="$1"
  local NAME="$2"
  local RAM="$3"
  local CORES="$4"
  local DISK="$5"

  if qm status "$ID" &>/dev/null; then
    echo "✅ VM $ID $NAME zaten var"
    return
  fi

  echo "🖥️ VM $ID $NAME oluşturuluyor..."

  qm create "$ID" \
    --name "$NAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --cpu host \
    --machine q35 \
    --bios ovmf \
    --scsihw virtio-scsi-single \
    --net0 virtio,bridge=vmbr0 \
    --agent enabled=1 \
    --onboot 1 \
    --balloon 0 \
    --vga virtio

  qm set "$ID" --efidisk0 "$VM_STORAGE":1,format=raw,efitype=4m
  qm set "$ID" --scsi0 "$VM_STORAGE":"$DISK",discard=on,ssd=1,iothread=1
  qm set "$ID" --ide2 "$UBUNTU_ISO",media=cdrom
  qm set "$ID" --boot order=ide2
}

# =========================
# 4. CREATE VMS
# =========================
if ! done_step "vms"; then
  echo "🖥️ Ubuntu ISO VM'leri oluşturuluyor..."

  create_iso_vm 103 docker-network 4096 2 32G
  create_iso_vm 102 docker-arr     8192 4 64G
  create_iso_vm 104 nextcloud      8192 4 64G
  create_iso_vm 105 homeassistant  4096 2 32G
  create_iso_vm 106 docker-media   24576 6 128G
  create_iso_vm 107 chia-farmer    8192 4 64G
  create_iso_vm 110 backup-server  8192 4 64G

  mark_step "vms"
  echo "✅ VM'ler hazır"
fi

# =========================
# 5. START VMS
# =========================
if ! done_step "start_vms"; then
  echo "▶️ VM'ler başlatılıyor..."

  for id in 102 103 104 105 106 107 110; do
    qm start "$id" || true
  done

  mark_step "start_vms"
  echo "✅ VM'ler başlatıldı"
fi

echo
echo "🎯 PART2 ISO CHECKPOINT TAMAMLANDI"
echo
echo "Şimdi manuel Ubuntu Server kurulumu:"
echo
echo "Her VM için Proxmox GUI > VM > Console aç."
echo
echo "Kurulumda önerilen bilgiler:"
echo
echo "VM102 docker-arr:"
echo "  IP: 192.168.50.102/24"
echo "VM103 docker-network:"
echo "  IP: 192.168.50.103/24"
echo "VM104 nextcloud:"
echo "  IP: 192.168.50.104/24"
echo "VM105 homeassistant:"
echo "  IP: 192.168.50.105/24"
echo "VM106 docker-media:"
echo "  IP: 192.168.50.106/24"
echo "VM107 chia-farmer:"
echo "  IP: 192.168.50.107/24"
echo "VM110 backup-server:"
echo "  IP: 192.168.50.110/24"
echo
echo "Gateway: 192.168.50.1"
echo "DNS: 1.1.1.1"
echo
echo "Username:"
echo "  ${BACMASTER_USER}"
echo
echo "Password:"
echo "  Part1'de verdiğin admin password"
echo
echo "Ubuntu kurulumu biten her VM için ISO çıkar:"
echo "  qm stop VMID"
echo "  qm set VMID --ide2 none"
echo "  qm set VMID --boot order=scsi0"
echo "  qm start VMID"
echo
echo "Sonra Part3 çalıştırılacak."
echo
