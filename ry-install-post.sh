#!/bin/bash
# ry-install Calamares post-install hook
# Runs as root in the chroot of the installed system via the shellprocess module
# v7.195.0 — 2026-08-30
set -euo pipefail

# Log to a persistent file for debugging; keep stdout/stderr separated so
# Calamares can distinguish info from errors.
# NOTE: Two tee processes write to the same file — line interleaving is
# theoretically possible under extreme load but negligible in practice
# (line-buffered writes, low output volume).
LOG="/var/log/ry-install-post.log"
exec > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)

log() { echo "[ry-install-post] $*"; }
warn() { echo "[ry-install-post] WARN: $*" >&2; }

STAGE="/usr/local/share/ry-install"
SYSDIR="$STAGE/system"

# ry-install.fish refuses to run as root and ry-verify.fish needs an interactive
# sudo, so neither can drive this stage. The profile is applied from the staged
# bytes plus profile.env, both produced by setup.fish from the same script.
if [ ! -r "$STAGE/profile.env" ]; then
    warn "CRITICAL: $STAGE/profile.env missing — setup.fish did not stage the profile"
    exit 1
fi
# shellcheck source=/dev/null
. "$STAGE/profile.env"
log "profile.env v${RY_VERSION:-unknown} loaded"

for v in RY_KERNEL_PARAMS RY_MASK RY_ENABLE RY_PKGS_DEL; do
    if [ -z "${!v:-}" ]; then
        warn "CRITICAL: $v empty in profile.env"
        exit 1
    fi
done

# 1. Install the staged managed configs
# Staged rather than overlaid: /boot in the airootfs is the live ISO's boot
# directory, not the target ESP, and an /etc overlay would also apply the
# profile to the live environment. Modes mirror ry-install: system files 0644.
log "Installing staged configs from $SYSDIR..."
if [ ! -d "$SYSDIR" ]; then
    warn "CRITICAL: $SYSDIR missing — no configs to install"
    exit 1
fi
INSTALLED=0
STAGED_TOTAL=0
while IFS= read -r -d '' src; do
    STAGED_TOTAL=$((STAGED_TOTAL + 1))
    dst="${src#"$SYSDIR"}"
    if install -D -m 0644 -- "$src" "$dst"; then
        INSTALLED=$((INSTALLED + 1))
    else
        warn "Failed to install $dst"
    fi
done < <(find "$SYSDIR" -type f -print0)
log "Installed $INSTALLED/$STAGED_TOTAL staged configs"
if [ "$INSTALLED" -ne "$STAGED_TOTAL" ]; then
    warn "CRITICAL: not every managed config was installed — verify before rebooting"
fi

# 2. Generate /etc/kernel/cmdline (runtime UUID + kernel params)
# NOTE: sdboot-manage reads LINUX_OPTIONS from /etc/sdboot-manage.conf (staged
# above) for boot entry generation — it does NOT read /etc/kernel/cmdline.
# This file is written for:
#   - UKI compatibility (mkinitcpio reads it when building unified images)
#   - Direct kernel boot fallback (systemd-boot reads it as a last resort)
#   - Diagnostic reference (ry-verify --verify checks it)
# The root UUID is not needed in LINUX_OPTIONS — sdboot-manage detects it.
log "Generating /etc/kernel/cmdline..."
UUID=$(findmnt -no UUID / 2>/dev/null) || true
# Fallback: parse /etc/fstab (written by Calamares before shellprocess runs).
# Do NOT use `mount | awk` — inside the chroot it resolves the host root.
if [ -z "$UUID" ]; then
    UUID=$(awk '$2 == "/" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' /etc/fstab 2>/dev/null) || true
fi
if [ -z "$UUID" ]; then
    # Last resort: blkid on the device named by fstab
    ROOT_DEV=$(awk '$2 == "/" { print $1; exit }' /etc/fstab 2>/dev/null) || true
    if [ -n "$ROOT_DEV" ]; then
        UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null) || true
    fi
fi
if [ -z "$UUID" ]; then
    warn "CRITICAL: cannot detect the root UUID — /etc/kernel/cmdline not written"
    warn "CRITICAL: the system may not boot; create /etc/kernel/cmdline by hand"
else
    install -d -m 0755 /etc/kernel
    printf 'rw root=UUID=%s %s\n' "$UUID" "$RY_KERNEL_PARAMS" > /etc/kernel/cmdline
    chmod 0644 /etc/kernel/cmdline
    WRITTEN=$(cat /etc/kernel/cmdline 2>/dev/null || true)
    if [[ "$WRITTEN" == *"UUID=${UUID}"* ]]; then
        log "Wrote /etc/kernel/cmdline with UUID=$UUID"
    else
        warn "CRITICAL: /etc/kernel/cmdline read-back mismatch"
        warn "Expected UUID=$UUID, got: $WRITTEN"
    fi
fi

# 3. Verify LINUX_OPTIONS in /etc/sdboot-manage.conf (authoritative for entries)
# The staged file already carries it. This is the safety net for a stale stage.
SDBOOT_CONF="/etc/sdboot-manage.conf"
if [ -f "$SDBOOT_CONF" ]; then
    CURRENT_OPTS=$(grep '^[#[:space:]]*LINUX_OPTIONS=' "$SDBOOT_CONF" 2>/dev/null || true)
    if [ -z "$CURRENT_OPTS" ]; then
        warn "LINUX_OPTIONS not found in $SDBOOT_CONF — injecting from profile.env"
        printf 'LINUX_OPTIONS="%s"\n' "$RY_KERNEL_PARAMS" >> "$SDBOOT_CONF"
        log "Appended LINUX_OPTIONS to $SDBOOT_CONF"
    else
        log "Verified: $CURRENT_OPTS"
    fi
else
    warn "$SDBOOT_CONF not found — sdboot-manage gen may produce incomplete entries"
fi

# 4. Apply the ext4 mount options ry-verify expects
# Calamares writes /etc/fstab before shellprocess runs. The rewrite below is the
# same contract ry-install applies: ext4 rows gain noatime,lazytime,commit=10 and
# lose defaults/relatime/atime/strictatime; every other row is byte-preserved.
log "Applying ext4 mount options to /etc/fstab..."
if [ -f /etc/fstab ]; then
    FSTAB_TMP=$(mktemp)
    if awk '
/^[ \t]*#/ || NF < 4 { print; next }
$3 != "ext4" { print; next }
$4 ~ /^[0-9]+$/ { print; next }
$4 ~ /(^|,)noatime(,|$)/ && $4 ~ /(^|,)lazytime(,|$)/ && $4 ~ /(^|,)commit=10(,|$)/ && $4 !~ /(^|,)(defaults|relatime|atime|strictatime)(,|$)/ { print; next }
{
    n = split($4, opts, ",")
    has_noat = 0; has_lazy = 0; out = ""
    for (i = 1; i <= n; i++) {
        o = opts[i]
        if (o == "") continue
        if (o == "relatime" || o == "atime" || o == "strictatime") continue
        if (o == "defaults") continue
        if (o ~ /^commit=/) continue
        if (o == "noatime") has_noat = 1
        if (o == "lazytime") has_lazy = 1
        out = (out == "" ? o : out "," o)
    }
    if (!has_noat)  out = (out == "" ? "noatime"  : out ",noatime")
    if (!has_lazy)  out = (out == "" ? "lazytime" : out ",lazytime")
    out = (out == "" ? "commit=10" : out ",commit=10")
    pos = 1
    for (f = 1; f <= 3; f++) {
        match(substr($0, pos), /[^ \t]+/); pos += RSTART + RLENGTH - 1
        match(substr($0, pos), /[ \t]+/);  pos += RSTART + RLENGTH - 1
    }
    match(substr($0, pos), /[^ \t]+/)
    print substr($0, 1, pos + RSTART - 2) out substr($0, pos + RSTART + RLENGTH - 1)
}' /etc/fstab > "$FSTAB_TMP" && [ -s "$FSTAB_TMP" ]; then
        cp -- /etc/fstab /etc/fstab.ry.bak
        cat -- "$FSTAB_TMP" > /etc/fstab
        log "fstab rewritten (backup at /etc/fstab.ry.bak)"
    else
        warn "fstab rewrite produced no output — leaving /etc/fstab untouched"
    fi
    rm -f "$FSTAB_TMP"
else
    warn "/etc/fstab not found — skipping mount-option rewrite"
fi

# 5. Drop live-ISO-only initramfs configuration
# archiso.conf pins the live HOOKS list and is sourced after /etc/mkinitcpio.conf,
# so it would override the staged HOOKS on the installed system.
ARCHISO_MKI="/etc/mkinitcpio.conf.d/archiso.conf"
if [ -f "$ARCHISO_MKI" ]; then
    rm -f "$ARCHISO_MKI"
    log "Removed $ARCHISO_MKI (live-environment override)"
fi

# 6. Mask services
log "Masking services..."
MASKED=0
# shellcheck disable=SC2086
for svc in $RY_MASK; do
    # Plain mask, not `mask --now`: there is no running systemd in the chroot.
    if systemctl mask "$svc"; then
        MASKED=$((MASKED + 1))
    else
        warn "Failed to mask $svc"
    fi
done
log "Masked $MASKED service(s)"

# 7. Enable services
log "Enabling services..."
ENABLED=0
ENABLE_TOTAL=0
# shellcheck disable=SC2086
for svc in $RY_ENABLE; do
    ENABLE_TOTAL=$((ENABLE_TOTAL + 1))
    if systemctl enable "$svc"; then
        ENABLED=$((ENABLED + 1))
    else
        warn "Failed to enable $svc"
    fi
done
log "Enabled $ENABLED/$ENABLE_TOTAL service(s)"

# 8. Re-mark the profile's own packages explicit, then remove the conflicting set
# Mirrors ry-install: -D --asexplicit first so a later -Rns cannot orphan a
# PKGS_ADD member that arrived as someone else's dependency.
if [ -n "${RY_PKGS_ADD:-}" ]; then
    PKGS_PRESENT=""
    # shellcheck disable=SC2086
    for pkg in $RY_PKGS_ADD; do
        if pacman -Qi "$pkg" &>/dev/null; then
            PKGS_PRESENT="$PKGS_PRESENT $pkg"
        fi
    done
    PKGS_PRESENT="${PKGS_PRESENT# }"
    if [ -n "$PKGS_PRESENT" ]; then
        # shellcheck disable=SC2086
        pacman -D --asexplicit -- $PKGS_PRESENT >/dev/null || warn "pacman -D --asexplicit reported an error"
        log "Marked explicit: $PKGS_PRESENT"
    fi
fi

log "Removing conflicting packages..."
PKGS_INSTALLED=""
# shellcheck disable=SC2086
for pkg in $RY_PKGS_DEL; do
    if pacman -Qi "$pkg" &>/dev/null; then
        PKGS_INSTALLED="$PKGS_INSTALLED $pkg"
    fi
done
PKGS_INSTALLED="${PKGS_INSTALLED# }"
if [ -n "$PKGS_INSTALLED" ]; then
    log "Installed targets: $PKGS_INSTALLED"
    # Single call so pacman resolves the removal order (a bootanimation package
    # depends on plymouth — removing both at once avoids a reverse-dep failure).
    # shellcheck disable=SC2086
    if ! pacman -Rns --noconfirm -- $PKGS_INSTALLED; then
        warn "Batch removal failed — falling back to per-package removal"
        for pkg in $PKGS_INSTALLED; do
            pacman -Rns --noconfirm -- "$pkg" || warn "Failed to remove $pkg"
        done
    fi
else
    log "No conflicting packages installed — nothing to remove"
fi

# 9. Rebuild the initramfs
log "Rebuilding initramfs..."
if ! mkinitcpio -P; then
    warn "CRITICAL: mkinitcpio failed — the system may not boot"
    exit 1
fi

# 10. Regenerate the boot entries
log "Updating bootloader..."
if ! command -v sdboot-manage &>/dev/null; then
    warn "CRITICAL: sdboot-manage not found"
    exit 1
fi
if ! sdboot-manage gen; then
    warn "CRITICAL: sdboot-manage gen failed"
    exit 1
fi
if ! sdboot-manage update; then
    warn "sdboot-manage update failed — the boot manager may be stale"
fi

log "Post-install complete — verify after reboot with: ry-verify.fish --verify"

# Flush the process-substitution tee pipes before exit so the log file captures
# all output. Without this, bash may exit before the background tee processes
# drain their buffers. Close both inherited FDs to signal EOF, then wait.
# `|| true` keeps set -e from aborting if a tee exits non-zero (a full log
# filesystem, say) — the install itself already succeeded.
exec 1>&- 2>&-
wait || true
exit 0
