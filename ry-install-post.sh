#!/bin/bash
# ry-install Calamares post-install hook
# Runs in chroot of installed system via shellprocess module
# v3.8.0 — 2026-03-19
set -euo pipefail

# Log to persistent file for debugging; preserve stdout/stderr separation so
# Calamares can distinguish info from errors.
LOG="/var/log/ry-install-post.log"
exec > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)

log() { echo "[ry-install-post] $*"; }
warn() { echo "[ry-install-post] WARN: $*" >&2; }

# 1. Generate /etc/kernel/cmdline (runtime UUID + kernel params)
# NOTE: sdboot-manage reads LINUX_OPTIONS from /etc/sdboot-manage.conf (static
# overlay) for boot entry generation — it does NOT read /etc/kernel/cmdline.
# This file is written for:
#   - UKI compatibility (mkinitcpio reads it when building unified images)
#   - Direct kernel boot fallback (systemd-boot reads it as last resort)
#   - Diagnostic reference (ry-install --verify-runtime checks it)
# Root UUID is NOT needed in LINUX_OPTIONS — sdboot-manage auto-detects it.
log "Generating /etc/kernel/cmdline..."
UUID=$(findmnt -no UUID / 2>/dev/null) || true
# Fallback: parse /etc/fstab (written by Calamares before shellprocess runs)
# Do NOT use `mount | awk` — inside chroot it resolves the host root, not the target.
if [ -z "$UUID" ]; then
    UUID=$(awk '$2 == "/" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' /etc/fstab 2>/dev/null) || true
fi
if [ -z "$UUID" ]; then
    # Last resort: blkid on the device from fstab
    ROOT_DEV=$(awk '$2 == "/" { print $1; exit }' /etc/fstab 2>/dev/null) || true
    if [ -n "$ROOT_DEV" ]; then
        UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null) || true
    fi
fi
if [ -z "$UUID" ]; then
    warn "Cannot detect root UUID — /etc/kernel/cmdline not written"
    warn "CRITICAL: System may not boot; manually create /etc/kernel/cmdline"
else
    # 18 params — injected by setup.fish at build time via @@KERNEL_PARAMS@@ placeholder.
    PARAMS="@@KERNEL_PARAMS@@"
    # Guard: abort if setup.fish failed to replace the placeholder
    if [[ "$PARAMS" == *"@@"* ]]; then
        warn "CRITICAL: KERNEL_PARAMS placeholder was not replaced by setup.fish"
        warn "CRITICAL: /etc/kernel/cmdline not written — system may not boot"
    else
        echo "rw root=UUID=${UUID} ${PARAMS}" > /etc/kernel/cmdline
        # Read-back verification
        if [ -f /etc/kernel/cmdline ]; then
            WRITTEN=$(cat /etc/kernel/cmdline)
            if [[ "$WRITTEN" == *"UUID=${UUID}"* ]]; then
                log "Written /etc/kernel/cmdline with UUID=$UUID"
            else
                warn "CRITICAL: /etc/kernel/cmdline read-back mismatch"
                warn "Expected UUID=$UUID, got: $WRITTEN"
            fi
        else
            warn "CRITICAL: /etc/kernel/cmdline not created"
        fi
    fi
fi

# 1b. Verify LINUX_OPTIONS in /etc/sdboot-manage.conf (authoritative for boot entries)
# The static overlay should already contain the correct LINUX_OPTIONS. This is a safety
# net: if the overlay was stale or missing, inject params here so sdboot-manage gen (step 6)
# produces correct boot entries.
SDBOOT_CONF="/etc/sdboot-manage.conf"
if [ -f "$SDBOOT_CONF" ]; then
    CURRENT_OPTS=$(grep '^LINUX_OPTIONS=' "$SDBOOT_CONF" 2>/dev/null || true)
    if [ -z "$CURRENT_OPTS" ]; then
        warn "LINUX_OPTIONS not found in $SDBOOT_CONF — injecting from build-time params"
        if [[ -n "${PARAMS:-}" && "$PARAMS" != *"@@"* ]]; then
            echo "LINUX_OPTIONS=\"${PARAMS}\"" >> "$SDBOOT_CONF"
            log "Appended LINUX_OPTIONS to $SDBOOT_CONF"
        else
            warn "No valid PARAMS available to inject"
        fi
    else
        log "Verified: $CURRENT_OPTS"
    fi
else
    warn "$SDBOOT_CONF not found — sdboot-manage gen may produce incomplete boot entries"
fi

# 2. Mask services — injected by setup.fish at build time via @@MASK@@ placeholder.
log "Masking services..."
MASK_LIST="@@MASK@@"
if [[ "$MASK_LIST" == *"@@"* ]]; then
    warn "CRITICAL: MASK placeholder was not replaced by setup.fish"
else
    MASKED=0
    for svc in $MASK_LIST; do
        if systemctl mask "$svc"; then
            MASKED=$((MASKED + 1))
        else
            warn "Failed to mask $svc"
        fi
    done
    log "Masked $MASKED service(s)"
fi

# 3. Enable services
log "Enabling services..."
ENABLED=0
for svc in amdgpu-performance.service cpupower-epp.service fstrim.timer NetworkManager-dispatcher.service; do
    if systemctl enable "$svc"; then
        ENABLED=$((ENABLED + 1))
    else
        warn "Failed to enable $svc"
    fi
done
log "Enabled $ENABLED/4 service(s)"

# 4. Remove conflicting packages — injected by setup.fish at build time via @@PKGS_DEL@@ placeholder.
# power-profiles-daemon moved to MASK in v3.1.0 (prevents dep reinstallation conflicts)
# Single call lets pacman resolve dependency order (e.g., cachyos-plymouth-bootanimation
# depends on plymouth — removing both at once avoids reverse-dep failures).
log "Removing conflicting packages..."
PKGS_DEL="@@PKGS_DEL@@"
if [[ "$PKGS_DEL" == *"@@"* ]]; then
    warn "CRITICAL: PKGS_DEL placeholder was not replaced by setup.fish"
else
    # Filter to only installed packages
    PKGS_INSTALLED=""
    for pkg in $PKGS_DEL; do
        if pacman -Qi "$pkg" &>/dev/null; then
            PKGS_INSTALLED="$PKGS_INSTALLED $pkg"
        fi
    done
    PKGS_INSTALLED="${PKGS_INSTALLED# }"

    if [ -n "$PKGS_INSTALLED" ]; then
        log "Installed targets: $PKGS_INSTALLED"
        # shellcheck disable=SC2086
        if ! pacman -Rns --noconfirm $PKGS_INSTALLED; then
            warn "Batch removal failed — falling back to per-package removal"
            for pkg in $PKGS_INSTALLED; do
                pacman -Rns --noconfirm "$pkg" || warn "Failed to remove $pkg"
            done
        fi
    else
        log "No conflicting packages installed — nothing to remove"
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
