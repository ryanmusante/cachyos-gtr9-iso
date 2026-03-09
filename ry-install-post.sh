#!/bin/bash
# ry-install Calamares post-install hook
# Runs in chroot of installed system via shellprocess module
# v3.5.2 — 2026-03-07
set -euo pipefail

log() { echo "[ry-install-post] $*"; }
warn() { echo "[ry-install-post] WARN: $*" >&2; }

# 1. Generate /etc/kernel/cmdline (only file needing runtime UUID)
log "Generating /etc/kernel/cmdline..."
UUID=$(findmnt -no UUID / 2>/dev/null) || true
# Fallback: Calamares may not bind-mount /proc before shellprocess
if [ -z "$UUID" ]; then
    UUID=$(blkid -s UUID -o value "$(mount | awk '$3 == "/" {print $1; exit}')" 2>/dev/null) || true
fi
if [ -z "$UUID" ]; then
    warn "Cannot detect root UUID — /etc/kernel/cmdline not written"
    warn "CRITICAL: System may not boot; manually create /etc/kernel/cmdline"
else
    # 18 params — synced to ry-install v3.5.2 KERNEL_PARAMS
    PARAMS="amd_iommu=off amd_pstate=active amdgpu.aspm=0 amdgpu.cwsr_enable=0 amdgpu.gpu_recovery=1 amdgpu.modeset=1 amdgpu.ppfeaturemask=0xfffd3fff amdgpu.runpm=0 audit=0 initcall_blacklist=simpledrm_platform_driver_init mt7925e.disable_aspm=1 nowatchdog nvme_core.default_ps_max_latency_us=0 pci=pcie_bus_perf quiet split_lock_detect=off usbcore.autosuspend=-1 zswap.enabled=0"
    echo "rw root=UUID=${UUID} ${PARAMS}" > /etc/kernel/cmdline
    log "Written /etc/kernel/cmdline with UUID=$UUID"
fi

# 2. Mask services — synced to ry-install v3.5.2 MASK (9 entries, unconditional)
# Note: systemctl mask/enable work in offline/chroot mode without a running daemon.
# No daemon-reload needed — there is no running systemd PID 1 in the Calamares chroot.
log "Masking services..."
MASK_LIST="ananicy-cpp.service power-profiles-daemon.service lvm2-monitor.service NetworkManager-wait-online.service sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"

for svc in $MASK_LIST; do
    systemctl mask "$svc" 2>/dev/null || warn "Failed to mask $svc"
done

# 3. Enable services
log "Enabling services..."
systemctl enable amdgpu-performance.service  || warn "Failed to enable amdgpu-performance"
systemctl enable cpupower-epp.service        || warn "Failed to enable cpupower-epp"
systemctl enable fstrim.timer                || warn "Failed to enable fstrim.timer"
systemctl enable NetworkManager-dispatcher.service || warn "Failed to enable NM-dispatcher"

# 4. Remove conflicting packages — synced to ry-install v3.5.2 PKGS_DEL (7 entries)
# power-profiles-daemon moved to MASK in v3.1.0 (prevents dep reinstallation conflicts)
# Single call lets pacman resolve dependency order (e.g., cachyos-plymouth-bootanimation
# depends on plymouth — removing both at once avoids reverse-dep failures).
log "Removing conflicting packages..."
PKGS_DEL="plymouth cachyos-plymouth-bootanimation ufw octopi micro cachyos-micro-settings btop"

# Filter to only installed packages
PKGS_INSTALLED=""
for pkg in $PKGS_DEL; do
    if pacman -Qi "$pkg" &>/dev/null; then
        PKGS_INSTALLED="$PKGS_INSTALLED $pkg"
    fi
done
PKGS_INSTALLED="${PKGS_INSTALLED# }"

if [ -n "$PKGS_INSTALLED" ]; then
    # shellcheck disable=SC2086
    if ! pacman -Rns --noconfirm $PKGS_INSTALLED 2>/dev/null; then
        warn "Batch removal failed — falling back to per-package removal"
        for pkg in $PKGS_INSTALLED; do
            pacman -Rns --noconfirm "$pkg" 2>/dev/null || warn "Failed to remove $pkg"
        done
    fi
fi

# 5. Rebuild initramfs
log "Rebuilding initramfs..."
if ! mkinitcpio -P; then
    warn "CRITICAL: mkinitcpio failed — system may not boot"
    exit 1
fi

# 6. Regenerate boot entries
log "Updating bootloader..."
if ! command -v sdboot-manage &>/dev/null; then
    warn "CRITICAL: sdboot-manage not found"
    exit 1
fi
if ! sdboot-manage gen; then
    warn "CRITICAL: sdboot-manage gen failed"
    exit 1
fi
sdboot-manage update || warn "sdboot-manage update failed"

log "Post-install complete"
exit 0
