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

# Check internet (try repo, not just ping)
if ! timeout 10 bash -c '</dev/tcp/archlinux.org/443' 2>/dev/null; then
    ping -c 2 -W 5 archlinux.org &>/dev/null || error "No internet."
fi

[[ -d /sys/firmware/efi ]] || error "System must be booted in UEFI mode."

# Verify efibootmgr is available in the live environment
command -v efibootmgr >/dev/null || pacman -Syy --needed --noconfirm efibootmgr >/dev/null 2>&1 || warn "efibootmgr not found — skipping EFI entry verification."

# Clean up any leftover mount from a previous interrupted run
umount -R /mnt 2>/dev/null || true

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

# Ensure os-prober is installed for Windows detection
arch-chroot /mnt pacman -S --needed --noconfirm os-prober >/dev/null 2>&1 || warn "os-prober could not be installed."

# Enable os-prober in GRUB config if not already enabled
grep -q "^GRUB_DISABLE_OS_PROBER=false" /mnt/etc/default/grub || \
    echo "GRUB_DISABLE_OS_PROBER=false" >> /mnt/etc/default/grub

log "Reinstalling GRUB..."
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck || error "GRUB reinstall failed."

# Verify the EFI boot entry was created
log "Verifying EFI boot entry..."
if command -v efibootmgr >/dev/null && efibootmgr -v 2>/dev/null | grep -q "GRUB"; then
    success "GRUB EFI entry found in firmware."
else
    warn "GRUB EFI entry not found. It may be named differently."
fi

# Backup existing grub.cfg before regenerating
if arch-chroot /mnt test -f /boot/grub/grub.cfg; then
    arch-chroot /mnt cp /boot/grub/grub.cfg /boot/grub/grub.cfg.bak
    success "Backed up previous grub.cfg to grub.cfg.bak"
fi

log "Updating GRUB config..."
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg || error "grub-mkconfig failed."

umount -R /mnt || true
success "GRUB recovery complete. Reboot and you'll see Windows in the menu."