#!/bin/bash
# Arch Linux automated installer with KDE Plasma, NVIDIA (open), GRUB/SDDM themes, Alt+Shift, Bluetooth, auto-mount HDDs

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}→ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

# Check root
[[ $EUID -ne 0 ]] && error "This script must be run as root (sudo)."

# Internet check
ping -c 1 archlinux.org &>/dev/null || error "No internet connection. Please configure network."

# UEFI check
[[ -d /sys/firmware/efi/efivars ]] || error "UEFI mode required. Reboot in UEFI."

# Function to select a disk – all messages go to stderr, only result to stdout
select_disk() {
    local prompt="$1"
    local disks=()
    local i=1

    echo "$prompt" >&2
    while read -r name size; do
        if [[ ! "$name" =~ ^(loop|sr|ram|zram) ]]; then
            disks+=("/dev/$name")
            echo "  $i) /dev/$name ($size)" >&2
            ((i++))
        fi
    done < <(lsblk -d -o NAME,SIZE -n 2>/dev/null)

    if [[ ${#disks[@]} -eq 0 ]]; then
        error "No disks found."
    fi

    while true; do
        read -p "Enter disk number (1-${#disks[@]}): " choice >&2
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#disks[@]} ]; then
            echo "${disks[$((choice-1))]}"
            return
        else
            echo "Invalid choice, try again." >&2
        fi
    done
}

clear
echo "============================================="
echo "  Arch Linux + KDE Plasma + NVIDIA (open)"
echo "============================================="
echo

read -p "Enter username: " username
[[ -z "$username" ]] && error "Username cannot be empty."
read -sp "Password for $username: " userpass
echo
read -sp "Repeat password: " userpass2
echo
[[ "$userpass" != "$userpass2" ]] && error "Passwords do not match."

echo
system_disk=$(select_disk "Select SYSTEM disk (SSD). ALL DATA on it will be DESTROYED:")
echo -e "${GREEN}✓ System disk selected: $system_disk${NC}"

echo
warn "Now specify ADDITIONAL disks (HDD) to be formatted and auto-mounted."
extra_disks=()
while true; do
    echo
    if [[ ${#extra_disks[@]} -gt 0 ]]; then
        echo "Currently selected extra disks: ${extra_disks[*]}"
    fi
    read -p "Add a disk (enter path like /dev/sda, or empty to finish): " disk
    [[ -z "$disk" ]] && break

    if [[ -b "$disk" ]]; then
        if [[ "$disk" == "$system_disk" ]]; then
            echo "❌ Cannot add system disk as extra disk."
        elif [[ " ${extra_disks[@]} " =~ " ${disk} " ]]; then
            echo "❌ Disk $disk already added."
        else
            extra_disks+=("$disk")
            echo "✓ Added $disk"
        fi
    else
        echo "❌ Disk $disk does not exist. Use correct path (e.g., /dev/sda)."
    fi
done

if [[ ${#extra_disks[@]} -gt 0 ]]; then
    echo -e "${GREEN}✓ Extra disks to format: ${extra_disks[*]}${NC}"
else
    echo "No extra disks selected."
fi

read -p "Hostname (default: arch-kde): " hostname
hostname=${hostname:-arch-kde}

# Timezone
info "Setting timezone (Europe/Moscow)..."
timedatectl set-ntp true
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime

# Partition SSD
info "Partitioning $system_disk..."
wipefs -a "$system_disk"
parted "$system_disk" mklabel gpt
parted "$system_disk" mkpart primary fat32 1MiB 513MiB
parted "$system_disk" set 1 esp on
parted "$system_disk" mkpart primary ext4 513MiB 100%
partprobe "$system_disk"

boot_part="${system_disk}1"
root_part="${system_disk}2"
[[ "$system_disk" == *"nvme"* ]] && boot_part="${system_disk}p1" && root_part="${system_disk}p2"

mkfs.fat -F32 "$boot_part"
mkfs.ext4 -F "$root_part"

mount "$root_part" /mnt
mkdir /mnt/boot
mount "$boot_part" /mnt/boot

# Install base system
info "Installing base system (may take a while)..."
pacstrap /mnt base base-devel linux linux-firmware vim nano sudo networkmanager grub efibootmgr
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot configuration
info "Configuring system..."
arch-chroot /mnt /bin/bash <<EOF

ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "$hostname" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain $hostname
HOSTS

echo "root:root" | chpasswd
useradd -m -G wheel,audio,video,storage -s /bin/bash "$username"
echo "$username:$userpass" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

pacman -Syu
pacman -S plasma-meta sddm konsole dolphin ark gwenview \
    bluez bluez-utils blueman pipewire pipewire-pulse wireplumber \
    git base-devel grub-customizer \
    nvidia-open nvidia-utils nvidia-settings

systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable sddm

sed -i 's/^#AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf

mkdir -p /home/$username/.config
cat > /home/$username/.config/kxkbrc <<KXKBRC
[Layout]
LayoutList=us,ru
Model=pc105
Options=grp:alt_shift_toggle
ResetOldOptions=true
KXKBRC
chown -R $username:$username /home/$username/.config

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<XKB
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us,ru"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
XKB

# SDDM theme (Sugar Dark)
git clone https://github.com/MarianArlt/sddm-sugar-dark /tmp/sddm-sugar-dark
mkdir -p /usr/share/sddm/themes
cp -r /tmp/sddm-sugar-dark /usr/share/sddm/themes/
cat > /etc/sddm.conf <<SDDM
[Theme]
Current=sddm-sugar-dark
[Autologin]
User=$username
Session=plasma
SDDM

# GRUB theme (Vimix)
git clone https://github.com/Se7endS/grub-vimix /tmp/grub-vimix
mkdir -p /boot/grub/themes
cp -r /tmp/grub-vimix/Vimix /boot/grub/themes/
echo 'GRUB_THEME="/boot/grub/themes/Vimix/theme.txt"' >> /etc/default/grub

# Установка загрузчика GRUB (исправление!)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

EOF

# Additional HDDs
if [[ ${#extra_disks[@]} -gt 0 ]]; then
    info "Setting up extra disks..."
    idx=1
    for disk in "${extra_disks[@]}"; do
        info "Formatting $disk ..."
        wipefs -a "$disk"
        parted "$disk" mklabel gpt
        parted "$disk" mkpart primary ext4 1MiB 100%
        partprobe "$disk"
        part="${disk}1"
        [[ "$disk" == *"nvme"* ]] && part="${disk}p1"
        mkfs.ext4 -F "$part"
        UUID=$(blkid -s UUID -o value "$part")
        mount_point="/storage$idx"   # точка монтирования внутри системы
        # Создаём каталог внутри chroot
        arch-chroot /mnt mkdir -p "$mount_point"
        echo "UUID=$UUID $mount_point ext4 defaults,noatime 0 2" >> /mnt/etc/fstab
        ((idx++))
    done
    # Монтируем все дополнительные диски внутри chroot
    arch-chroot /mnt mount -a
fi

umount -R /mnt
echo -e "${GREEN}Installation complete! Reboot with: reboot${NC}"