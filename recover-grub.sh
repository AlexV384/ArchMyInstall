#!/bin/bash
# GRUB recovery script for Arch Linux + Windows dual-boot
# Run from Arch live USB after Windows installation.

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success(){ echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[⚠]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || error "Run with root: sudo $0"
ping -c 2 -W 5 archlinux.org &>/dev/null || error "No internet."

# Find root partition (ext4 with label ARCH_ROOT or ask)
root_part=$(blkid -L ARCH_ROOT 2>/dev/null || true)
[[ -z "$root_part" ]] && {
    warn "ARCH_ROOT label not found. Trying to find ext4 root..."
    root_part=$(blkid -t TYPE=ext4 -o device | head -1)
    [[ -z "$root_part" ]] && error "Cannot find root partition."
    warn "Using $root_part as root (label not set)."
}
success "Root partition: $root_part"

# Find EFI partition (vfat with label ARCH_EFI)
efi_part=$(blkid -L ARCH_EFI 2>/dev/null || true)
[[ -z "$efi_part" ]] && {
    warn "ARCH_EFI label not found. Trying to find EFI..."
    efi_part=$(blkid -t TYPE=vfat -o device | head -1)
    [[ -z "$efi_part" ]] && error "Cannot find EFI partition."
    warn "Using $efi_part as EFI."
}
success "EFI partition: $efi_part"

mount "$root_part" /mnt
mount "$efi_part" /mnt/boot

log "Reinstalling GRUB..."
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck

log "Detecting other OS..."
arch-chroot /mnt os-prober

log "Updating GRUB config..."
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

umount -R /mnt
success "GRUB recovery complete. Reboot and you'll see Windows in the menu."