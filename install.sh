#!/bin/bash
# Arch Linux автоматическая установка с KDE Plasma, темами GRUB/SDDM, Alt+Shift, Bluetooth, монтированием HDD, драйверами NVIDIA (open)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}Ошибка: $1${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}→ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

[[ $EUID -ne 0 ]] && error "Скрипт должен запускаться от root."
ping -c 1 archlinux.org &>/dev/null || error "Нет интернета."
[[ -d /sys/firmware/efi/efivars ]] || error "Только UEFI."

select_disk() {
    local prompt="$1"
    local disks=($(lsblk -d -o NAME,SIZE -n | awk '{print "/dev/"$1" ("$2")"}'))
    [[ ${#disks[@]} -eq 0 ]] && error "Нет дисков."
    echo "$prompt"
    select disk in "${disks[@]}"; do
        if [[ -n $disk ]]; then
            echo "${disk%% *}"
            return
        else
            echo "Неверный выбор, попробуйте снова."
        fi
    done
}

clear
echo "============================================="
echo "  Arch Linux + KDE Plasma + NVIDIA (open)"
echo "============================================="

read -p "Введите имя пользователя: " username
[[ -z "$username" ]] && error "Имя не может быть пустым."
read -sp "Пароль для $username: " userpass
echo
read -sp "Повторите пароль: " userpass2
echo
[[ "$userpass" != "$userpass2" ]] && error "Пароли не совпадают."

echo
warn "Выберите диск для системы (SSD). ВСЕ ДАННЫЕ НА НЁМ БУДУТ УДАЛЕНЫ."
system_disk=$(select_disk "Системный диск:")
echo "Выбран: $system_disk"

echo
warn "Теперь укажите ДОПОЛНИТЕЛЬНЫЕ диски (HDD) для автоматического монтирования."
extra_disks=()
while true; do
    read -p "Добавить диск (оставьте пустым для завершения): " disk
    [[ -z "$disk" ]] && break
    if [[ -b "$disk" ]]; then
        extra_disks+=("$disk")
        echo "Добавлен $disk"
    else
        echo "Диск $disk не существует, пропускаем."
    fi
done

read -p "Имя хоста (по умолчанию arch-kde): " hostname
hostname=${hostname:-arch-kde}

# Часовой пояс
info "Настройка времени (Europe/Moscow)..."
timedatectl set-ntp true
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime

# Разметка SSD
info "Разметка $system_disk..."
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

# Установка базы
info "Установка базовой системы..."
pacstrap /mnt base base-devel linux linux-firmware vim nano sudo networkmanager grub efibootmgr
genfstab -U /mnt >> /mnt/etc/fstab

# chroot и настройка
info "Настройка системы..."
arch-chroot /mnt /bin/bash <<EOF

ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
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

# Установка KDE, драйверов NVIDIA open, Bluetooth, тем
pacman -S --noconfirm plasma-meta sddm konsole dolphin ark gwenview \
    bluez bluez-utils blueman pipewire pipewire-pulse wireplumber \
    git base-devel grub-customizer \
    nvidia-open nvidia-utils nvidia-settings

systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable sddm

# Bluetooth автовключение
sed -i 's/^#AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf

# Alt+Shift для KDE и X11
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

# Тема SDDM
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

# Тема GRUB
git clone https://github.com/Se7endS/grub-vimix /tmp/grub-vimix
mkdir -p /boot/grub/themes
cp -r /tmp/grub-vimix/Vimix /boot/grub/themes/
echo 'GRUB_THEME="/boot/grub/themes/Vimix/theme.txt"' >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

EOF

# Дополнительные HDD
if [[ ${#extra_disks[@]} -gt 0 ]]; then
    info "Настройка дополнительных дисков..."
    idx=1
    for disk in "${extra_disks[@]}"; do
        info "Форматирование $disk ..."
        wipefs -a "$disk"
        parted "$disk" mklabel gpt
        parted "$disk" mkpart primary ext4 1MiB 100%
        partprobe "$disk"
        part="${disk}1"
        [[ "$disk" == *"nvme"* ]] && part="${disk}p1"
        mkfs.ext4 -F "$part"
        UUID=$(blkid -s UUID -o value "$part")
        mount_point="/mnt/storage$idx"
        mkdir -p "$mount_point"
        echo "UUID=$UUID $mount_point ext4 defaults,noatime 0 2" >> /mnt/etc/fstab
        ((idx++))
    done
    arch-chroot /mnt mount -a
fi

umount -R /mnt
echo -e "${GREEN}Установка завершена! Перезагрузитесь командой reboot${NC}"