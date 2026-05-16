#!/bin/bash
# =============================================================================
# Arch Linux Automated Installer — KDE Plasma 6 + NVIDIA + AUR
# =============================================================================
# ✅ KDE Plasma 6
# ✅ NVIDIA RTX (DKMS)
# ✅ yay AUR helper
# ✅ EWW + Rofi
# ✅ SDDM fallback
# ✅ Dual-boot ready
# ✅ NVMe/SATA safe
# ✅ Auto mirror optimization
# ✅ Stable AUR/Git handling
# ✅ Extra disks auto-mount
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Colors & logging
# -----------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[⚠]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

trap 'error "Installer failed on line $LINENO"' ERR

# -----------------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || error "Run as root."

ping -c 2 archlinux.org &>/dev/null || error "No internet connection."

[[ -d /sys/firmware/efi ]] || error "System must be booted in UEFI mode."

# -----------------------------------------------------------------------------
# Disk selector
# -----------------------------------------------------------------------------

select_disk() {
    local prompt="$1"
    local exclude="${2:-}"

    local disks=()
    local i=1

    echo -e "\n$prompt"
    echo "────────────────────────────────────────────"

    while read -r line; do
        local name size model

        name=$(awk '{print $1}' <<< "$line")
        size=$(awk '{print $2}' <<< "$line")

        [[ "$name" =~ ^(loop|sr|ram|zram)$ ]] && continue
        [[ -n "$exclude" && "$name" == "$exclude" ]] && continue

        model=$(lsblk -d -o MODEL -n "/dev/$name" 2>/dev/null | xargs)

        disks+=("/dev/$name")

        printf " %d) %-12s %-10s %s\n" \
            "$i" "/dev/$name" "$size" "$model"

        ((i++))

    done < <(lsblk -d -o NAME,SIZE -n)

    echo "────────────────────────────────────────────"

    [[ ${#disks[@]} -eq 0 ]] && error "No disks found."

    while true; do
        read -rp "Choose disk [1-${#disks[@]}]: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( choice >= 1 && choice <= ${#disks[@]} ))
        then
            echo "${disks[$((choice-1))]}"
            return
        fi

        warn "Invalid selection."
    done
}

# -----------------------------------------------------------------------------
# Partition helper
# -----------------------------------------------------------------------------

get_partition() {
    local disk="$1"
    local num="$2"

    if [[ "$disk" =~ nvme ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------

clear

cat << "EOF"
╔════════════════════════════════════════════╗
║        Arch Linux Installer — KDE 6       ║
║                                            ║
║   ✅ NVIDIA RTX 3060                      ║
║   ✅ EWW + Rofi                           ║
║   ✅ AUR Support                          ║
║   ✅ Dual Boot Ready                      ║
╚════════════════════════════════════════════╝
EOF

# -----------------------------------------------------------------------------
# User input
# -----------------------------------------------------------------------------

read -rp "Username: " username

[[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] \
    || error "Invalid username."

read -rsp "Password: " pass1
echo

read -rsp "Confirm password: " pass2
echo

[[ "$pass1" == "$pass2" ]] \
    || error "Passwords do not match."

read -rp "Hostname [arch-kde]: " hostname
hostname="${hostname:-arch-kde}"

# -----------------------------------------------------------------------------
# Disk selection
# -----------------------------------------------------------------------------

echo

warn "WARNING: ALL DATA ON THE SYSTEM DISK WILL BE ERASED."

system_disk=$(select_disk "Select installation disk:")

success "Selected: $system_disk"

extra_disks=()

echo
warn "Optional additional disks will be formatted and mounted."

while true; do

    [[ ${#extra_disks[@]} -gt 0 ]] &&
        echo "Added: ${extra_disks[*]}"

    read -rp "Add extra disk or press Enter: " disk

    [[ -z "$disk" ]] && break

    [[ ! -b "$disk" ]] && {
        warn "Disk not found."
        continue
    }

    [[ "$disk" == "$system_disk" ]] && {
        warn "System disk already selected."
        continue
    }

    extra_disks+=("$disk")

done

# -----------------------------------------------------------------------------
# Confirm
# -----------------------------------------------------------------------------

echo
warn "INSTALLATION SUMMARY"
echo " System disk: $system_disk"
echo " Hostname:    $hostname"
echo " Username:    $username"

[[ ${#extra_disks[@]} -gt 0 ]] &&
    echo " Extra disks: ${extra_disks[*]}"

echo

read -rp "Continue? [yes/y]: " confirm

[[ "$confirm" =~ ^(yes|y)$ ]] \
    || error "Installation aborted."

# -----------------------------------------------------------------------------
# Time sync
# -----------------------------------------------------------------------------

log "Synchronizing time..."

timedatectl set-ntp true

# -----------------------------------------------------------------------------
# Mirrors
# -----------------------------------------------------------------------------

log "Optimizing mirrors..."

pacman -Sy --noconfirm reflector

reflector \
    --latest 20 \
    --protocol https \
    --sort rate \
    --save /etc/pacman.d/mirrorlist

# -----------------------------------------------------------------------------
# Partitioning
# -----------------------------------------------------------------------------

log "Partitioning disk..."

wipefs -af "$system_disk"

parted -s "$system_disk" mklabel gpt

parted -s "$system_disk" mkpart ESP fat32 1MiB 513MiB
parted -s "$system_disk" set 1 esp on

parted -s "$system_disk" mkpart ROOT ext4 513MiB 100%

partprobe "$system_disk"
udevadm settle

sleep 2

boot_part=$(get_partition "$system_disk" 1)
root_part=$(get_partition "$system_disk" 2)

success "EFI : $boot_part"
success "ROOT: $root_part"

# -----------------------------------------------------------------------------
# Wait for partitions
# -----------------------------------------------------------------------------

for part in "$boot_part" "$root_part"; do

    for ((i=0; i<15; i++)); do
        [[ -b "$part" ]] && break
        sleep 1
    done

    [[ -b "$part" ]] || error "Partition $part not found."

done

# -----------------------------------------------------------------------------
# Formatting
# -----------------------------------------------------------------------------

log "Formatting partitions..."

mkfs.fat -F32 "$boot_part"
mkfs.ext4 -F "$root_part"

# -----------------------------------------------------------------------------
# Mount
# -----------------------------------------------------------------------------

mount "$root_part" /mnt

mkdir -p /mnt/boot

mount "$boot_part" /mnt/boot

# -----------------------------------------------------------------------------
# Pacstrap
# -----------------------------------------------------------------------------

log "Installing base system..."

pacstrap -K /mnt \
    base \
    base-devel \
    linux \
    linux-firmware \
    linux-headers \
    sudo \
    vim \
    nano \
    git \
    curl \
    wget \
    rsync \
    networkmanager \
    grub \
    efibootmgr \
    os-prober \
    reflector \
    intel-ucode \
    amd-ucode

genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------------------------------------------------------------
# Export vars
# -----------------------------------------------------------------------------

export USERNAME="$username"
export USERPASS="$pass1"
export HOSTNAME="$hostname"

# -----------------------------------------------------------------------------
# CHROOT
# -----------------------------------------------------------------------------

log "Entering chroot..."

arch-chroot /mnt /bin/bash << 'CHROOT_EOF'

set -Eeuo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[⚠]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

trap 'error "Chroot failed on line $LINENO"' ERR

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

USERNAME="${USERNAME}"
USERPASS="${USERPASS}"
HOSTNAME="${HOSTNAME}"

# -----------------------------------------------------------------------------
# Timezone & locale
# -----------------------------------------------------------------------------

ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime

hwclock --systohc

sed -i \
's/^#\(en_US.UTF-8\)/\1/;
 s/^#\(ru_RU.UTF-8\)/\1/' \
/etc/locale.gen

locale-gen

echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# -----------------------------------------------------------------------------
# Hostname
# -----------------------------------------------------------------------------

echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF

# -----------------------------------------------------------------------------
# Users
# -----------------------------------------------------------------------------

useradd -m -G wheel,audio,video,storage -s /bin/bash "$USERNAME"

echo "$USERNAME:$USERPASS" | chpasswd

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

chmod 440 /etc/sudoers.d/wheel

# -----------------------------------------------------------------------------
# Pacman config
# -----------------------------------------------------------------------------

sed -i \
'/^\s*#\s*\[multilib\]/,/^\s*#Include/s/^#//' \
/etc/pacman.conf

pacman -Sy --noconfirm

# -----------------------------------------------------------------------------
# Certificates
# -----------------------------------------------------------------------------

log "Updating certificates..."

pacman -S --noconfirm \
    ca-certificates \
    ca-certificates-utils \
    ca-certificates-mozilla

update-ca-trust

# -----------------------------------------------------------------------------
# KDE Plasma
# -----------------------------------------------------------------------------

log "Installing KDE Plasma..."

pacman -S --noconfirm \
    plasma-meta \
    kde-applications \
    xorg \
    xorg-server \
    xorg-xinit \
    sddm \
    discover \
    packagekit-qt6 \
    dolphin \
    konsole \
    ark \
    kate \
    rofi

# -----------------------------------------------------------------------------
# NVIDIA
# -----------------------------------------------------------------------------

log "Installing NVIDIA drivers..."

pacman -S --noconfirm \
    dkms \
    nvidia-dkms \
    nvidia-utils \
    nvidia-settings \
    lib32-nvidia-utils

sed -i \
's/^MODULES=()/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
/etc/mkinitcpio.conf

mkinitcpio -P

# -----------------------------------------------------------------------------
# Applications
# -----------------------------------------------------------------------------

log "Installing applications..."

pacman -S --noconfirm \
    code \
    pycharm-community-edition \
    intellij-idea-community-edition \
    steam \
    vlc \
    qbittorrent \
    syncthing \
    texstudio \
    noto-fonts \
    noto-fonts-cjk \
    noto-fonts-emoji \
    ttf-dejavu \
    ttf-liberation \
    bluez \
    bluez-utils \
    go \
    rust

# -----------------------------------------------------------------------------
# Git fixes
# -----------------------------------------------------------------------------

log "Fixing Git HTTP issues..."

git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000

# -----------------------------------------------------------------------------
# yay install
# -----------------------------------------------------------------------------

log "Installing yay..."

echo "%wheel ALL=(ALL) NOPASSWD: /usr/bin/pacman, /usr/bin/makepkg" \
> /etc/sudoers.d/temp-aur

chmod 440 /etc/sudoers.d/temp-aur

su - "$USERNAME" -c '
set -e

rm -rf /tmp/yay

for i in 1 2 3 4 5
do
    echo "Attempt $i..."

    if git clone https://aur.archlinux.org/yay.git /tmp/yay
    then
        cd /tmp/yay
        makepkg -si --noconfirm
        exit 0
    fi

    rm -rf /tmp/yay
    sleep 5
done

exit 1
'

rm -f /etc/sudoers.d/temp-aur

# -----------------------------------------------------------------------------
# AUR packages
# -----------------------------------------------------------------------------

log "Installing AUR packages..."

su - "$USERNAME" -c "
yay -S --noconfirm \
    eww \
    brave-bin \
    obsidian \
    android-studio
"

# -----------------------------------------------------------------------------
# Services
# -----------------------------------------------------------------------------

systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable sddm

# -----------------------------------------------------------------------------
# Bluetooth
# -----------------------------------------------------------------------------

sed -i \
's/^#AutoEnable=false/AutoEnable=true/' \
/etc/bluetooth/main.conf

# -----------------------------------------------------------------------------
# Keyboard
# -----------------------------------------------------------------------------

mkdir -p /etc/X11/xorg.conf.d

cat > /etc/X11/xorg.conf.d/00-keyboard.conf << EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us,ru"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
EOF

# -----------------------------------------------------------------------------
# GRUB
# -----------------------------------------------------------------------------

log "Installing GRUB..."

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=GRUB \
    --recheck

grep -q "GRUB_DISABLE_OS_PROBER" /etc/default/grub \
|| echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub

os-prober || true

grub-mkconfig -o /boot/grub/grub.cfg

# -----------------------------------------------------------------------------
# GRUB theme
# -----------------------------------------------------------------------------

log "Installing GRUB theme..."

if git clone --depth=1 \
https://github.com/vinceliuice/grub2-themes.git \
/tmp/grub-themes
then

    cd /tmp/grub-themes

    chmod +x install.sh

    ./install.sh -t tela -s 1080p || true

    grub-mkconfig -o /boot/grub/grub.cfg

    rm -rf /tmp/grub-themes

fi

# -----------------------------------------------------------------------------
# Finish
# -----------------------------------------------------------------------------

success "Chroot configuration completed."

CHROOT_EOF

# -----------------------------------------------------------------------------
# Extra disks
# -----------------------------------------------------------------------------

if [[ ${#extra_disks[@]} -gt 0 ]]; then

    log "Configuring additional disks..."

    idx=1

    for disk in "${extra_disks[@]}"; do

        wipefs -af "$disk"

        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart primary ext4 1MiB 100%

        partprobe "$disk"
        sleep 2

        part=$(get_partition "$disk" 1)

        mkfs.ext4 -F "$part"

        UUID=$(blkid -s UUID -o value "$part")

        mount_point="/storage$idx"

        mkdir -p "/mnt$mount_point"

        echo \
"UUID=$UUID $mount_point ext4 defaults,noatime 0 2" \
>> /mnt/etc/fstab

        success "$disk mounted as $mount_point"

        ((idx++))

    done

fi

# -----------------------------------------------------------------------------
# Unmount
# -----------------------------------------------------------------------------

log "Unmounting..."

umount -R /mnt

# -----------------------------------------------------------------------------
# Finish
# -----------------------------------------------------------------------------

cat << EOF

╔════════════════════════════════════════════╗
║         🎉 INSTALLATION COMPLETE           ║
╚════════════════════════════════════════════╝

After reboot:

 • KDE Plasma 6
 • NVIDIA drivers
 • yay
 • EWW
 • Rofi
 • Brave
 • Android Studio
 • Obsidian

are fully installed.

Reboot now:
    reboot

EOF