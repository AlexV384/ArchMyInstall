#!/bin/bash
# Arch Linux автоматическая установка с KDE Plasma, темами GRUB/SDDM, Alt+Shift, Bluetooth, монтированием HDD

set -e  # прерывать при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}Ошибка: $1${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}→ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

# Проверка, что скрипт запущен от root
[[ $EUID -ne 0 ]] && error "Скрипт должен запускаться от root (sudo)."

# Проверка подключения к интернету
info "Проверка интернета..."
ping -c 1 archlinux.org &>/dev/null || error "Нет интернета. Настройте подключение (iwctl, dhcpcd)."

# Убедимся, что система в UEFI режиме
[[ -d /sys/firmware/efi/efivars ]] || error "Скрипт поддерживает только UEFI. Перезагрузитесь в UEFI режиме."

# --- Функция для выбора диска из списка ---
select_disk() {
    local prompt="$1"
    local disks=($(lsblk -d -o NAME,SIZE -n | awk '{print "/dev/"$1" ("$2")"}'))
    if [[ ${#disks[@]} -eq 0 ]]; then
        error "Не найдено ни одного диска."
    fi
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

# --- Ввод параметров от пользователя ---
clear
echo "============================================="
echo "  Arch Linux + KDE Plasma автоматическая установка"
echo "============================================="
echo

read -p "Введите имя пользователя (латиница): " username
[[ -z "$username" ]] && error "Имя не может быть пустым."
read -sp "Введите пароль для пользователя $username: " userpass
echo
read -sp "Повторите пароль: " userpass2
echo
[[ "$userpass" != "$userpass2" ]] && error "Пароли не совпадают."

echo
warn "Сейчас нужно указать диск для установки системы (SSD). ВСЕ ДАННЫЕ НА НЁМ БУДУТ УДАЛЕНЫ."
system_disk=$(select_disk "Выберите диск для системы (SSD):")
echo "Выбран системный диск: $system_disk"

echo
warn "Теперь укажите ДОПОЛНИТЕЛЬНЫЕ диски (HDD), которые будут отформатированы и автоматически смонтированы."
echo "Если дополнительных дисков нет, просто нажмите Enter."
extra_disks=()
while true; do
    read -p "Добавить диск для хранения (оставьте пустым для завершения): " disk
    [[ -z "$disk" ]] && break
    if [[ -b "$disk" ]]; then
        extra_disks+=("$disk")
        echo "Добавлен диск $disk"
    else
        echo "Диск $disk не существует, пропускаем."
    fi
done

echo
read -p "Введите имя хоста (например, arch-pc): " hostname
hostname=${hostname:-arch-kde}

# --- Настройка времени ---
info "Настройка часового пояса (Europe/Moscow)..."
timedatectl set-ntp true
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime

# --- Разметка системного диска (SSD) ---
info "Разметка системного диска $system_disk (GPT, UEFI)..."
wipefs -a "$system_disk"
parted "$system_disk" mklabel gpt
parted "$system_disk" mkpart primary fat32 1MiB 513MiB
parted "$system_disk" set 1 esp on
parted "$system_disk" mkpart primary ext4 513MiB 100%
partprobe "$system_disk"

boot_part="${system_disk}1"
root_part="${system_disk}2"
if [[ "$system_disk" == *"nvme"* ]]; then
    boot_part="${system_disk}p1"
    root_part="${system_disk}p2"
fi

info "Форматирование разделов..."
mkfs.fat -F32 "$boot_part"
mkfs.ext4 -F "$root_part"

# Монтируем корень и boot
mount "$root_part" /mnt
mkdir /mnt/boot
mount "$boot_part" /mnt/boot

# --- Установка базовой системы ---
info "Установка базовой системы (это займёт некоторое время)..."
pacstrap /mnt base base-devel linux linux-firmware vim nano sudo networkmanager grub efibootmgr

# Генерация fstab
genfstab -U /mnt >> /mnt/etc/fstab

# --- chroot и настройка ---
info "Настройка системы в chroot..."
arch-chroot /mnt /bin/bash <<EOF

# Часовой пояс и аппаратные часы
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

# Локали
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Имя хоста
echo "$hostname" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain $hostname
HOSTS

# Пароль root
echo "root:root" | chpasswd

# Создание пользователя
useradd -m -G wheel,audio,video,storage -s /bin/bash "$username"
echo "$username:$userpass" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Установка KDE Plasma и дополнительных пакетов
pacman -S --noconfirm plasma-meta sddm konsole dolphin ark gwenview \
    bluez bluez-utils blueman pipewire pipewire-pulse wireplumber \
    git base-devel grub-customizer

# Включение служб
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable sddm

# --- Настройка Bluetooth (включение и автозапуск) ---
mkdir -p /etc/bluetooth
sed -i 's/^#AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf

# --- Настройка переключения раскладки Alt+Shift ---
mkdir -p /home/$username/.config
cat > /home/$username/.config/kxkbrc <<KXKBRC
[Layout]
LayoutList=us,ru
Model=pc105
Options=grp:alt_shift_toggle
ResetOldOptions=true
KXKBRC
chown -R $username:$username /home/$username/.config

# Также установим системную опцию XKB для консоли и всех пользователей
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<XKB
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us,ru"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
XKB

# --- Установка темы для SDDM (Sugar Dark) ---
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

# --- Установка темы для GRUB (Vimix) ---
git clone https://github.com/Se7endS/grub-vimix /tmp/grub-vimix
mkdir -p /boot/grub/themes
cp -r /tmp/grub-vimix/Vimix /boot/grub/themes/
echo 'GRUB_THEME="/boot/grub/themes/Vimix/theme.txt"' >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

EOF

# --- Добавление дополнительных HDD в fstab (автомонтирование) ---
if [[ ${#extra_disks[@]} -gt 0 ]]; then
    info "Настройка автоматического монтирования дополнительных дисков..."
    mount_point_index=1
    for disk in "${extra_disks[@]}"; do
        # Создаём один раздел на весь диск
        info "Форматирование $disk ..."
        wipefs -a "$disk"
        parted "$disk" mklabel gpt
        parted "$disk" mkpart primary ext4 1MiB 100%
        partprobe "$disk"
        local part="${disk}1"
        if [[ "$disk" == *"nvme"* ]]; then
            part="${disk}p1"
        fi
        mkfs.ext4 -F "$part"
        UUID=$(blkid -s UUID -o value "$part")
        mount_point="/mnt/storage$mount_point_index"
        mkdir -p "/mnt$mount_point"
        echo "UUID=$UUID $mount_point ext4 defaults,noatime 0 2" >> /mnt/etc/fstab
        ((mount_point_index++))
    done
    # Монтируем их сразу
    arch-chroot /mnt mount -a
fi

# --- Завершение ---
info "Установка завершена. Отмонтируем и перезагрузимся."
umount -R /mnt
echo -e "${GREEN}Готово! Перезагрузите компьютер (reboot) и извлеките установочную флешку.${NC}"