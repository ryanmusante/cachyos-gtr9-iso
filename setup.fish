#!/usr/bin/env fish
# setup.fish — Prepare custom CachyOS ISO build tree
# Requires: running GTR9 Pro with ry-install applied, git, sudo
# v3.5.2 — 2026-03-07

set -g VERSION "3.5.2"
set -g SCRIPT_DIR (status dirname)
set -g ISO_DIR "$SCRIPT_DIR/cachyos-custom-iso"
set -g AIROOTFS "$ISO_DIR/archiso/airootfs"

# ── Colors ──────────────────────────────────────────────

set -g NO_COLOR (test -n "$NO_COLOR"; and echo true; or echo false)

function _c
    test "$NO_COLOR" = true; and return
    isatty stdout; or return
    set_color $argv
end

function _info
    _c blue; echo "  [INFO] $argv"; _c normal
end

function _ok
    _c green; echo "  [OK]   $argv"; _c normal
end

function _warn
    _c yellow; echo "  [WARN] $argv"; _c normal
end

function _err
    _c red; echo "  [FAIL] $argv"; _c normal
end

function _step
    _c cyan; echo ""; echo "══ $argv ══"; _c normal
end

# ── Options ─────────────────────────────────────────────

argparse 'h/help' 'v/version' 'dry-run' 'force' -- $argv
or begin
    echo "Usage: setup.fish [--dry-run] [--force]"
    exit 2
end

if set -q _flag_help
    echo "setup.fish v$VERSION — Prepare custom CachyOS ISO build tree"
    echo ""
    echo "Usage: setup.fish [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run    Preview changes without modifying anything"
    echo "  --force      Overwrite existing ISO directory"
    echo "  -h, --help   Show this help"
    echo "  -v, --version Show version"
    exit 0
end

if set -q _flag_version
    echo "setup.fish v$VERSION"
    exit 0
end

set -g DRY false
if set -q _flag_dry_run
    set -g DRY true
    _warn "DRY RUN — no changes will be made"
end

# ── Helpers ─────────────────────────────────────────────

function _cp
    # _cp SOURCE DEST [--sudo]
    set -l src $argv[1]
    set -l dst $argv[2]
    set -l use_sudo false
    test (count $argv) -ge 3; and test "$argv[3]" = "--sudo"
    and set use_sudo true

    if not test -f "$src"
        _warn "source missing, skipping: $src"
        return 1
    end

    if test "$DRY" = true
        _info "would copy: $src → $dst"
        return 0
    end

    mkdir -p (dirname "$dst")
    if test "$use_sudo" = true
        sudo cp -- "$src" "$dst"
    else
        cp -- "$src" "$dst"
    end
    or begin
        _err "copy failed: $src → $dst"
        return 1
    end
    _ok "copied: $src → $dst"
end

# ── Preflight ───────────────────────────────────────────

_step "Preflight checks"

# Must run from bundle directory
if not test -d "$SCRIPT_DIR/overlay"
    _err "Run from the bundle directory (overlay/ not found)"
    exit 1
end

# Check ry-install exists
set -g RY_INSTALL ""
if test -f "$HOME/ry-install/ry-install.fish"
    set -g RY_INSTALL "$HOME/ry-install/ry-install.fish"
else if test -f "$SCRIPT_DIR/../ry-install.fish"
    set -g RY_INSTALL "$SCRIPT_DIR/../ry-install.fish"
end

if test -z "$RY_INSTALL"
    _err "ry-install.fish not found at ~/ry-install/ or parent directory"
    exit 1
end
_ok "ry-install.fish: $RY_INSTALL"

# Verify ry-install version matches this bundle
set -l ry_version (grep '^set -g VERSION ' "$RY_INSTALL" | string replace -r 'set -g VERSION "([^"]+)"' '$1')
if test "$ry_version" != "$VERSION"
    _warn "ry-install version mismatch: $ry_version (expected $VERSION)"
end

# Check running system has configs deployed (ry-install --verify-static would be ideal)
set -l check_files \
    /boot/loader/loader.conf \
    /etc/sdboot-manage.conf \
    /etc/mkinitcpio.conf \
    /etc/modprobe.d/99-cachyos-modprobe.conf \
    /etc/sysctl.d/99-ry-sysctl.conf \
    /etc/systemd/system/amdgpu-performance.service
set -l missing 0
for f in $check_files
    if not test -f "$f"
        _warn "missing on running system: $f"
        set missing (math $missing + 1)
    end
end
if test $missing -gt 0
    _err "Run ry-install.fish --all first, then re-run this setup"
    exit 1
end
_ok "running system configs present"

# Check git
command -q git; or begin; _err "git not found"; exit 1; end

# Check target dir
if test -d "$ISO_DIR"
    if set -q _flag_force
        _warn "removing existing $ISO_DIR"
        test "$DRY" = false; and rm -rf "$ISO_DIR"
    else
        _err "$ISO_DIR already exists (use --force to overwrite)"
        exit 1
    end
end

_ok "preflight complete"

# ── Step 1: Clone ───────────────────────────────────────

_step "Step 1: Clone CachyOS-Live-ISO"

if test "$DRY" = true
    _info "would run: git clone CachyOS-Live-ISO → $ISO_DIR"
    _info "would run: git checkout -b gtr9-pro"
else
    git clone https://github.com/CachyOS/CachyOS-Live-ISO.git "$ISO_DIR"
    or begin; _err "git clone failed"; exit 1; end

    cd "$ISO_DIR"
    git checkout -b gtr9-pro 2>/dev/null
    or git checkout gtr9-pro 2>/dev/null
    or begin; _err "git checkout gtr9-pro failed"; exit 1; end
    cd "$SCRIPT_DIR"
    _ok "cloned and branched"
end

# ── Step 2: Create overlay directories ──────────────────

_step "Step 2: Create overlay directories"

# v3.5.2: removed modules-load.d, journald.conf.d, coredump.conf.d; added sysctl.d
set -l dirs \
    boot/loader \
    etc/kernel \
    etc/modprobe.d \
    etc/sysctl.d \
    etc/udev/rules.d \
    etc/systemd/resolved.conf.d \
    etc/systemd/logind.conf.d \
    etc/systemd/system/multi-user.target.wants \
    etc/iwd \
    etc/NetworkManager/conf.d \
    etc/conf.d \
    etc/skel/.config/fish/conf.d \
    etc/skel/.config/environment.d \
    etc/skel/.config/systemd/user \
    etc/calamares/modules \
    usr/local/bin

for d in $dirs
    if test "$DRY" = true
        _info "would mkdir: $AIROOTFS/$d"
    else
        mkdir -p "$AIROOTFS/$d"
    end
end
set -l n (count $dirs)
_ok "$n directories"

# ── Step 3: Copy static configs from running system ─────

_step "Step 3: Copy 16 static configs from running system"

# 12 system configs (excluding /etc/kernel/cmdline — generated at install time)
# v3.5.2: removed modules-load.d, journald.conf.d, coredump.conf.d; added sysctl.d
set -l system_files \
    /boot/loader/loader.conf \
    /etc/sdboot-manage.conf \
    /etc/mkinitcpio.conf \
    /etc/modprobe.d/99-cachyos-modprobe.conf \
    /etc/sysctl.d/99-ry-sysctl.conf \
    /etc/udev/rules.d/99-cachyos-udev.rules \
    /etc/systemd/resolved.conf.d/99-cachyos-resolved.conf \
    /etc/systemd/logind.conf.d/99-cachyos-logind.conf \
    /etc/iwd/main.conf \
    /etc/NetworkManager/conf.d/99-cachyos-nm.conf \
    /etc/conf.d/wireless-regdom

set -l copied 0
for f in $system_files
    _cp "$f" "$AIROOTFS$f" --sudo
    and set copied (math $copied + 1)
end

# 2 service files
for f in /etc/systemd/system/amdgpu-performance.service /etc/systemd/system/cpupower-epp.service
    _cp "$f" "$AIROOTFS$f" --sudo
    and set copied (math $copied + 1)
end

# 3 user files → /etc/skel (NOT $HOME)
_cp "$HOME/.config/fish/conf.d/10-ssh-auth-sock.fish" "$AIROOTFS/etc/skel/.config/fish/conf.d/10-ssh-auth-sock.fish"
and set copied (math $copied + 1)

_cp "$HOME/.config/environment.d/10-environment.conf" "$AIROOTFS/etc/skel/.config/environment.d/10-environment.conf"
and set copied (math $copied + 1)

_cp "$HOME/.config/systemd/user/ssh-agent.service" "$AIROOTFS/etc/skel/.config/systemd/user/ssh-agent.service"
and set copied (math $copied + 1)

_ok "$copied/16 static files copied"
if test $copied -lt 16
    _warn "some files missing — review output above"
end

# ── Step 4: Bundle overlay files ────────────────────────

_step "Step 4: Place bundle overlay files"

# Wrapper scripts
_cp "$SCRIPT_DIR/overlay/usr/local/bin/ry-install-post.sh" \
    "$AIROOTFS/usr/local/bin/ry-install-post.sh"

_cp "$SCRIPT_DIR/overlay/usr/local/bin/ry-install-firstboot.sh" \
    "$AIROOTFS/usr/local/bin/ry-install-firstboot.sh"

# First-boot service unit
_cp "$SCRIPT_DIR/overlay/etc/systemd/system/ry-install-firstboot.service" \
    "$AIROOTFS/etc/systemd/system/ry-install-firstboot.service"

# Calamares shellprocess config
_cp "$SCRIPT_DIR/overlay/etc/calamares/modules/shellprocess-ry-install.conf" \
    "$AIROOTFS/etc/calamares/modules/shellprocess-ry-install.conf"

# ry-install.fish itself
_cp "$RY_INSTALL" "$AIROOTFS/usr/local/bin/ry-install.fish"

# First-boot enable symlink
if test "$DRY" = true
    _info "would symlink: ry-install-firstboot.service → multi-user.target.wants"
else
    ln -sf /etc/systemd/system/ry-install-firstboot.service \
        "$AIROOTFS/etc/systemd/system/multi-user.target.wants/ry-install-firstboot.service"
    _ok "symlink: firstboot → multi-user.target.wants"
end

# Make scripts executable
if test "$DRY" = false
    chmod 755 "$AIROOTFS/usr/local/bin/ry-install-post.sh"
    chmod 755 "$AIROOTFS/usr/local/bin/ry-install-firstboot.sh"
    chmod 755 "$AIROOTFS/usr/local/bin/ry-install.fish"
    _ok "scripts marked executable"
end

# ── Step 5: Modify packages.x86_64 ─────────────────────

_step "Step 5: Modify packages.x86_64"

set -l pkgfile "$ISO_DIR/archiso/packages.x86_64"
if not test -f "$pkgfile"
    _warn "packages.x86_64 not found — check ISO repo structure"
    _warn "you may need to modify Calamares netinstall YAML instead"
else
    # v3.5.2: 15 packages (pipewire-libcamera removed — pulled as dep)
    set -l pkgs_add \
        bat \
        bottom \
        cachyos-gaming-applications \
        cachyos-gaming-meta \
        dust \
        eza \
        fd \
        git-delta \
        iw \
        lm_sensors \
        mkinitcpio-firmware \
        nvme-cli \
        procs \
        sd \
        stress-ng

    # v3.5.2: 7 packages (power-profiles-daemon moved to MASK)
    set -l pkgs_del \
        btop \
        cachyos-micro-settings \
        cachyos-plymouth-bootanimation \
        micro \
        octopi \
        plymouth \
        ufw

    if test "$DRY" = true
        _info "would add to packages.x86_64: $pkgs_add"
        _info "would remove from packages.x86_64: $pkgs_del"
    else
        # Add packages (skip if already present)
        set -l added 0
        for pkg in $pkgs_add
            if not grep -qx "$pkg" "$pkgfile"
                echo "$pkg" >> "$pkgfile"
                set added (math $added + 1)
            end
        end
        _ok "added $added packages"

        # Remove/comment out packages
        set -l removed 0
        for pkg in $pkgs_del
            if grep -qx "$pkg" "$pkgfile"
                sed -i "s/^$pkg\$/#$pkg/" "$pkgfile"
                set removed (math $removed + 1)
            end
        end
        _ok "commented out $removed packages"

        # Sort the file (preserve comment header, re-sort package lines)
        set -l tmp (mktemp)
        grep '^#' "$pkgfile" > "$tmp"
        grep -v '^#' "$pkgfile" | grep -v '^\s*$' | sort -u >> "$tmp"
        mv "$tmp" "$pkgfile"
        _ok "sorted packages.x86_64"
    end
end

# ── Step 6: Modify profiledef.sh ───────────────────────

_step "Step 6: Update profiledef.sh file_permissions"

set -l profiledef "$ISO_DIR/archiso/profiledef.sh"
if not test -f "$profiledef"
    _warn "profiledef.sh not found"
else
    set -l perms \
        '  ["/usr/local/bin/ry-install.fish"]="0:0:755"' \
        '  ["/usr/local/bin/ry-install-post.sh"]="0:0:755"' \
        '  ["/usr/local/bin/ry-install-firstboot.sh"]="0:0:755"'

    if test "$DRY" = true
        _info "would add 3 file_permissions entries to profiledef.sh"
    else
        # Find file_permissions block, then its closing )
        set -l fp_start (grep -n 'file_permissions' "$profiledef" | head -1 | cut -d: -f1)
        if test -n "$fp_start"
            set -l close_line (tail -n +"$fp_start" "$profiledef" | grep -n '^)' | head -1 | cut -d: -f1)
            if test -n "$close_line"
                # close_line is relative to fp_start, convert to absolute
                set close_line (math "$fp_start + $close_line - 1")
                # Write entries to temp file, use sed r to insert before )
                set -l tmp (mktemp)
                for p in $perms
                    echo "$p" >> "$tmp"
                end
                set -l before_close (math "$close_line - 1")
                # GNU sed: r command inserts after line N
                sed -i "$before_close r $tmp" "$profiledef"
                rm -f "$tmp"
                _ok "added 3 file_permissions entries"
            else
                _warn "could not find closing ) for file_permissions — add manually:"
                for p in $perms
                    echo "  $p"
                end
            end
        else
            _warn "file_permissions not found in profiledef.sh — add manually:"
            for p in $perms
                echo "  $p"
            end
        end
    end
end

# ── Step 7: Calamares settings.conf ─────────────────────

_step "Step 7: Register shellprocess@ry-install in Calamares"

set -l settings_files (find "$AIROOTFS" -name 'settings.conf' -path '*/calamares/*' 2>/dev/null)
if test (count $settings_files) -eq 0
    _warn "Calamares settings.conf not found in airootfs"
    _warn "After clone, locate it and add 'shellprocess@ry-install' after bootloader module:"
    _info "  - bootloader"
    _info "  - shellprocess@ry-install    # ← add this"
    _info "  - umount"
else
    for sf in $settings_files
        if test "$DRY" = true
            _info "would insert shellprocess@ry-install in: $sf"
        else
            # Idempotency: skip if already registered
            if grep -q 'shellprocess@ry-install' "$sf"
                _ok "already registered in: $sf"
            else if grep -q '\- bootloader' "$sf"
                # GNU sed 0,/pattern/ range — insert after first occurrence only
                sed -i '0,/- bootloader/{/- bootloader/a\  - shellprocess@ry-install
}' "$sf"
                _ok "inserted in: $sf"
            else
                _warn "no bootloader entry found in: $sf"
                _warn "manually add '  - shellprocess@ry-install' to the exec sequence"
            end
        end
    end
end

# ── Step 8: Also check for netinstall configs ───────────

_step "Step 8: Check for Calamares netinstall configs"

set -l netinstall_files (find "$AIROOTFS" -name 'netinstall*' -path '*/calamares/*' 2>/dev/null)
if test (count $netinstall_files) -gt 0
    _warn "Found Calamares netinstall configs — packages may be installed here too:"
    for nf in $netinstall_files
        _info "  $nf"
    end
    _warn "Review these files for PKGS_ADD/PKGS_DEL overlap"
else
    _ok "no netinstall configs found (packages.x86_64 only)"
end

# ── Summary ─────────────────────────────────────────────

_step "Summary"

echo ""
if test "$DRY" = true
    _warn "DRY RUN complete — no changes were made"
    echo ""
    _info "Re-run without --dry-run to execute"
else
    _ok "ISO build tree ready at: $ISO_DIR"
    echo ""
    echo "  Files placed in airootfs overlay:"

    if test -d "$AIROOTFS"
        set -l file_count (find "$AIROOTFS" -type f | wc -l | string trim)
        echo "    $file_count files total"
    end

    echo ""
    echo "  Next steps:"
    echo "    1. Review the changes:"
    echo "       cd $ISO_DIR"
    echo "       git diff"
    echo "       git status"
    echo ""
    echo "    2. Verify Calamares settings.conf has shellprocess@ry-install"
    echo "       after the bootloader module"
    echo ""
    echo "    3. Install build deps:"
    echo "       sudo pacman -S archiso mkinitcpio-archiso squashfs-tools grub --needed"
    echo ""
    echo "    4. Build the ISO:"
    echo "       cd $ISO_DIR"
    echo "       sudo ./buildiso.sh -p desktop -v -w"
    echo ""
    echo "    5. Test in VM first:"
    echo "       qemu-img create -f qcow2 test-disk.qcow2 40G"
    echo "       cp /usr/share/edk2/x64/OVMF_VARS.4m.fd ovmf-vars.fd"
    echo "       qemu-system-x86_64 -enable-kvm -m 4G -cpu host \\"
    echo "           -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \\"
    echo "           -drive if=pflash,format=raw,file=ovmf-vars.fd \\"
    echo "           -cdrom out/cachyos-desktop-*.iso \\"
    echo "           -drive file=test-disk.qcow2,if=virtio,format=qcow2 -boot d"
    echo ""
    echo "    6. After install + reboot, verify:"
    echo "       ry-install.fish --verify-static"
    echo "       ry-install.fish --verify-runtime"
    echo "       ry-install.fish --diff"
end
