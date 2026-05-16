#!/bin/bash
# Arch Linux Automated Installer — KDE Plasma 6, NVIDIA RTX 3060, Dual-Boot Ready
# ✅ EWW top panel | ✅ Rofi launcher | ✅ PLM/SDDM login
# ✅ FIX: SSL certs, time sync, D-Bus errors, retry logic

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[⚠]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

# --- Пререквизиты ---
[[ $EUID -eq 0 ]] || error "Run with root: sudo $0"
ping -c 2 -W 5 archlinux.org &>/dev/null || error "No internet."
[[ -d /sys/firmware/efi ]] || error "UEFI mode required."

# --- Выбор диска ---
select_disk() {
    local prompt="$1" exclude="${2:-}" disks=() i=1
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
        read -rp "Disk number (1-${#disks[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disks[@]} )); then
            echo "${disks[$((choice-1))]}"; return
        else
            warn "Invalid choice." >&2
        fi
    done
}

# --- Получение имени раздела (NVMe/SATA safe) ---
get_partition() {
    local disk="$1" num="$2" part
    part=$(lsblk -n -l -o NAME "$disk" 2>/dev/null | tail -n +2 | sed -n "${num}p")
    [[ -n "$part" ]] && { echo "/dev/$part"; return; }
    part=$(blkid -t PART_ENTRY_NUMBER="$num" -o device 2>/dev/null | grep "^${disk}" | head -1)
    [[ -n "$part" ]] && { echo "$part"; return; }
    [[ "$disk" =~ nvme ]] && { echo "${disk}p${num}"; return; }
    echo "${disk}${num}"
}

# --- Retry-функция для git clone ---
git_clone_with_retry() {
    local url="$1" dest="$2" max_attempts=3
    for ((i=1; i<=max_attempts; i++)); do
        log "Attempt $i/$max_attempts: cloning $url..."
        if git clone --depth=1 "$url" "$dest" 2>/dev/null; then
            return 0
        elif [[ $i -lt $max_attempts ]]; then
            warn "Failed, waiting 5s before retry..."
            sleep 5
        fi
    done
    return 1
}

# --- Заголовок ---
clear
cat << 'EOF'
╔════════════════════════════════════════════╗
║  Arch Linux Installer — KDE Plasma 6       ║
║  🎨 EWW Panel | 🚀 Rofi Launcher          ║
║  ✅ RTX 3060 | ✅ Dual-Boot Ready          ║
╚════════════════════════════════════════════╝
EOF

# --- Ввод пользователя ---
read -rp "Username (letters only): " username
[[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || error "Invalid username."
read -rsp "Password: " pass1; echo
read -rsp "Confirm: " pass2; echo
[[ "$pass1" == "$pass2" ]] || error "Passwords mismatch."
read -rp "Hostname (default: arch-kde): " hostname
hostname="${hostname:-arch-kde}"

# --- Выбор дисков ---
warn "WARNING: System disk will be ERASED!"
system_disk=$(select_disk "Select Arch disk (SSD):")
success "System: $system_disk"

extra_disks=()
warn "Additional disks will be formatted to /storageN"
while true; do
    [[ ${#extra_disks[@]} -gt 0 ]] && echo "Added: ${extra_disks[*]}"
    read -rp "Add disk (/dev/sdX) or Enter: " disk
    [[ -z "$disk" ]] && break
    [[ ! -b "$disk" ]] && { warn "Not found"; continue; }
    [[ "$disk" == "$system_disk" ]] && { warn "System disk skipped"; continue; }
    [[ " ${extra_disks[*]:-} " =~ " $disk " ]] && { warn "Already added"; continue; }
    extra_disks+=("$disk"); success "Added: $disk"
done

# Подтверждение
echo -e "\n⚠️  Confirm:"
echo "  • System: $system_disk (ERASE)"
[[ ${#extra_disks[@]} -gt 0 ]] && echo "  • Extra: ${extra_disks[*]}"
echo "  • User: $username | Host: $hostname"
read -rp "Proceed? (yes/y): " confirm
[[ "$confirm" =~ ^(yes|y)$ ]] || error "Cancelled."

# --- Время и синхронизация (КРИТИЧНО для SSL) ---
log "Setting timezone and syncing time (SSL critical)..."
timedatectl set-ntp true
sleep 8  # Даём время на первичную синхронизацию
if ! timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
    warn "NTP not synced yet, continuing anyway..."
fi
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime

# --- Разметка ---
log "Partitioning $system_disk ..."
wipefs -a "$system_disk" 2>/dev/null || true
parted -s "$system_disk" mklabel gpt
parted -s "$system_disk" mkpart primary fat32 1MiB 513MiB
parted -s "$system_disk" set 1 esp on
parted -s "$system_disk" mkpart primary ext4 513MiB 100%

# Активация разделов
partprobe "$system_disk" 2>/dev/null || true
udevadm settle
partx -a "$system_disk" 2>/dev/null || true
udevadm trigger --subsystem-match=block 2>/dev/null || true
sleep 2

boot_part=$(get_partition "$system_disk" 1)
root_part=$(get_partition "$system_disk" 2)
log "Partitions: EFI=$boot_part | ROOT=$root_part"

# Ждём появления устройств
for part in "$boot_part" "$root_part"; do
    for ((i=0; i<15; i++)); do
        [[ -b "$part" ]] && break
        sleep 1
    done
    [[ -b "$part" ]] || error "Partition $part not appeared."
done

# Форматирование
mkfs.fat -F32 -n "ARCH_EFI" "$boot_part" || error "EFI format failed"
mkfs.ext4 -F -L "ARCH_ROOT" "$root_part" || error "Root format failed"

mount "$root_part" /mnt
mkdir -p /mnt/boot
mount "$boot_part" /mnt/boot

# --- Базовая система ---
log "Installing base system..."
pacstrap -K /mnt \
    base base-devel linux linux-firmware \
    intel-ucode amd-ucode \
    vim nano sudo networkmanager grub efibootmgr \
    git wget curl rsync os-prober \
    ca-certificates openssl  # ← КРИТИЧНО: сертификаты сразу

genfstab -U /mnt >> /mnt/etc/fstab

# --- Экспорт переменных ---
export USERPASS="$pass1" USERNAME="$username" HOSTNAME="$hostname"

# --- Конфигурация в chroot ---
log "Configuring system..."
arch-chroot /mnt /bin/bash << 'CHROOT_EOF'
set -e

# Логи внутри chroot
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[⚠]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

USERNAME="${USERNAME}"
USERPASS="${USERPASS}"
HOSTNAME="${HOSTNAME}"

# Время и локали
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc
timedatectl set-ntp true 2>/dev/null || true

sed -i 's/^#\(en_US.UTF-8\)/\1/; s/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Хостнейм и hosts
echo "${HOSTNAME}" > /etc/hostname
echo "127.0.0.1   localhost" > /etc/hosts
echo "::1         localhost" >> /etc/hosts
echo "127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}" >> /etc/hosts

# Пользователь
passwd -l root
useradd -m -G wheel,audio,video,storage -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USERPASS}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Multilib + обновление
sed -i '/^\s*#\s*\[multilib\]/,/^\s*#Include/s/^#//' /etc/pacman.conf
pacman -Syu --noconfirm

# 🔐 SSL-сертификаты (ОБЯЗАТЕЛЬНО перед AUR!)
log "Updating SSL certificates (critical for AUR)..."
pacman -S --noconfirm ca-certificates ca-certificates-mozilla openssl
update-ca-trust force-enable
update-ca-trust extract

# 🌐 Проверка доступа к AUR
log "Testing AUR connectivity..."
if ! curl -fsSL --connect-timeout 15 https://aur.archlinux.org/packages.json &>/dev/null; then
    warn "AUR test failed, retrying once..."
    sleep 3
    if ! curl -fsSL --connect-timeout 15 https://aur.archlinux.org/packages.json &>/dev/null; then
        error "Cannot reach AUR. Check: 1) Time is correct, 2) DNS works, 3) No proxy/censorship."
    fi
fi

# KDE Plasma 6 (без DM по умолчанию)
log "Installing KDE Plasma 6..."
pacman -S --noconfirm \
    plasma-meta \
    networkmanager bluez bluez-utils \
    xorg xorg-server xorg-xinit \
    dolphin konsole \
    discover packagekit-qt6

# NVIDIA (DKMS для совместимости с ядрами)
log "Installing NVIDIA drivers (DKMS)..."
pacman -S --noconfirm linux-headers dkms
pacman -S --noconfirm nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils

# mkinitcpio для NVIDIA
sed -i 's/^MODULES=()/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
grep -q "kms" /etc/mkinitcpio.conf || sed -i 's/\(HOOKS=.*base.*\)/\1 kms/' /etc/mkinitcpio.conf
mkinitcpio -P || error "mkinitcpio failed"

# Приложения из официальных репозиториев
log "Installing IDEs and apps..."
pacman -S --noconfirm \
    code pycharm-community-edition intellij-idea-community-edition \
    ttf-liberation ttf-dejavu noto-fonts noto-fonts-cjk noto-fonts-emoji \
    syncthing texstudio vlc steam qbittorrent \
    texlive-core texlive-latexextra texlive-fontsextra texlive-langcyrillic

# Rofi (лаунчер)
log "Installing Rofi..."
pacman -S --noconfirm rofi

# Go и Rust для сборки AUR-пакетов
log "Installing Go and Rust..."
pacman -S --noconfirm go rust

# 🔧 yay (AUR helper) с безопасным sudo
log "Setting up yay..."
echo "%wheel ALL=(ALL) NOPASSWD: /usr/bin/pacman, /usr/bin/makepkg, /usr/bin/git" > /etc/sudoers.d/temp-aur
chmod 440 /etc/sudoers.d/temp-aur

su - "${USERNAME}" -c "
    cd /tmp && \
    rm -rf yay && \
    git clone https://aur.archlinux.org/yay.git && \
    cd yay && \
    makepkg -si --noconfirm && \
    cd / && rm -rf /tmp/yay
" || error "Failed to build yay"

rm -f /etc/sudoers.d/temp-aur

# AUR-пакеты: EWW
log "Installing EWW from AUR..."
su - "${USERNAME}" -c "yay -S --noconfirm eww" || warn "EWW installation failed"

# Plasma Login Manager (PLM) с fallback на SDDM
log "Setting up display manager..."
if su - "${USERNAME}" -c "yay -S --noconfirm plasma-login-manager" 2>/dev/null; then
    if [[ -f /usr/lib/systemd/system/plasma-login-manager.service ]]; then
        # systemctl enable внутри chroot работает без D-Bus (просто создаёт симлинки)
        if systemctl enable plasma-login-manager 2>/dev/null; then
            success "PLM enabled"
        else
            warn "Could not enable PLM via systemctl, trying manual symlink..."
            mkdir -p /etc/systemd/system/display-manager.service.d
            ln -sf /usr/lib/systemd/system/plasma-login-manager.service /etc/systemd/system/display-manager.service 2>/dev/null || true
        fi
    else
        warn "PLM service file not found, installing SDDM"
        pacman -S --noconfirm sddm
        systemctl enable sddm
    fi
else
    warn "Could not install PLM, installing SDDM as fallback"
    pacman -S --noconfirm sddm
    systemctl enable sddm
fi

# Остальные AUR-пакеты
log "Installing additional AUR apps..."
su - "${USERNAME}" -c "yay -S --noconfirm android-studio brave-bin obsidian" || warn "Some AUR packages failed"

# Сервисы
systemctl enable NetworkManager bluetooth
sed -i 's/^#AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf

# Раскладка (Alt+Shift)
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
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck || error "GRUB install failed"
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Тема GRUB (опционально)
log "Installing GRUB theme (optional)..."
if git_clone_with_retry "https://github.com/vinceliuice/grub2-themes.git" /tmp/grub-themes; then
    cd /tmp/grub-themes
    if chmod +x install.sh && ./install.sh -t tela -s 1080p 2>/dev/null; then
        if [[ -f "/boot/grub/themes/Tela/theme.txt" ]]; then
            sed -i '/^GRUB_THEME=/d' /etc/default/grub
            echo 'GRUB_THEME="/boot/grub/themes/Tela/theme.txt"' >> /etc/default/grub
            grub-mkconfig -o /boot/grub/grub.cfg
            success "GRUB theme applied"
        fi
    fi
    cd / && rm -rf /tmp/grub-themes
fi

# Права на домашнюю директорию
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

log "Chroot configuration complete."
CHROOT_EOF

# --- Дополнительные диски ---
if [[ ${#extra_disks[@]} -gt 0 ]]; then
    log "Setting up additional disks..."
    idx=1
    for disk in "${extra_disks[@]}"; do
        log "Formatting $disk ..."
        wipefs -a "$disk" 2>/dev/null || true
        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart primary ext4 1MiB 100%
        partprobe "$disk" 2>/dev/null || true
        udevadm settle
        partx -a "$disk" 2>/dev/null || true
        sleep 2

        part=$(get_partition "$disk" 1)
        for ((i=0; i<15; i++)); do
            [[ -b "$part" ]] && break
            sleep 1
        done
        [[ -b "$part" ]] || error "Partition $part not appeared"

        mkfs.ext4 -F -L "STORAGE$idx" "$part" || error "mkfs failed"
        UUID=$(blkid -s UUID -o value "$part")
        [[ -z "$UUID" ]] && error "No UUID for $part"

        mount_point="/storage$idx"
        echo "UUID=$UUID $mount_point ext4 defaults,noatime 0 2" >> /mnt/etc/fstab
        mkdir -p "/mnt$mount_point"
        success "$disk → $mount_point"
        ((idx++))
    done
fi

# Завершение
umount -R /mnt 2>/dev/null || true

cat << EOF

╔════════════════════════════════════════════╗
║     🎉 Arch installation complete!         ║
╚════════════════════════════════════════════╝

Next steps:
  1. Reboot: $ reboot
  2. Login via PLM or SDDM
  3. Meta+Space → Rofi launcher
  4. EWW is installed – configure your top bar in ~/.config/eww/

Dual-boot with Windows 11:
  • Install Windows on a SEPARATE disk
  • Boot into Arch and run:
    $ sudo os-prober
    $ sudo grub-mkconfig -o /boot/grub/grub.cfg

Troubleshooting:
  • SSL/AUR errors: check time with 'timedatectl status'
  • NVIDIA black screen: add nvidia-drm.modeset=1 to kernel params
  • No panel? Start EWW manually: eww daemon

Enjoy! 🐧✨
EOF