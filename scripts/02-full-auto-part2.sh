#!/usr/bin/env bash
set -euo pipefail

export TERM=xterm

STATE_DIR="/root/.part2-iso-state"
SECRETS_DIR="/root/.secrets"
PART2_ENV="$SECRETS_DIR/part2.env"
USERS_ENV="$SECRETS_DIR/users.env"

mkdir -p "$STATE_DIR" "$SECRETS_DIR"

done_step() { [[ -f "$STATE_DIR/$1.done" ]]; }
mark_step() { touch "$STATE_DIR/$1.done"; }

ask_visible_into() {
  local __var="$1"
  local prompt="$2"
  local input=""

  while true; do
    read -r -p "$prompt: " input
    [[ -n "$input" ]] && break
    echo "Boş bırakılamaz."
  done

  printf -v "$__var" "%s" "$input"
}

echo "🚀 Part2 ISO Mode: TrueNAS API + Ubuntu ISO VM oluşturma"

[[ -f "$USERS_ENV" ]] || {
  echo "❌ $USERS_ENV yok. Önce Part1 çalışmalı."
  exit 1
}

source "$USERS_ENV"

if [[ ! -f "$PART2_ENV" ]]; then
  echo
  echo "TrueNAS API key oluşturmak için TrueNAS Shell:"
  echo "midclt call api_key.create '{\"name\":\"bacmaster-installer\",\"username\":\"truenas_admin\"}'"
  echo
  echo "⚠️ API key bu kurulum sırasında ekranda görünecek."
  ask_visible_into TRUENAS_KEY "TrueNAS API key yapıştır"

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

if ! done_step "truenas_api"; then
  echo "🔍 TrueNAS API kontrol ediliyor..."

  tn_get "system/info" >/tmp/truenas-info.json || {
    echo "❌ TrueNAS API erişimi başarısız."
    echo "rm -f $PART2_ENV ile API key'i sıfırlayabilirsin."
    exit 1
  }

  if grep -qi "authentication" /tmp/truenas-info.json || grep -qi "unauthorized" /tmp/truenas-info.json; then
    echo "❌ TrueNAS API key hatalı görünüyor."
    echo "Düzeltmek için:"
    echo "rm -f $PART2_ENV"
    echo "bash install.sh"
    echo "seçim: 2"
    exit 1
  fi

  mark_step "truenas_api"
  echo "✅ TrueNAS API erişimi tamam"
fi

if ! done_step "truenas_datasets"; then
  echo "🧊 TrueNAS dataset/NFS hazırlanıyor..."

  echo "👤 TrueNAS media user hazırlanıyor..."

  tn_post "user" "{
    \"username\": \"${MEDIA_USER}\",
    \"full_name\": \"Media User\",
    \"group_create\": true,
    \"uid\": ${MEDIA_UID},
    \"password\": \"${MEDIA_PASS}\",
    \"smb\": false
  }" >/dev/null || true

  echo "📦 Ana datasetler oluşturuluyor..."

  # DİKKAT:
  # tank/media altındaki downloads/movies/series/music dataset OLMAYACAK.
  # Bunlar normal klasör olacak.
  # Sebep: Alt datasetler ACL inheritance/write problemi çıkarıyor.
  for ds in \
    "tank/media" \
    "tank/photos" \
    "tank/temp" \
    "private/documents" \
    "private/photos" \
    "private/timemachine"
  do
    tn_post "pool/dataset" "{\"name\": \"${ds}\", \"share_type\": \"GENERIC\"}" >/dev/null || true
  done

  echo "📁 Media alt klasörleri normal klasör olarak oluşturuluyor..."

  tn_post "filesystem/mkdir" "{\"path\": \"/mnt/tank/media/downloads\"}" >/dev/null || true
  tn_post "filesystem/mkdir" "{\"path\": \"/mnt/tank/media/downloads/torrents\"}" >/dev/null || true
  tn_post "filesystem/mkdir" "{\"path\": \"/mnt/tank/media/downloads/usenet\"}" >/dev/null || true
  tn_post "filesystem/mkdir" "{\"path\": \"/mnt/tank/media/downloads/sonarr\"}" >/dev/null || true
  tn_post "filesystem/mkdir" "{\"path\": \"/mnt/tank/media/downloads/radarr\"}" >/dev/null || true
  tn_post "filesystem/mkdir" "{\"path\": \"/mnt/tank/media/movies\"}" >/dev/null || true
  tn_post "filesystem/mkdir" "{\"path\": \"/mnt/tank/media/series\"}" >/dev/null || true
  tn_post "filesystem/mkdir" "{\"path\": \"/mnt/tank/media/music\"}" >/dev/null || true

  echo "🔐 Dataset ownership/ACL hazırlanıyor..."

  tn_post "filesystem/chown" "{
    \"path\": \"/mnt/tank/media\",
    \"uid\": ${MEDIA_UID},
    \"gid\": ${MEDIA_GID},
    \"options\": {
      \"recursive\": true,
      \"traverse\": true
    }
  }" >/dev/null || true

  echo "📡 NFS share oluşturuluyor/güncelleniyor..."

  EXISTING_NFS_ID="$(tn_get "sharing/nfs" | grep -oE '"id":[0-9]+|"paths":\["/mnt/tank/media"\]' | awk '
    /"id":/ {id=$0; gsub(/[^0-9]/,"",id)}
    /"paths":/ {print id}
  ' | head -n1)"

  NFS_PAYLOAD="{
    \"paths\": [\"/mnt/tank/media\"],
    \"comment\": \"tank media NFS\",
    \"enabled\": true,
    \"networks\": [\"192.168.50.0/24\"],
    \"mapall_user\": \"${MEDIA_USER}\",
    \"mapall_group\": \"${MEDIA_USER}\",
    \"ro\": false
  }"

  if [[ -n "${EXISTING_NFS_ID:-}" ]]; then
    tn_put "sharing/nfs/id/${EXISTING_NFS_ID}" "$NFS_PAYLOAD" >/dev/null || true
  else
    tn_post "sharing/nfs" "$NFS_PAYLOAD" >/dev/null || true
  fi

  tn_put "service/id/nfs" "{\"enable\": true}" >/dev/null || true
  tn_post "service/start" "{\"service\": \"nfs\"}" >/dev/null || true
  tn_post "service/restart" "{\"service\": \"nfs\"}" >/dev/null || true

  mark_step "truenas_datasets"
  echo "✅ TrueNAS dataset/NFS tamam"
fi

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

  DISK_SIZE="${DISK%G}"

  qm set "$ID" --efidisk0 "$VM_STORAGE":1,format=raw,efitype=4m
  qm set "$ID" --scsi0 "${VM_STORAGE}:${DISK_SIZE}",discard=on,ssd=1,iothread=1
  qm set "$ID" --ide2 "$UBUNTU_ISO",media=cdrom
  qm set "$ID" --boot order=ide2
}

find_pci_by_regex() {
  local regex="$1"
  lspci -Dnn | grep -Ei "$regex" | awk '{print $1}' | head -n1 || true
}

find_all_pci_by_regex() {
  local regex="$1"
  lspci -Dnn | grep -Ei "$regex" | awk '{print $1}' || true
}

pci_short() {
  echo "$1" | sed 's/^0000://'
}

add_hostpci() {
  local vmid="$1"
  local index="$2"
  local pci="$3"
  local opts="$4"

  [[ -n "$pci" ]] || return 0

  pci="$(pci_short "$pci")"

  echo "🎮 VM $vmid hostpci$index ekleniyor: $pci,$opts"
  qm set "$vmid" -hostpci"$index" "$pci,$opts" || true
}

add_vm106_igpu_passthrough() {
  local igpu

  echo "🎬 VM106 Intel iGPU aranıyor..."

  igpu="$(find_pci_by_regex 'Intel Corporation.*Raptor Lake.*UHD Graphics|Intel Corporation.*UHD Graphics|Intel Corporation.*VGA.*Raptor Lake|00:02.0.*Intel')"

  if [[ -z "$igpu" ]]; then
    echo "⚠️ Intel iGPU bulunamadı, VM106 passthrough atlandı"
    return 0
  fi

  # Jellyfin/Immich hardware acceleration için Primary GPU gerekmez.
  add_hostpci 106 0 "$igpu" "pcie=1,x-vga=0,rombar=1"
}

add_vm107_chia_passthrough() {
  local gpu=""
  local audio=""
  local base=""
  local idx=0
  local sata_list=()

  echo "🎮 VM107 RTX 3060 / NVIDIA GPU aranıyor..."

  gpu="$(find_pci_by_regex 'NVIDIA.*RTX 3060|NVIDIA.*GA106.*RTX 3060|NVIDIA.*VGA|NVIDIA.*3D')"

  if [[ -n "$gpu" ]]; then
    base="$(echo "$gpu" | sed -E 's/\.[0-9]$//')"

    audio="$(lspci -Dnn | grep -Ei "${base}\.1.*NVIDIA.*Audio|${base}\.1.*High Definition Audio" | awk '{print $1}' | head -n1 || true)"

    # Chia CUDA compute için Primary GPU gerekmez.
    # Proxmox GUI karşılığı:
    # PCI-Express: ON
    # Primary GPU: OFF
    # ROM-Bar: ON
    add_hostpci 107 "$idx" "$gpu" "pcie=1,x-vga=0,rombar=1"
    idx=$((idx + 1))

    if [[ -n "$audio" ]]; then
      add_hostpci 107 "$idx" "$audio" "pcie=1,rombar=1"
      idx=$((idx + 1))
    fi
  else
    echo "⚠️ RTX 3060 / NVIDIA GPU bulunamadı, VM107 GPU passthrough atlandı"
  fi

  echo "🔎 VM107 için JMicron JMB58x AHCI SATA controller aranıyor..."

  mapfile -t sata_list < <(find_all_pci_by_regex 'JMicron.*JMB58.*AHCI|JMicron.*AHCI SATA|JMB58x.*AHCI SATA|JMicron Technology.*JMB58.*SATA')

  if [[ "${#sata_list[@]}" -eq 0 ]]; then
    echo "⚠️ JMicron JMB58x SATA controller bulunamadı"
  fi

  for sata in "${sata_list[@]}"; do
    add_hostpci 107 "$idx" "$sata" "pcie=1,rombar=1"
    idx=$((idx + 1))
  done
}

if ! done_step "vms"; then
  echo "🖥️ Ubuntu ISO VM'leri oluşturuluyor..."

  create_iso_vm 103 docker-network 4096 2 32G
  create_iso_vm 102 docker-arr     8192 4 64G
  create_iso_vm 104 nextcloud      8192 4 64G
  create_iso_vm 105 homeassistant  4096 2 32G
  create_iso_vm 106 docker-media   24576 6 128G
  create_iso_vm 107 chia-farmer    8192 4 64G
  create_iso_vm 110 backup-server  8192 4 64G

  echo "🎮 GPU / SATA passthrough ayarları uygulanıyor..."

  add_vm106_igpu_passthrough
  add_vm107_chia_passthrough

  mark_step "vms"
  echo "✅ VM'ler hazır"
fi

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
echo "Şimdi her VM için manuel Ubuntu Server kurulumu yap:"
echo
echo "VM102 docker-arr      IP: 192.168.50.102/24"
echo "VM103 docker-network  IP: 192.168.50.103/24"
echo "VM104 nextcloud       IP: 192.168.50.104/24"
echo "VM105 homeassistant   IP: 192.168.50.105/24"
echo "VM106 docker-media    IP: 192.168.50.106/24"
echo "VM107 chia-farmer     IP: 192.168.50.107/24"
echo "VM110 backup-server   IP: 192.168.50.110/24"
echo
echo "Gateway: 192.168.50.1"
echo "DNS: 1.1.1.1"
echo "Username: ${BACMASTER_USER}"
echo "Password: Part1'de verdiğin admin password"
echo
echo "Her Ubuntu kurulumu bitince ilgili VM için:"
echo "qm stop VMID"
echo "qm set VMID --ide2 none"
echo "qm set VMID --boot order=scsi0"
echo "qm start VMID"
echo
echo "Tüm VM'ler kurulduktan sonra Part3:"
echo "cd /root/homelab && bash install.sh"
echo "seçim: 3"
echo
