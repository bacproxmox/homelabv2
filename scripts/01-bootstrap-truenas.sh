mkdir -p scripts

cat > scripts/01-bootstrap-truenas.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/root/.bootstrap-state"
SECRETS_DIR="/root/.secrets"
USERS_ENV="$SECRETS_DIR/users.env"
SERVICE_FILE="/etc/systemd/system/bootstrap-truenas.service"

mkdir -p "$STATE_DIR" "$SECRETS_DIR"

step_done() { [[ -f "$STATE_DIR/$1.done" ]]; }
mark_done() { touch "$STATE_DIR/$1.done"; }

ask_secret() {
  local prompt="$1"
  local var
  read -rsp "$prompt: " var
  echo
  printf "%s" "$var"
}

echo "🚀 Part1: Proxmox + TrueNAS VM"

# =========================
# USERS ENV
# =========================
if [[ ! -f "$USERS_ENV" ]]; then
  echo "🔐 Kullanıcı bilgileri oluşturuluyor..."

  read -rp "Media user [media]: " MEDIA_USER
  MEDIA_USER="${MEDIA_USER:-media}"
  MEDIA_PASS="$(ask_secret "Media password")"

  read -rp "Admin user [bacmaster]: " BACMASTER_USER
  BACMASTER_USER="${BACMASTER_USER:-bacmaster}"
  BACMASTER_PASS="$(ask_secret "Admin password")"

  read -rp "Secondary user [tulumba]: " TULUMBA_USER
  TULUMBA_USER="${TULUMBA_USER:-tulumba}"
  TULUMBA_PASS="$(ask_secret "Secondary password")"

  read -rp "Backup user [backup]: " BACKUP_USER
  BACKUP_USER="${BACKUP_USER:-backup}"
  BACKUP_PASS="$(ask_secret "Backup password")"

cat > "$USERS_ENV" <<EOL
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
EOL

  chmod 600 "$USERS_ENV"
fi

source "$USERS_ENV"

# =========================
# SYSTEMD CONTINUE SERVICE
# =========================
if ! step_done "systemd"; then
cat > "$SERVICE_FILE" <<EOL
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
EOL

systemctl daemon-reload
systemctl enable bootstrap-truenas.service || true
mark_done "systemd"
fi

# =========================
# REPO
# =========================
if ! step_done "repo"; then
  sed -i 's/^deb/#deb/g' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true
  . /etc/os-release
  echo "deb http://download.proxmox.com/debian/pve $VERSION_CODENAME pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
  mark_done "repo"
fi

# =========================
# UPDATE
# =========================
if ! step_done "update"; then
  apt update
  apt full-upgrade -y
  mark_done "update"
fi

# =========================
# PACKAGES
# =========================
if ! step_done "packages"; then
  apt install -y curl wget nano htop iftop iotop smartmontools pciutils lshw unzip git net-tools gdisk
  mark_done "packages"
fi

# =========================
# POPUP FIX
# =========================
if ! step_done "popup"; then
  PVE_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
  if [[ -f "$PVE_JS" ]]; then
    cp "$PVE_JS" "$PVE_JS.bak.$(date +%F-%H%M%S)"
    sed -i "s/data.status !== 'Active'/false/g" "$PVE_JS"
    systemctl restart pveproxy || true
  fi
  mark_done "popup"
fi

# =========================
# LINUX USERS
# =========================
if ! step_done "users"; then
  for u in MEDIA BACMASTER TULUMBA BACKUP; do
    USER_VAR="${u}_USER"
    PASS_VAR="${u}_PASS"
    UID_VAR="${u}_UID"
    GID_VAR="${u}_GID"

    USER_NAME="${!USER_VAR}"
    USER_PASS="${!PASS_VAR}"
    USER_ID="${!UID_VAR}"
    GROUP_ID="${!GID_VAR}"

    groupadd -g "$GROUP_ID" "$USER_NAME" 2>/dev/null || true

    if ! id "$USER_NAME" &>/dev/null; then
      useradd -m -u "$USER_ID" -g "$GROUP_ID" -s /bin/bash "$USER_NAME"
    fi

    echo "$USER_NAME:$USER_PASS" | chpasswd

    if [[ "$USER_NAME" != "$MEDIA_USER" ]]; then
      usermod -aG sudo,users "$USER_NAME"
    else
      usermod -aG users "$USER_NAME"
    fi
  done

  mark_done "users"
fi

# =========================
# ISO DOWNLOAD
# =========================
if ! step_done "isos"; then
  mkdir -p /var/lib/vz/template/iso
  cd /var/lib/vz/template/iso

  wget -nc https://download.sys.truenas.net/TrueNAS-SCALE-Goldeye/25.10.3/TrueNAS-SCALE-25.10.3.iso
  wget -nc https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso || true

  mark_done "isos"
fi

# =========================
# IOMMU
# =========================
if ! step_done "iommu"; then
  if grep -q "intel_iommu=on" /proc/cmdline; then
    mark_done "iommu"
  else
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/' /etc/default/grub

    for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
      grep -qxF "$mod" /etc/modules || echo "$mod" >> /etc/modules
    done

    update-grub
    update-initramfs -u -k all
    touch "$STATE_DIR/iommu_reboot.done"

    echo "🔁 Reboot gerekiyor. Reboot sonrası otomatik devam edecek."
    sleep 5
    reboot
  fi
fi

# =========================
# NVME STORAGE
# =========================
if ! step_done "nvme"; then
  NVME="/dev/disk/by-id/nvme-XPG_SPECTRIX_S40G_2J4520139863"

  [[ -e "$NVME" ]] || { echo "NVMe bulunamadı: $NVME"; exit 1; }

  if ! zpool list nvme-vm &>/dev/null; then
    wipefs -a "$NVME" || true
    sgdisk --zap-all "$NVME" || true
    zpool create -f -o ashift=12 nvme-vm "$NVME"
    zfs set compression=lz4 nvme-vm
    zfs set atime=off nvme-vm
  fi

  if ! pvesm status | awk '{print $1}' | grep -qx "nvme-vm"; then
    pvesm add zfspool nvme-vm -pool nvme-vm -content images,rootdir
  fi

  mark_done "nvme"
fi

# =========================
# TRUENAS VM 101
# =========================
if ! step_done "truenas_vm"; then
  VMID="101"
  ISO="local:iso/TrueNAS-SCALE-25.10.3.iso"

  DISK_TANK="/dev/disk/by-id/ata-TOSHIBA_MG10ACA20TE_4580A0BSF4MJ"
  DISK_PRIVATE="/dev/disk/by-id/ata-ST4000NM0053_Z1Z5KNAT"

  [[ -e "$DISK_TANK" ]] || { echo "20TB disk yok: $DISK_TANK"; exit 1; }
  [[ -e "$DISK_PRIVATE" ]] || { echo "4TB disk yok: $DISK_PRIVATE"; exit 1; }

  if ! qm status "$VMID" &>/dev/null; then
    qm create "$VMID" \
      --name truenas \
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
fi

systemctl disable bootstrap-truenas.service >/dev/null 2>&1 || true

echo
echo "✅ PART1 tamamlandı."
echo
echo "Manuel checkpoint:"
echo "1. qm start 101"
echo "2. TrueNAS installer aç"
echo "3. OS diski olarak 64GB scsi0 seç"
echo "4. Kurulum bitince:"
echo "   qm stop 101"
echo "   qm set 101 --ide2 none"
echo "   qm set 101 --boot order=scsi0"
echo "   qm start 101"
echo
EOF

chmod +x scripts/01-bootstrap-truenas.sh
