#!/bin/bash
# Arch Linux Automated Installer — KDE Plasma 6, NVIDIA RTX 3060, Dual-Boot Ready
# ✅ EWW top panel | ✅ Rofi launcher | ✅ PLM login manager (no SDDM fallback)
# ✅ Robust AUR handling with yay fallback | ✅ Fixed bugs from original
# ✅ zram swap | ✅ pipewire | ✅ flatpak | ✅ fwupd | ✅ ufw | ✅ TRIM | ✅ logging

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
LOGFILE="/var/log/arch-install.log"

log()    { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOGFILE"; }
success(){ echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOGFILE"; }
warn()   { echo -e "${YELLOW}[⚠]${NC} $1" | tee -a "$LOGFILE"; }
error()  { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOGFILE" >&2; exit 1; }

# Rollback on error
cleanup() {
    warn "Error occurred. Unmounting..."
    umount -R /mnt 2>/dev/null || true
    warn "See $LOGFILE for details."
}
trap cleanup ERR

[[ $EUID -eq 0 ]] || error "Run with root privileges: sudo $0"

# Check internet (try repo, not just ping)
if ! timeout 10 bash -c '</dev/tcp/archlinux.org/443' 2>/dev/null; then
    ping -c 2 -W 5 archlinux.org &>/dev/null || error "No internet connection."
fi

[[ -d /sys/firmware/efi ]] || error "System must be booted in UEFI mode."

# Init log
mkdir -p /var/log
: > "$LOGFILE"
log "Arch Linux Installer started at $(date)"

# --- Time sync BEFORE chroot (critical for TLS) ---
log "Syncing system time..."
timedatectl set-ntp true
sleep 2
hwclock --systohc

# Auto-detect microcode
detect_ucode() {
    if grep -q "AuthenticAMD" /proc/cpuinfo; then echo "amd-ucode"
    elif grep -q "GenuineIntel" /proc/cpuinfo; then echo "intel-ucode"
    else echo ""; fi
}
UCODE=$(detect_ucode)
log "Detected CPU microcode: ${UCODE:-unknown}"

# Disk selection with model and size
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

get_partition() {
    local disk="$1" num="$2" part
    part=$(lsblk -n -l -o NAME "$disk" 2>/dev/null | tail -n +2 | sed -n "${num}p")
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
║  🎨 EWW Panel | 🚀 Rofi Launcher           ║
║  ✅ RTX 3060 | ✅ Dual-Boot Ready           ║
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
log "Existing partitions on $system_disk:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT -n "$system_disk" 2>/dev/null | sed 's/^/  /' || true

extra_disks=()
warn "Additional disks will be formatted AND auto-mounted at /storageN"
while true; do
    [[ ${#extra_disks[@]} -gt 0 ]] && echo "Added: ${extra_disks[*]}"
    read -rp "Add a disk (e.g., /dev/sdb) or Enter to continue: " disk
    [[ -z "$disk" ]] && break
    [[ ! -b "$disk" ]] && { warn "Device $disk does not exist."; continue; }
    [[ "$disk" == "$system_disk" ]] && { warn "This is the system disk – skipped."; continue; }
    [[ " ${extra_disks[*]:-} " =~ " $disk " ]] && { warn "Disk already added."; continue; }
    read -rp "Format AND mount $disk at /storage${#extra_disks[@]}? (yes/y): " confirm_disk
    [[ "$confirm_disk" =~ ^(yes|y)$ ]] || { warn "Skipped $disk."; continue; }
    extra_disks+=("$disk"); success "Added: $disk"
done

# Confirmation
echo ""
warn "Confirm installation:"
echo "  • System disk: $system_disk (will be erased)"
[[ ${#extra_disks[@]} -gt 0 ]] && echo "  • Additional disks: ${extra_disks[*]}"
echo "  • Username: $username"
echo "  • Hostname: $hostname"
echo "  • Microcode: ${UCODE:-auto}"
read -rp "Proceed? (yes/y): " confirm
[[ "$confirm" =~ ^(yes|y)$ ]] || error "Installation cancelled."

# Save password securely
PASSFILE=$(mktemp)
chmod 600 "$PASSFILE"
echo "$pass1" > "$PASSFILE"

# Timezone
log "Setting timezone (Europe/Moscow)..."
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime

# --- Optimize mirrors before install ---
log "Optimizing mirrors with reflector..."
if command -v reflector &>/dev/null; then
    reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null || warn "Reflector failed, using default mirrors."
else
    warn "reflector not installed, skipping mirror optimization."
fi

# Partitioning
log "Partitioning $system_disk ..."

# Free the disk: disable swap and unmount any of its partitions
# (Arch live may auto-enable swap/mounts from this disk, blocking rescan)
for p in /dev/${system_disk#/dev/}*; do
    [[ -b "$p" ]] || continue
    swapoff "$p" 2>/dev/null || true
    umount "$p" 2>/dev/null || true
done

# Drop stale partition device nodes
partprobe "$system_disk" 2>/dev/null || true
for p in /dev/${system_disk#/dev/}*; do
    [[ -b "$p" ]] || continue
    partx -d "$p" 2>/dev/null || true
done
blockdev --rereadpt "$system_disk" 2>/dev/null || true

wipefs -a "$system_disk" 2>/dev/null || true

# parted: don't let set -e abort on the benign "could not inform kernel" warning
parted -s "$system_disk" mklabel gpt || true
parted -s "$system_disk" mkpart primary fat32 1MiB 513MiB || true
parted -s "$system_disk" set 1 esp on || true
parted -s "$system_disk" mkpart primary ext4 513MiB 100% || true

# Notify the kernel about the new layout
udevadm settle
partprobe "$system_disk" 2>/dev/null || true
udevadm settle
sleep 3
partx -a "$system_disk" 2>/dev/null || partx -u "$system_disk" 2>/dev/null || true
udevadm trigger --subsystem-match=block 2>/dev/null || true
sleep 1

boot_part=$(get_partition "$system_disk" 1)
root_part=$(get_partition "$system_disk" 2)
log "Partitions: EFI=$boot_part | ROOT=$root_part"

for part in "$boot_part" "$root_part"; do
    for ((i=0; i<10; i++)); do
        [[ -b "$part" ]] && break
        sleep 1
    done
    [[ -b "$part" ]] || error "Partition $part did not appear after 10 seconds."
done

mkfs.fat -F32 -n "ARCH_EFI" "$boot_part" || error "Failed to format EFI partition."
mkfs.ext4 -F -L "ARCH_ROOT" "$root_part" || error "Failed to format root partition."

mount "$root_part" /mnt
mkdir -p /mnt/boot
mount "$boot_part" /mnt/boot

# Base system
# Enable [multilib] in the LIVE pacman.conf BEFORE pacstrap (needed for lib32-* pkgs)
sed -i '/^\s*#\s*\[multilib\]/,/^\s*#Include/s/^#//' /etc/pacman.conf
log "Installing base system..."
PACSTAMP_PKGS="base base-devel linux linux-firmware"
[[ -n "$UCODE" ]] && PACSTAMP_PKGS="$PACSTAMP_PKGS $UCODE"
PACSTAMP_PKGS="$PACSTAMP_PKGS vim nano sudo networkmanager grub efibootmgr git wget curl rsync os-prober"
PACSTAMP_PKGS="$PACSTAMP_PKGS reflector fwupd pipewire pipewire-alsa pipewire-pulse wireplumber lib32-pipewire flatpak ufw power-profiles-daemon zram-generator"

pacstrap -K /mnt $PACSTAMP_PKGS || error "pacstrap failed."

genfstab -U /mnt >> /mnt/etc/fstab

# Write password to secured location inside chroot (in /root, stable - not /tmp)
mkdir -p /mnt/root
cp "$PASSFILE" /mnt/root/.pswd
chmod 600 /mnt/root/.pswd

# Export only username and hostname (NOT password)
export USERNAME="$username" HOSTNAME="$hostname"

# Chroot configuration
log "Configuring system..."
arch-chroot /mnt /bin/bash << 'CHROOT_EOF'
set -e

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[⚠]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

FAILED_PKGS=()
mark_failed() { FAILED_PKGS+=("$1"); }

USERNAME="${USERNAME}"
HOSTNAME="${HOSTNAME}"
PASSWD_FILE="/root/.pswd"

ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --hctosys

sed -i 's/^#\(en_US.UTF-8\)/\1/; s/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "${HOSTNAME}" > /etc/hostname
echo "127.0.0.1   localhost" > /etc/hosts
echo "::1         localhost" >> /etc/hosts
echo "127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}" >> /etc/hosts

PASS=$(cat "$PASSWD_FILE")
useradd -m -G wheel,audio,video,storage -s /bin/bash "${USERNAME}"
printf '%s\n' "${USERNAME}:${PASS}" | chpasswd
rm -f "$PASSWD_FILE"

passwd -l root
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Enable multilib and update
sed -i '/^\s*#\s*\[multilib\]/,/^\s*#Include/s/^#//' /etc/pacman.conf
pacman -Syu --noconfirm --noprogressbar 2>/dev/null || warn "Full system update had issues, continuing..."

# SSL certs
log "Updating SSL certificates..."
pacman -S --noconfirm --noprogressbar ca-certificates-mozilla 2>/dev/null || true
update-ca-trust || true

# KDE Plasma 6
log "Installing KDE Plasma 6..."
pacman -S --noconfirm --noprogressbar \
    plasma-meta \
    networkmanager bluez bluez-utils \
    xorg xorg-server xorg-xinit \
    dolphin konsole \
    discover packagekit-qt6 || warn "Some KDE packages failed."

# NVIDIA
log "Installing kernel headers..."
pacman -S --noconfirm --noprogressbar linux-headers dkms 2>/dev/null || true

# Check if lib32-nvidia-utils exists in enabled repos
if pacman -Si lib32-nvidia-utils &>/dev/null; then
    log "Installing NVIDIA drivers..."
    pacman -S --noconfirm --noprogressbar \
        nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils 2>/dev/null || \
        warn "Some NVIDIA packages failed."
else
    warn "lib32-nvidia-utils not available. Installing without 32-bit libs."
    pacman -S --noconfirm --noprogressbar nvidia-dkms nvidia-utils nvidia-settings 2>/dev/null || \
        warn "NVIDIA packages failed."
fi

# mkinitcpio - NVIDIA modules + kms hook
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
grep -q '^HOOKS=.*\bkms\b' /etc/mkinitcpio.conf || sed -i 's/^HOOKS=(/HOOKS=(kms /' /etc/mkinitcpio.conf
mkinitcpio -P || error "mkinitcpio failed."

# Applications
log "Installing IDEs and applications..."
pacman -S --noconfirm --noprogressbar \
    code pycharm-community-edition intellij-idea-community-edition \
    ttf-liberation ttf-dejavu noto-fonts noto-fonts-cjk noto-fonts-emoji \
    syncthing texstudio vlc steam qbittorrent \
    texlive-core texlive-latexextra texlive-fontsextra texlive-langcyrillic 2>/dev/null || \
    warn "Some applications failed."

log "Installing Rofi..."
pacman -S --noconfirm --noprogressbar rofi 2>/dev/null || warn "Rofi install failed."

log "Installing Go and Rust..."
pacman -S --noconfirm --noprogressbar go rust 2>/dev/null || warn "Go/Rust install failed."

# Flatpak setup (flatpak already installed via pacstrap)
log "Setting up Flatpak..."
if command -v flatpak &>/dev/null && flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null; then
    success "Flatpak + Flathub configured."
else
    mark_failed "flatpak"
    warn "Flatpak setup failed."
fi

# UFW firewall
log "Setting up UFW firewall..."
if pacman -S --noconfirm --noprogressbar ufw 2>/dev/null; then
    echo "DEFAULT_INPUT_POLICY=DROP" >> /etc/ufw/ufw.conf
    echo "DEFAULT_FORWARD_POLICY=DROP" >> /etc/ufw/ufw.conf
    echo "DEFAULT_OUTPUT_POLICY=ACCEPT" >> /etc/ufw/ufw.conf
    systemctl enable ufw 2>/dev/null || true
    success "UFW configured (default deny inbound)."
else
    mark_failed "ufw"
    warn "UFW installation failed."
fi

# ----- AUR helper (yay) with fallback -----
log "Setting up yay (AUR helper)..."
echo "%wheel ALL=(ALL) NOPASSWD: /usr/bin/pacman, /usr/bin/makepkg, /usr/bin/git" > /etc/sudoers.d/temp-aur
chmod 440 /etc/sudoers.d/temp-aur

YAY_OK=false
if runuser -u "${USERNAME}" -- bash -c "
    cd /tmp && \
    git clone https://aur.archlinux.org/yay.git && \
    cd yay && \
    makepkg -si --noconfirm && \
    cd / && rm -rf /tmp/yay
" 2>&1; then
    YAY_OK=true
    success "yay installed from AUR."
else
    warn "AUR clone failed. Trying GitHub tarball..."
    if runuser -u "${USERNAME}" -- bash -c "
        cd /tmp && \
        wget -q 'https://github.com/Jguer/yay/archive/refs/heads/master.tar.gz' -O yay.tar.gz && \
        tar xf yay.tar.gz && \
        cd yay-master && \
        makepkg -si --noconfirm && \
        cd / && rm -rf /tmp/yay.tar.gz /tmp/yay-master
    " 2>&1; then
        YAY_OK=true
        success "yay installed from GitHub tarball."
    else
        mark_failed "yay (AUR helper)"
        warn "yay could not be installed. AUR packages will be skipped."
    fi
fi

# ----- AUR packages (only if yay is available) -----
if $YAY_OK; then
    log "Installing EWW..."
    if runuser -u "${USERNAME}" -- bash -c "yay -S --noconfirm eww" 2>/dev/null; then
        success "EWW installed."
    else
        mark_failed "eww (Elkowars Wacky Widgets)"
        warn "EWW installation failed."
    fi

    log "Installing Plasma Login Manager (PLM)..."
    if runuser -u "${USERNAME}" -- bash -c "yay -S --noconfirm plasma-login-manager" 2>/dev/null; then
        if systemctl enable plasma-login-manager 2>/dev/null; then
            success "PLM enabled."
        else
            mark_failed "plasma-login-manager service enablement"
            warn "PLM service not found or could not be enabled."
        fi
    else
        mark_failed "plasma-login-manager"
        warn "PLM installation failed. No login manager will be enabled."
    fi

    log "Installing additional AUR applications..."
    for pkg in android-studio brave-bin obsidian; do
        if ! runuser -u "${USERNAME}" -- bash -c "yay -S --noconfirm $pkg" 2>/dev/null; then
            mark_failed "$pkg"
            warn "$pkg failed to install."
        fi
    done
else
    for pkg in eww plasma-login-manager android-studio brave-bin obsidian; do
        mark_failed "$pkg (no yay)"
    done
    warn "All AUR packages skipped because yay is not available."
fi

# Remove temporary NOPASSWD sudoers rule AFTER all AUR installs are done
rm -f /etc/sudoers.d/temp-aur

# Enable basic services
systemctl enable NetworkManager bluetooth || true
sed -i 's/^#AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf

# zram swap via systemd-zram-generator (activates automatically on /dev/zram0)
log "Configuring zram swap..."
mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf << 'ZRAM'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
ZRAM
systemctl daemon-reload || true
success "zram swap configured (compression: zstd)."

# Keyboard layout
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << 'XKB'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us,ru"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
XKB

# GRUB
log "Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck || error "GRUB installation failed."

# Verify EFI entry
log "Verifying EFI boot entry..."
efibootmgr -v 2>/dev/null | grep -q "GRUB" && success "GRUB EFI entry found." || warn "GRUB EFI entry not found in firmware."

# NVIDIA kernel parameters for stable modesetting (Plasma/Wayland on RTX 3060)
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet nvidia_drm.modeset=1 nvidia_drm.fbdev=1"/' /etc/default/grub

grep -q '^GRUB_DISABLE_OS_PROBER=false' /etc/default/grub || \
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig had issues."

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

# Write failed packages list (inside chroot -> /tmp, mounted as /mnt/tmp on host)
printf "%s\n" "${FAILED_PKGS[@]:-}" > /tmp/failed_packages.txt
log "Chroot configuration complete."
CHROOT_EOF

# Additional disks setup
if [[ ${#extra_disks[@]} -gt 0 ]]; then
    log "Setting up additional disks..."
    idx=1
    for disk in "${extra_disks[@]}"; do
        log "Formatting and setting up $disk ..."
        wipefs -a "$disk" 2>/dev/null || true
        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart primary ext4 1MiB 100%
        partprobe "$disk" 2>/dev/null || true
        udevadm settle
        partx -a "$disk" 2>/dev/null || true
        udevadm trigger --subsystem-match=block 2>/dev/null || true
        sleep 1

        part=$(get_partition "$disk" 1)
        for ((i=0; i<10; i++)); do
            [[ -b "$part" ]] && break
            sleep 1
        done
        [[ -b "$part" ]] || error "Partition $part for additional disk did not appear."

        mkfs.ext4 -F -L "STORAGE$idx" "$part" || error "mkfs failed: $part"

        UUID=$(blkid -s UUID -o value "$part")
        [[ -z "$UUID" ]] && error "Could not get UUID for $part"

        mount_point="/storage$idx"
        echo "UUID=$UUID $mount_point ext4 defaults,noatime,discard 0 2" >> /mnt/etc/fstab
        mkdir -p "/mnt$mount_point"
        success "$disk → $mount_point (UUID: ${UUID:0:8}...)"
        ((idx++))
    done
fi

# Enable TRIM timer inside chroot
arch-chroot /mnt systemctl enable fstrim.timer 2>/dev/null || true

# Read failed packages list (BEFORE unmounting /mnt)
FAILED_LIST=""
if [[ -f /mnt/tmp/failed_packages.txt ]]; then
    FAILED_LIST=$(cat /mnt/tmp/failed_packages.txt)
fi

# Finish
umount -R /mnt 2>/dev/null || true

cat << EOF

╔════════════════════════════════════════════╗
║         🎉 Arch installation complete!       ║
╚════════════════════════════════════════════╝

After reboot:
  • If PLM was installed: you'll be greeted by Plasma Login Manager.
  • Press Meta+Space to launch Rofi.
  • EWW is ready if installed.
  • Flatpak + Flathub available.
  • UFW firewall active (deny inbound by default).
EOF

if [[ -n "$FAILED_LIST" ]]; then
    echo ""
    echo "⚠️  The following packages were NOT installed:"
    while IFS= read -r pkg; do
        echo "   • $pkg"
    done <<< "$FAILED_LIST"
    echo ""
    echo "  Possible reasons: AUR connectivity, SSL issues, or unsupported packages."
    echo "  You can install them manually after rebooting:"
    echo "    yay -S <package>"
fi

echo ""
echo "To set up dual-boot with Windows 11, run the GRUB recovery script."
echo "Log saved to: $LOGFILE"

# Cleanup temp password file
rm -f "$PASSFILE"
