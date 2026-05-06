#!/usr/bin/env bash
set -euo pipefail

export TERM=xterm

STATE_DIR="/root/.bootstrap-state"
SECRETS_DIR="/root/.secrets"
USERS_ENV="$SECRETS_DIR/users.env"
SERVICE_FILE="/etc/systemd/system/bootstrap-truenas.service"

mkdir -p "$STATE_DIR" "$SECRETS_DIR"

step_done() {
  [[ -f "$STATE_DIR/$1.done" ]]
}

mark_done() {
  touch "$STATE_DIR/$1.done"
}

iommu_is_active() {
  [[ -d /sys/kernel/iommu_groups ]] && \
  [[ "$(find /sys/kernel/iommu_groups -type l | wc -l)" -gt 0 ]]
}

ask_text() {
  local prompt="$1"
  local default="$2"
  local var=""

  printf "%s [%s]: " "$prompt" "$default"
  read -r var
  var="${var:-$default}"

  printf "%s" "$var"
}

ask_secret() {
  local prompt="$1"
  local var=""

  while true; do
    printf "%s: " "$prompt"

    stty -echo || true
    read -r var
    stty echo || true
    echo

    if [[ -n "$var" ]]; then
      break
    fi

    echo "Boş bırakılamaz."
  done

  printf "%s" "$var"
}

echo
echo "🚀 PART1 - Proxmox + TrueNAS VM hazırlığı başlıyor / devam ediyor..."
echo

# =========================
# USERS ENV WIZARD
# =========================
if [[ ! -f "$USERS_ENV" ]]; then
  echo "🔐 Kullanıcı bilgileri oluşturuluyor..."
  echo

  MEDIA_USER="$(ask_text "Media user" "media")"
  MEDIA_PASS="$(ask_secret "Media password")"

  BACMASTER_USER="$(ask_text "Admin user" "bacmaster")"
  BACMASTER_PASS="$(ask_secret "Admin password")"

  TULUMBA_USER="$(ask_text "Secondary user" "tulumba")"
  TULUMBA_PASS="$(ask_secret "Secondary password")"

  BACKUP_USER="$(ask_text "Backup user" "backup")"
  BACKUP_PASS="$(ask_secret "Backup password")"

  cat > "$USERS_ENV" <<EOF
MEDIA_USER="$MEDIA_USER"
MEDIA_PASS="$MEDIA_PASS"
MEDIA_UID=1000
MEDIA_GID=1000

BACMASTER_USER="$BACMASTER_USER"
BACMASTER_PASS="$BACMASTER_PASS"
BACMASTER_UID=1100
BACMASTER_GID=1100

TULUMBA_USER="$TULUMBA_USER"
TULUMBA_PASS="$TULUMBA_PASS"
TULUMBA_UID=1200
TULUMBA_GID=1200

BACKUP_USER="$BACKUP_USER"
BACKUP_PASS="$BACKUP_PASS"
BACKUP_UID=1300
BACKUP_GID=1300
EOF

  chmod 600 "$USERS_ENV"
  echo "✅ users.env oluşturuldu: $USERS_ENV"
fi

source "$USERS_ENV"

echo "🔎 Kullanıcı bilgileri kontrol ediliyor..."

for var in \
  MEDIA_USER MEDIA_PASS MEDIA_UID MEDIA_GID \
  BACMASTER_USER BACMASTER_PASS BACMASTER_UID BACMASTER_GID \
  TULUMBA_USER TULUMBA_PASS TULUMBA_UID TULUMBA_GID \
  BACKUP_USER BACKUP_PASS BACKUP_UID BACKUP_GID
do
  if [[ -z "${!var:-}" ]]; then
    echo "❌ Eksik değişken: $var"
    echo "Dosyayı kontrol et: $USERS_ENV"
    exit 1
  fi
done

echo "✅ Kullanıcı bilgileri tamam"

# =========================
# REBOOT CONTINUE SERVICE
# =========================
if ! step_done "systemd"; then
  echo "🔁 Reboot sonrası devam servisi hazırlanıyor..."

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Bacmaster Bootstrap TrueNAS Installer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/homelab/scripts/01-bootstrap-truenas.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable bootstrap-truenas.service || true

  mark_done "systemd"
  echo "✅ Reboot devam servisi hazır"
fi

# =========================
# BASIC PACKAGES
# =========================
if ! step_done "packages"; then
  echo "📦 Temel paketler kuruluyor..."

  apt update
  apt install -y \
    curl \
    wget \
    nano \
    htop \
    iftop \
    iotop \
    smartmontools \
    pciutils \
    lshw \
    unzip \
    git \
    net-tools \
    gdisk \
    qemu-guest-agent

  mark_done "packages"
  echo "✅ Temel paketler hazır"
fi

# =========================
# NO SUBSCRIPTION POPUP FIX
# =========================
if ! step_done "popup"; then
  echo "🔕 No-subscription popup kapatılıyor..."

  PVE_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

  if [[ -f "$PVE_JS" ]]; then
    cp "$PVE_JS" "$PVE_JS.bak.$(date +%F-%H%M%S)"
    sed -i "s/data.status !== 'Active'/false/g" "$PVE_JS" || true
    systemctl restart pveproxy || true
  else
    echo "⚠️ proxmoxlib.js bulunamadı, popup fix atlandı"
  fi

  mark_done "popup"
  echo "✅ Popup fix tamam"
fi

# =========================
# LINUX USERS - FIXED GROUP LOGIC
# =========================
if ! step_done "users"; then
  echo "👤 Linux kullanıcıları oluşturuluyor..."

  for u in MEDIA BACMASTER TULUMBA BACKUP; do
    USER_VAR="${u}_USER"
    PASS_VAR="${u}_PASS"
    UID_VAR="${u}_UID"
    GID_VAR="${u}_GID"

    USER_NAME="${!USER_VAR}"
    USER_PASS="${!PASS_VAR}"
    USER_ID="${!UID_VAR}"
    GROUP_ID="${!GID_VAR}"

    echo "➡️ Kullanıcı hazırlanıyor: $USER_NAME UID=$USER_ID GID=$GROUP_ID"

    # UID başka kullanıcıda varsa dur
    if getent passwd "$USER_ID" >/dev/null; then
      EXISTING_USER="$(getent passwd "$USER_ID" | cut -d: -f1)"
      if [[ "$EXISTING_USER" != "$USER_NAME" ]]; then
        echo "❌ UID $USER_ID zaten başka kullanıcıda: $EXISTING_USER"
        echo "Temiz kurulumda bu olmamalı. Kullanıcı/UID çakışması var."
        exit 1
      fi
    fi

    # GID varsa onu kullan; yoksa kullanıcı adıyla grup oluştur
    if getent group "$GROUP_ID" >/dev/null; then
      EXISTING_GROUP="$(getent group "$GROUP_ID" | cut -d: -f1)"
      echo "⚠️ GID $GROUP_ID zaten var: $EXISTING_GROUP"
      PRIMARY_GROUP="$EXISTING_GROUP"
    else
      if getent group "$USER_NAME" >/dev/null; then
        PRIMARY_GROUP="$USER_NAME"
      else
        groupadd -g "$GROUP_ID" "$USER_NAME"
        PRIMARY_GROUP="$USER_NAME"
      fi
    fi

    # Kullanıcı yoksa oluştur
    if ! id "$USER_NAME" &>/dev/null; then
      useradd -m -u "$USER_ID" -g "$PRIMARY_GROUP" -s /bin/bash "$USER_NAME"
    else
      echo "✅ Kullanıcı zaten var: $USER_NAME"
    fi

    echo "$USER_NAME:$USER_PASS" | chpasswd

    if [[ "$USER_NAME" != "$MEDIA_USER" ]]; then
      usermod -aG sudo,users "$USER_NAME"
    else
      usermod -aG users "$USER_NAME"
    fi
  done

  mark_done "users"
  echo "✅ Linux kullanıcıları hazır"
fi

# =========================
# ISO DOWNLOAD
# =========================
if ! step_done "isos"; then
  echo "📀 ISO dosyaları indiriliyor..."

  mkdir -p /var/lib/vz/template/iso
  cd /var/lib/vz/template/iso

  wget -nc https://download.sys.truenas.net/TrueNAS-SCALE-Goldeye/25.10.3/TrueNAS-SCALE-25.10.3.iso
  wget -nc https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso || true

  mark_done "isos"
  echo "✅ ISO dosyaları hazır"
fi

# =========================
# IOMMU ENABLE / VERIFY
# =========================
if ! step_done "iommu"; then
  echo "🧠 IOMMU kontrol ediliyor..."

  if iommu_is_active; then
    echo "✅ IOMMU zaten aktif"
    mark_done "iommu"
  else
    echo "⚙️ IOMMU aktif ediliyor..."

    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
      sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/' /etc/default/grub
    else
      echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"' >> /etc/default/grub
    fi

    for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
      grep -qxF "$mod" /etc/modules || echo "$mod" >> /etc/modules
    done

    update-grub
    update-initramfs -u -k all

    touch "$STATE_DIR/iommu_reboot_requested.done"

    echo
    echo "🔁 IOMMU için reboot gerekiyor."
    echo "✅ Reboot sonrası script otomatik devam edecek."
    sleep 5
    reboot
  fi
fi

if step_done "iommu_reboot_requested" && ! step_done "iommu_verified"; then
  echo "🔍 Reboot sonrası IOMMU doğrulanıyor..."

  if iommu_is_active; then
    mark_done "iommu_verified"
    mark_done "iommu"
    echo "✅ IOMMU aktif görünüyor"
  else
    echo "❌ IOMMU aktif görünmüyor."
    echo "Manuel kontrol:"
    echo "cat /proc/cmdline"
    echo "dmesg | grep -Ei 'DMAR|IOMMU|VT-d'"
    echo "find /sys/kernel/iommu_groups/ -type l | head"
    exit 1
  fi
fi

# =========================
# NVME STORAGE: nvme-vm
# =========================
if ! step_done "nvme"; then
  echo "💾 NVMe storage hazırlanıyor..."

  NVME="/dev/disk/by-id/nvme-XPG_SPECTRIX_S40G_2J4520139863"

  if [[ ! -e "$NVME" ]]; then
    echo "❌ NVMe bulunamadı: $NVME"
    echo "Diskleri kontrol et:"
    echo "ls -l /dev/disk/by-id/"
    exit 1
  fi

  if ! zpool list nvme-vm &>/dev/null; then
    echo "⚠️ NVMe temizlenecek ve ZFS pool oluşturulacak: nvme-vm"
    echo "Disk: $NVME"

    wipefs -a "$NVME" || true
    sgdisk --zap-all "$NVME" || true

    zpool create -f -o ashift=12 nvme-vm "$NVME"
    zfs set compression=lz4 nvme-vm
    zfs set atime=off nvme-vm
  else
    echo "✅ ZFS pool zaten var: nvme-vm"
  fi

  if ! pvesm status | awk '{print $1}' | grep -qx "nvme-vm"; then
    pvesm add zfspool nvme-vm -pool nvme-vm -content images,rootdir
  else
    echo "✅ Proxmox storage zaten var: nvme-vm"
  fi

  mark_done "nvme"
  echo "✅ NVMe storage hazır"
fi

# =========================
# TRUENAS VM 101
# =========================
if ! step_done "truenas_vm"; then
  echo "🧊 TrueNAS VM 101 oluşturuluyor..."

  VMID="101"
  VMNAME="truenas"
  ISO="local:iso/TrueNAS-SCALE-25.10.3.iso"

  DISK_TANK="/dev/disk/by-id/ata-TOSHIBA_MG10ACA20TE_4580A0BSF4MJ"
  DISK_PRIVATE="/dev/disk/by-id/ata-ST4000NM0053_Z1Z5KNAT"

  if [[ ! -e "$DISK_TANK" ]]; then
    echo "❌ 20TB tank disk bulunamadı: $DISK_TANK"
    exit 1
  fi

  if [[ ! -e "$DISK_PRIVATE" ]]; then
    echo "❌ 4TB private disk bulunamadı: $DISK_PRIVATE"
    exit 1
  fi

  if qm status "$VMID" &>/dev/null; then
    echo "✅ VM $VMID zaten var, oluşturma atlandı"
  else
    qm create "$VMID" \
      --name "$VMNAME" \
      --memory 32768 \
      --cores 4 \
      --cpu host \
      --machine q35 \
      --bios ovmf \
      --scsihw virtio-scsi-single \
      --net0 virtio,bridge=vmbr0 \
      --onboot 1 \
      --balloon 0 \
      --vga vmware

    qm set "$VMID" --efidisk0 nvme-vm:1,format=raw,efitype=4m
    qm set "$VMID" --scsi0 nvme-vm:64,discard=on,ssd=1,iothread=1
    qm set "$VMID" --ide2 "$ISO",media=cdrom
    qm set "$VMID" --boot order=ide2

    qm set "$VMID" --scsi1 "$DISK_TANK",serial=TANK20TB
    qm set "$VMID" --scsi2 "$DISK_PRIVATE",serial=PRIVATE4TB
  fi

  mark_done "truenas_vm"

  echo
  echo "✅ TrueNAS VM 101 config:"
  qm config "$VMID"
fi

systemctl disable bootstrap-truenas.service >/dev/null 2>&1 || true

echo
echo "🎯 PART1 CHECKPOINT TAMAMLANDI"
echo
echo "Manuel adımlar:"
echo "1. qm start 101"
echo "2. Proxmox GUI > VM 101 > Console"
echo "3. TrueNAS installer içinde SADECE 64GB scsi0 OS diskini seç"
echo "4. Kurulum bitince:"
echo "   qm stop 101"
echo "   qm set 101 --ide2 none"
echo "   qm set 101 --boot order=scsi0"
echo "   qm start 101"
echo "5. TrueNAS içinde:"
echo "   - IP: 192.168.50.101"
echo "   - pool: tank"
echo "   - pool: private"
echo "   - API key oluştur"
echo "6. Sonra Part2:"
echo "   cd /root/homelab && bash install.sh"
echo "   seçim: 2"
echo
