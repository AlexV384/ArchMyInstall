#!/bin/bash
# Arch Linux Automated Installer — KDE Plasma 6, NVIDIA RTX 3060, Dual-Boot Ready
# ✅ English interface (no encoding issues) | ✅ Disk selection shown BEFORE input
# ✅ Separate GRUB recovery script available

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[⚠]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

# Check prerequisites
[[ $EUID -eq 0 ]] || error "Run with root privileges: sudo $0"
ping -c 2 -W 5 archlinux.org &>/dev/null || error "No internet connection."
[[ -d /sys/firmware/efi ]] || error "System must be booted in UEFI mode."

# Disk selection with model and size (output goes to stderr so it's visible when called in subshell)
select_disk() {
    local prompt="$1" exclude="${2:-}"
    local disks=() i=1
    echo -e "\n$prompt\n─────────────────────────────────────" >&2
    while IFS= read -r line; do
        local name size model
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        model=$(lsblk -d -o MODEL -n "/dev/$name" 2>/dev/null | xargs 2>/dev/null || echo "Unknown")
        [[ "$name" =~ ^(loop|sr|ram|zram) ]] && continue
        [[ -n "$exclude" && "$name" == "$exclude" ]] && continue
        disks+=("/dev/$name")
        printf "  %d) %-12s | %-10s | %s\n" "$i" "/dev/$name" "$size" "$model" >&2
        ((i++))
    done < <(lsblk -d -o NAME,SIZE -n 2>/dev/null | sort)
    echo "─────────────────────────────────────" >&2
    [[ ${#disks[@]} -eq 0 ]] && error "No disks found."
    while true; do
        read -rp "Enter disk number (1-${#disks[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disks[@]} )); then
            echo "${disks[$((choice-1))]}"; return
        else
            warn "Invalid choice." >&2
        fi
    done
}

# Partition name detection (NVMe/SATA safe)
get_partition() {
    local disk="$1" num="$2" part
    part=$(lsblk -n -o NAME "$disk" 2>/dev/null | tail -n +2 | sed -n "${num}p")
    [[ -n "$part" ]] && { echo "/dev/$part"; return; }
    part=$(blkid -t PART_ENTRY_NUMBER="$num" -o device 2>/dev/null | grep "^${disk}" | head -1)
    [[ -n "$part" ]] && { echo "$part"; return; }
    [[ "$disk" =~ nvme ]] && { echo "${disk}p${num}"; return; }
    echo "${disk}${num}"
}

clear
cat << 'EOF'
╔════════════════════════════════════════════╗
║  Arch Linux Installer — KDE Plasma 6       ║
║  🎨 Top Panel | 🚀 Centered Launcher      ║
║  ✅ RTX 3060 | ✅ Dual-Boot Ready          ║
╚════════════════════════════════════════════╝
EOF

# User input
read -rp "Username (letters only): " username
[[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || error "Invalid username."
read -rsp "Password for $username: " pass1; echo
read -rsp "Confirm password: " pass2; echo
[[ "$pass1" == "$pass2" ]] || error "Passwords do not match."
read -rp "Hostname (default: arch-kde): " hostname
hostname="${hostname:-arch-kde}"

# Disk selection
echo ""
warn "WARNING: The system disk will be COMPLETELY ERASED!"
system_disk=$(select_disk "Select disk for Arch Linux (SSD recommended):")
success "System disk: $system_disk"

extra_disks=()
warn "Additional disks will be formatted and mounted at /storageN"
while true; do
    [[ ${#extra_disks[@]} -gt 0 ]] && echo "Added: ${extra_disks[*]}"
    read -rp "Add a disk (e.g., /dev/sdb) or Enter to continue: " disk
    [[ -z "$disk" ]] && break
    [[ ! -b "$disk" ]] && { warn "Device $disk does not exist."; continue; }
    [[ "$disk" == "$system_disk" ]] && { warn "This is the system disk – skipped."; continue; }
    [[ " ${extra_disks[*]:-} " =~ " $disk " ]] && { warn "Disk already added."; continue; }
    extra_disks+=("$disk"); success "Added: $disk"
done

# Confirmation
echo ""
warn "Confirm installation:"
echo "  • System disk: $system_disk (will be erased)"
[[ ${#extra_disks[@]} -gt 0 ]] && echo "  • Additional disks: ${extra_disks[*]}"
echo "  • Username: $username"
echo "  • Hostname: $hostname"
read -rp "Proceed? (yes/y): " confirm
[[ "$confirm" =~ ^(yes|y)$ ]] || error "Installation cancelled."

# Time setup
log "Setting timezone (Europe/Moscow)..."
timedatectl set-ntp true
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime

# Partitioning
log "Partitioning $system_disk ..."
wipefs -a "$system_disk" 2>/dev/null || true
parted -s "$system_disk" mklabel gpt
parted -s "$system_disk" mkpart primary fat32 1MiB 513MiB
parted -s "$system_disk" set 1 esp on
parted -s "$system_disk" mkpart primary ext4 513MiB 100%
partprobe "$system_disk" 2>/dev/null || sleep 2

boot_part=$(get_partition "$system_disk" 1)
root_part=$(get_partition "$system_disk" 2)
log "Partitions: EFI=$boot_part | ROOT=$root_part"

# Formatting
mkfs.fat -F32 -n "ARCH_EFI" "$boot_part" || error "Failed to format EFI partition."
mkfs.ext4 -F -L "ARCH_ROOT" "$root_part" || error "Failed to format root partition."

mount "$root_part" /mnt
mkdir -p /mnt/boot
mount "$boot_part" /mnt/boot

# Base system
log "Installing base system..."
pacstrap -K /mnt \
    base base-devel linux linux-firmware \
    intel-ucode amd-ucode \
    vim nano sudo networkmanager grub efibootmgr \
    git wget curl rsync os-prober

genfstab -U /mnt >> /mnt/etc/fstab

# Export variables for chroot
export USERPASS="$pass1" USERNAME="$username" HOSTNAME="$hostname"

# Chroot configuration
log "Configuring system..."
arch-chroot /mnt /bin/bash << 'CHROOT_EOF'
set -e

USERNAME="${USERNAME}"
USERPASS="${USERPASS}"
HOSTNAME="${HOSTNAME}"

ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8\)/\1/; s/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "${HOSTNAME}" > /etc/hostname
echo "127.0.0.1   localhost" > /etc/hosts
echo "::1         localhost" >> /etc/hosts
echo "127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}" >> /etc/hosts

passwd -l root
useradd -m -G wheel,audio,video,storage -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USERPASS}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Enable multilib and update
sed -i '/^\s*#\s*\[multilib\]/,/^\s*#Include/s/^#//' /etc/pacman.conf
pacman -Syu --noconfirm

# Install KDE Plasma 6 and basic utilities
log "Installing KDE Plasma 6..."
pacman -S --noconfirm \
    plasma-meta sddm \
    networkmanager bluez bluez-utils \
    xorg xorg-server xorg-xinit \
    dolphin konsole krunner \
    discover packagekit-qt6

# NVIDIA drivers (stable branch)
log "Installing NVIDIA drivers..."
pacman -S --noconfirm \
    nvidia nvidia-utils nvidia-settings \
    lib32-nvidia-utils

# mkinitcpio for NVIDIA
sed -i 's/^MODULES=()/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
grep -q "kms" /etc/mkinitcpio.conf || sed -i 's/\(HOOKS=.*base.*\)/\1 kms/' /etc/mkinitcpio.conf
mkinitcpio -P || error "mkinitcpio failed."

# Applications from official repositories
log "Installing IDEs and applications..."
pacman -S --noconfirm \
    code pycharm-community-edition intellij-idea-community-edition \
    ttf-liberation ttf-dejavu noto-fonts noto-fonts-cjk noto-fonts-emoji \
    syncthing texstudio vlc steam qbittorrent \
    texlive-core texlive-latexextra texlive-fontsextra texlive-langcyrillic

# AUR helper (yay)
log "Setting up yay (AUR helper)..."
echo "%wheel ALL=(ALL) NOPASSWD: /usr/bin/pacman, /usr/bin/makepkg, /usr/bin/git" > /etc/sudoers.d/temp-aur
chmod 440 /etc/sudoers.d/temp-aur

su - "${USERNAME}" -c "
    cd /tmp && \
    git clone https://aur.archlinux.org/yay.git && \
    cd yay && \
    makepkg -si --noconfirm && \
    cd / && rm -rf /tmp/yay
"

rm -f /etc/sudoers.d/temp-aur
su - "${USERNAME}" -c "yay -S --noconfirm android-studio brave-bin obsidian"

# Enable services
systemctl enable NetworkManager bluetooth sddm
sed -i 's/^#AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf

# Keyboard layout (Alt+Shift)
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << 'XKB'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us,ru"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
XKB

# KDE interface: top panel + centered launcher
log "Configuring top panel and launcher..."
mkdir -p "/home/${USERNAME}/.config"
cat > "/home/${USERNAME}/.config/krunnerrc" << 'KRUNNER'
[General]
FreeFloating=true
Position=Center
KRUNNER

mkdir -p "/home/${USERNAME}/.config/autostart"
cat > "/home/${USERNAME}/.config/autostart/plasma-post-setup.desktop" << AUTOSTART
[Desktop Entry]
Type=Application
Name=Plasma Post Setup
Exec=/home/${USERNAME}/.config/plasma-post-setup.sh
Hidden=false
NoDisplay=true
X-KDE-AutostartAfter=plasmashell
AUTOSTART

cat > "/home/${USERNAME}/.config/plasma-post-setup.sh" << 'POST_SETUP'
#!/bin/bash
# Runs once after first Plasma login
SETUP_MARKER="$HOME/.plasma-setup-done"
[[ -f "$SETUP_MARKER" ]] && exit 0

sleep 8   # Wait for plasmashell to fully load

# Create top panel, remove bottom one (supports both Plasma 5 and 6)
qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
    var panels = panels();
    for (var i = 0; i < panels.length; i++) {
        if (panels[i].location === 'bottom') {
            panels[i].remove();
        }
    }
    var panel = new Panel();
    panel.location = 'top';
    panel.height = 42;
    panel.addWidget('org.kde.plasma.kicker');
    panel.addWidget('org.kde.plasma.icontasks');
    panel.addWidget('org.kde.plasma.systemtray');
    panel.addWidget('org.kde.plasma.digitalclock');
" 2>/dev/null || qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
    var panels = panels();
    for (var i = 0; i < panels.length; i++) {
        if (panels[i].location === 'bottom') {
            panels[i].remove();
        }
    }
    var panel = new Panel();
    panel.location = 'top';
    panel.height = 42;
    panel.addWidget('org.kde.plasma.kicker');
    panel.addWidget('org.kde.plasma.icontasks');
    panel.addWidget('org.kde.plasma.systemtray');
    panel.addWidget('org.kde.plasma.digitalclock');
" 2>/dev/null || true

# Set hotkeys
kwriteconfig6 --file kglobalshortcutsrc --group plasmashell --key _activate_launcher "Meta,none,Application Launcher" 2>/dev/null || \
kwriteconfig --file kglobalshortcutsrc --group plasmashell --key _activate_launcher "Meta,none,Application Launcher" 2>/dev/null || true
kwriteconfig6 --file kglobalshortcutsrc --group krunner --key _run "Meta+Space,none,KRunner" 2>/dev/null || \
kwriteconfig --file kglobalshortcutsrc --group krunner --key _run "Meta+Space,none,KRunner" 2>/dev/null || true

# Apply changes
qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || qdbus org.kde.KWin /KWin reconfigure 2>/dev/null || true

touch "$SETUP_MARKER"
rm -f "$HOME/.config/autostart/plasma-post-setup.desktop"
rm -f "$0"
POST_SETUP

chmod +x "/home/${USERNAME}/.config/plasma-post-setup.sh"
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

# GRUB installation
log "Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck || error "GRUB installation failed."
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Optional GRUB theme
log "Installing GRUB theme (Tela)..."
if git clone --depth=1 https://github.com/vinceliuice/grub2-themes.git /tmp/grub-themes 2>/dev/null; then
    cd /tmp/grub-themes
    if chmod +x install.sh && ./install.sh -t tela -s 1080p 2>/dev/null; then
        if [[ -f "/boot/grub/themes/Tela/theme.txt" ]]; then
            grep -q "^GRUB_THEME=" /etc/default/grub || echo 'GRUB_THEME="/boot/grub/themes/Tela/theme.txt"' >> /etc/default/grub
            sed -i 's|^GRUB_THEME=.*|GRUB_THEME="/boot/grub/themes/Tela/theme.txt"|' /etc/default/grub
            grub-mkconfig -o /boot/grub/grub.cfg
            success "GRUB theme installed."
        fi
    else
        warn "Failed to install GRUB theme."
    fi
    cd / && rm -rf /tmp/grub-themes
fi

log "Chroot configuration complete."
CHROOT_EOF

# Additional disks setup
if [[ ${#extra_disks[@]} -gt 0 ]]; then
    log "Setting up additional disks..."
    idx=1
    for disk in "${extra_disks[@]}"; do
        log "Formatting $disk ..."
        wipefs -a "$disk" 2>/dev/null || true
        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart primary ext4 1MiB 100%
        partprobe "$disk" 2>/dev/null || sleep 1

        part=$(get_partition "$disk" 1)
        mkfs.ext4 -F -L "STORAGE$idx" "$part" || error "mkfs failed: $part"

        UUID=$(blkid -s UUID -o value "$part")
        [[ -z "$UUID" ]] && error "Could not get UUID for $part"

        mount_point="/storage$idx"
        echo "UUID=$UUID $mount_point ext4 defaults,noatime 0 2" >> /mnt/etc/fstab
        mkdir -p "/mnt$mount_point"
        success "$disk → $mount_point (UUID: ${UUID:0:8}...)"
        ((idx++))
    done
fi

# Finish
umount -R /mnt 2>/dev/null || true

cat << EOF

╔════════════════════════════════════════════╗
║         🎉 Arch installation complete!     ║
╚════════════════════════════════════════════╝

After reboot you will boot into KDE Plasma 6.

- Press Meta (Windows) to open the launcher.
- Meta+Space for KRunner (search, commands, calculator).

To set up dual‑boot with Windows 11, follow the instructions below (including the automatic GRUB recovery step).
EOF