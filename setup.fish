#!/usr/bin/env fish
# setup.fish — Prepare custom CachyOS ISO build tree
# Requires: running GTR9 Pro with ry-install applied, git, sudo
# v3.8.0 — 2026-03-19

set -g VERSION "3.8.0"
set -g SCRIPT_DIR (status dirname)
set -g ISO_DIR "$SCRIPT_DIR/cachyos-custom-iso"
set -g AIROOTFS "$ISO_DIR/archiso/airootfs"
set -g LOCKFILE "$SCRIPT_DIR/.setup.lock"

# ── Colors ──────────────────────────────────────────────

set -g NO_COLOR (test -n "$NO_COLOR"; and echo true; or echo false)

# All progress/status output targets stderr; check isatty stderr for color.
function _c
    test "$NO_COLOR" = true; and return
    isatty stderr; or return
    set_color $argv
end

function _info
    begin; _c blue; echo "  [INFO] $argv"; _c normal; end >&2
end

function _ok
    begin; _c green; echo "  [OK]   $argv"; _c normal; end >&2
end

function _warn
    begin; _c yellow; echo "  [WARN] $argv"; _c normal; end >&2
end

function _err
    begin; _c red; echo "  [FAIL] $argv"; _c normal; end >&2
end

function _step
    begin; _c cyan; echo ""; echo "══ $argv ══"; _c normal; end >&2
end

# ── Options ─────────────────────────────────────────────

argparse 'h/help' 'v/version' 'dry-run' 'force' -- $argv
or begin
    echo "Usage: setup.fish [--dry-run] [--force]" >&2
    exit 2
end

if set -q _flag_help
    echo "setup.fish v$VERSION — Prepare custom CachyOS ISO build tree"
    echo ""
    echo "Usage: setup.fish [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run    Preview changes without modifying anything"
    echo "  --force      Overwrite existing ISO directory, bypass version mismatch"
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

function _cp --description "Copy file with optional sudo, dry-run awareness"
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

function _extract_fish_var --description "Extract a Fish global variable's values from a source file"
    # _extract_fish_var VARNAME FILE
    # Extracts values from `set -g VARNAME val1 val2 \` (possibly multiline)
    # Returns space-separated string on stdout.
    if test (count $argv) -lt 2
        _err "_extract_fish_var: requires VARNAME FILE"
        return 1
    end
    set -l varname $argv[1]
    set -l srcfile $argv[2]

    if not test -f "$srcfile"
        _err "_extract_fish_var: file not found: $srcfile"
        return 1
    end

    # Write sed script to a temp file to avoid Fish/sed double-escaping issues.
    # Logic: find the declaration line, loop to collect backslash continuations,
    # strip the `set -g VARNAME` prefix, collapse newlines to spaces.
    set -l sedscript (mktemp)
    printf '/^[[:space:]]*set -g %s\\b/{\n:loop\n/\\\\[[:space:]]*$/{\nN\nb loop\n}\ns/^[[:space:]]*set -g %s[[:space:]]*//\ns/\\\\[[:space:]]*\\n/ /g\ns/^[[:space:]]*//\ns/[[:space:]]*$//\np\n}\n' "$varname" "$varname" > "$sedscript"
    sed -nf "$sedscript" "$srcfile" | tr -s ' ' | sed 's/^ //; s/ $//'
    rm -f "$sedscript"
end

# ── Lock ────────────────────────────────────────────────

if test "$DRY" = false
    if test -f "$LOCKFILE"
        set -l lock_pid (cat "$LOCKFILE" 2>/dev/null)
        if test -n "$lock_pid"; and kill -0 -- "$lock_pid" 2>/dev/null
            _err "another setup.fish is running (PID $lock_pid)"
            exit 1
        end
        _warn "removing stale lock (PID $lock_pid)"
        rm -f "$LOCKFILE"
    end
    echo %self > "$LOCKFILE"
    function _cleanup_lock --on-event fish_exit
        rm -f "$LOCKFILE" 2>/dev/null
    end
end

# ── Preflight ───────────────────────────────────────────

_step "Preflight checks"

# Must run from bundle directory
if not test -f "$SCRIPT_DIR/ry-install-post.sh"
    _err "Run from the bundle directory (ry-install-post.sh not found)"
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

# Verify ry-install version matches this bundle — hard error unless --force
set -l ry_version (grep '^set -g VERSION ' "$RY_INSTALL" | head -1 | string replace -r 'set -g VERSION "([^"]+)"' '$1')
if test "$ry_version" != "$VERSION"
    if set -q _flag_force
        _warn "ry-install version mismatch: $ry_version (expected $VERSION) — continuing (--force)"
    else
        _err "ry-install version mismatch: $ry_version (expected $VERSION)"
        _err "Update the bundle to match ry-install, or use --force to bypass"
        exit 1
    end
end

# Check running system has all 16 static configs deployed
# (all SYSTEM_DESTINATIONS + SERVICE_DESTINATIONS + USER_DESTINATIONS minus cmdline)
set -l check_files \
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
    /etc/conf.d/wireless-regdom \
    /etc/systemd/system/amdgpu-performance.service \
    /etc/systemd/system/cpupower-epp.service \
    "$HOME/.config/fish/conf.d/10-ssh-auth-sock.fish" \
    "$HOME/.config/environment.d/10-environment.conf" \
    "$HOME/.config/systemd/user/ssh-agent.service"
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
_ok "all 16 static configs present on running system"

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

set -l dirs \
    boot/loader \
    etc/kernel \
    etc/modprobe.d \
    etc/sysctl.d \
    etc/udev/rules.d \
    etc/systemd/resolved.conf.d \
    etc/systemd/logind.conf.d \
    etc/systemd/system/multi-user.target.wants \
    etc/systemd/user-preset \
    etc/iwd \
    etc/NetworkManager/conf.d \
    etc/conf.d \
    etc/skel/.config/fish/conf.d \
    etc/skel/.config/environment.d \
    etc/skel/.config/systemd/user \
    etc/calamares/modules \
    usr/local/bin

# Batch: single mkdir call for all directories (avoids 17 sequential forks)
if test "$DRY" = true
    for d in $dirs
        _info "would mkdir: $AIROOTFS/$d"
    end
else
    set -l full_dirs
    for d in $dirs
        set -a full_dirs "$AIROOTFS/$d"
    end
    mkdir -p $full_dirs
end
_ok (count $dirs)" directories"

# ── Step 3: Copy static configs from running system ─────

_step "Step 3: Copy 16 static configs from running system"

# 11 system configs (excluding /etc/kernel/cmdline — generated at install time)
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
_cp "$SCRIPT_DIR/ry-install-post.sh" \
    "$AIROOTFS/usr/local/bin/ry-install-post.sh"

_cp "$SCRIPT_DIR/ry-install-firstboot.sh" \
    "$AIROOTFS/usr/local/bin/ry-install-firstboot.sh"

# First-boot service unit
_cp "$SCRIPT_DIR/ry-install-firstboot.service" \
    "$AIROOTFS/etc/systemd/system/ry-install-firstboot.service"

# Calamares shellprocess config
_cp "$SCRIPT_DIR/shellprocess-ry-install.conf" \
    "$AIROOTFS/etc/calamares/modules/shellprocess-ry-install.conf"

# ry-install.fish itself
_cp "$RY_INSTALL" "$AIROOTFS/usr/local/bin/ry-install.fish"

# ssh-agent user preset — deployed at build time so it's active on first login
# (creating at first-boot is too late — systemd --user reads presets at session start)
if test "$DRY" = true
    _info "would create: $AIROOTFS/etc/systemd/user-preset/50-ry-install.preset"
else
    echo "enable ssh-agent.service" > "$AIROOTFS/etc/systemd/user-preset/50-ry-install.preset"
    _ok "created: ssh-agent user preset"
end

# First-boot enable symlink
if test "$DRY" = true
    _info "would symlink: ry-install-firstboot.service → multi-user.target.wants"
else
    ln -sf /etc/systemd/system/ry-install-firstboot.service \
        "$AIROOTFS/etc/systemd/system/multi-user.target.wants/ry-install-firstboot.service"
    _ok "symlink: firstboot → multi-user.target.wants"
end

# Batch: single chmod for all scripts (avoids 3 sequential forks)
if test "$DRY" = false
    chmod 755 \
        "$AIROOTFS/usr/local/bin/ry-install-post.sh" \
        "$AIROOTFS/usr/local/bin/ry-install-firstboot.sh" \
        "$AIROOTFS/usr/local/bin/ry-install.fish"
    _ok "scripts marked executable"
end

# ── Step 4b: Extract profile data from ry-install and inject into post script ──

_step "Step 4b: Extract profile data from ry-install into post script"

# Extract KERNEL_PARAMS, MASK, and PKGS_DEL from ry-install.fish and inject into
# the post-install script. This keeps the bundle in sync automatically — no hardcoded
# lists that drift when ry-install updates.

set -l post_script "$AIROOTFS/usr/local/bin/ry-install-post.sh"

if test "$DRY" = true
    _info "would extract KERNEL_PARAMS, MASK, PKGS_DEL from $RY_INSTALL"
    _info "would inject into ry-install-post.sh replacing @@...@@ placeholders"
else
    if not test -f "$post_script"
        _err "post script not found at $post_script"
        exit 1
    end

    # Extract each variable
    set -l kernel_params (_extract_fish_var KERNEL_PARAMS "$RY_INSTALL")
    set -l mask_list (_extract_fish_var MASK "$RY_INSTALL")
    set -l pkgs_del (_extract_fish_var PKGS_DEL "$RY_INSTALL")

    # Validate extractions — batch check, single error exit
    set -l extract_ok true
    if test -z "$kernel_params"
        _err "Failed to extract KERNEL_PARAMS from $RY_INSTALL"
        set extract_ok false
    end
    if test -z "$mask_list"
        _err "Failed to extract MASK from $RY_INSTALL"
        set extract_ok false
    end
    if test -z "$pkgs_del"
        _err "Failed to extract PKGS_DEL from $RY_INSTALL"
        set extract_ok false
    end
    if test "$extract_ok" = false
        exit 1
    end

    # Batch: single sed call for all 3 placeholder replacements
    # (avoids 3 sequential reads + writes of the same file)
    # | delimiter — no kernel params contain |
    sed -i \
        -e "s|@@KERNEL_PARAMS@@|$kernel_params|" \
        -e "s|@@MASK@@|$mask_list|" \
        -e "s|@@PKGS_DEL@@|$pkgs_del|" \
        "$post_script"

    # Verify: no @@ placeholders remain
    if grep -q '@@.*@@' "$post_script"
        _err "Unreplaced placeholders found in post script:"
        grep '@@.*@@' "$post_script" | head -5 >&2
        exit 1
    end

    # Count params for log
    set -l kp_count (string split " " -- "$kernel_params" | count)
    set -l mask_count (string split " " -- "$mask_list" | count)
    set -l pkg_count (string split " " -- "$pkgs_del" | count)
    _ok "injected: KERNEL_PARAMS=$kp_count, MASK=$mask_count, PKGS_DEL=$pkg_count"
end

# ── Step 5: Modify package list ─────────────────────────

_step "Step 5: Modify packages list"

# CachyOS renamed packages.x86_64 → packages_desktop.x86_64 (circa early 2026).
# buildiso.sh copies it to the standard archiso name during build, but setup.fish
# runs before buildiso.sh, so detect whichever exists.
set -l pkgfile ""
if test -f "$ISO_DIR/archiso/packages_desktop.x86_64"
    set pkgfile "$ISO_DIR/archiso/packages_desktop.x86_64"
else if test -f "$ISO_DIR/archiso/packages.x86_64"
    set pkgfile "$ISO_DIR/archiso/packages.x86_64"
end
if test -z "$pkgfile"
    _warn "packages*.x86_64 not found — check ISO repo structure"
    _warn "you may need to modify Calamares netinstall YAML instead"
else
    _info "using "(basename $pkgfile)
    # v3.7.13: 13 packages (bat/eza removed in v3.6.4 — deps of cachyos-fish-config)
    set -l pkgs_add \
        bottom \
        cachyos-gaming-applications \
        cachyos-gaming-meta \
        dust \
        fd \
        git-delta \
        iw \
        lm_sensors \
        mkinitcpio-firmware \
        nvme-cli \
        procs \
        sd \
        stress-ng

    # v3.7.13: 7 packages (power-profiles-daemon moved to MASK)
    set -l pkgs_del \
        btop \
        cachyos-micro-settings \
        cachyos-plymouth-bootanimation \
        micro \
        octopi \
        plymouth \
        ufw

    if test "$DRY" = true
        _info "would add to "(basename $pkgfile)": $pkgs_add"
        _info "would remove from "(basename $pkgfile)": $pkgs_del"
    else
        # Batch add: write candidates to temp, filter already-present, append remainder
        set -l tmp_add (mktemp)
        set -l added 0
        for pkg in $pkgs_add
            if not grep -qx "$pkg" "$pkgfile"
                echo "$pkg" >> "$tmp_add"
                set added (math $added + 1)
            end
        end
        if test -s "$tmp_add"
            cat "$tmp_add" >> "$pkgfile"
        end
        rm -f "$tmp_add"
        _ok "added $added packages"

        # Batch comment-out: single sed call with all patterns
        # (avoids N sequential grep+sed passes over the file)
        set -l sed_args
        set -l removed 0
        for pkg in $pkgs_del
            if grep -qx "$pkg" "$pkgfile"
                set -a sed_args -e "s/^$pkg\$/#$pkg/"
                set removed (math $removed + 1)
            end
        end
        if test (count $sed_args) -gt 0
            sed -i $sed_args "$pkgfile"
        end
        _ok "commented out $removed packages"

        # Sort the file: preserve file-header comments (contiguous block at top),
        # keep commented-out packages separate from header, then sort active packages.
        set -l tmp (mktemp)
        # Header: contiguous comment block at top of file
        set -l header_end 0
        set -l line_num 0
        for line in (cat "$pkgfile")
            set line_num (math $line_num + 1)
            if string match -rq '^#' -- "$line"
                set header_end $line_num
            else
                break
            end
        end
        # Write header comments
        if test $header_end -gt 0
            head -n "$header_end" "$pkgfile" > "$tmp"
        end
        # Write commented-out packages (lines starting with # that are NOT in the header)
        if test $header_end -gt 0
            tail -n +"(math $header_end + 1)" "$pkgfile" | grep '^#' >> "$tmp"
        else
            grep '^#' "$pkgfile" >> "$tmp"
        end
        # Write active packages, sorted
        grep -v '^#' "$pkgfile" | grep -v '^\s*$' | sort -u >> "$tmp"
        mv "$tmp" "$pkgfile"
        _ok "sorted "(basename $pkgfile)
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
    else if grep -q 'ry-install.fish' "$profiledef"
        _ok "file_permissions already present"
    else
        # Find the file_permissions associative array and its closing paren.
        # Scope the search to only lines AFTER file_permissions to avoid
        # matching other arrays or function bodies.
        set -l fp_start (grep -n 'file_permissions' "$profiledef" | head -1 | cut -d: -f1)
        if test -n "$fp_start"
            # Match closing ) that is the sole non-whitespace content on its line
            set -l close_line (tail -n +"$fp_start" "$profiledef" | grep -n '^\s*)' | head -1 | cut -d: -f1)
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
                    _info "$p"
                end
            end
        else
            _warn "file_permissions not found in profiledef.sh — add manually:"
            for p in $perms
                _info "$p"
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
            else if grep -qP '^\s*- bootloader\s*$' "$sf"
                # Detect indentation from the existing bootloader line
                set -l indent (grep -P '^\s*- bootloader\s*$' "$sf" | head -1 | sed 's/- bootloader.*//')
                # Insert after first bootloader occurrence, matching existing indentation.
                # Write sed script to temp file to avoid Fish/sed quoting conflicts.
                set -l sedscript (mktemp)
                printf '0,/^[[:space:]]*- bootloader[[:space:]]*$/{/^[[:space:]]*- bootloader[[:space:]]*$/a\\\n%s- shellprocess@ry-install\n}' "$indent" > "$sedscript"
                sed -i -f "$sedscript" "$sf"
                rm -f "$sedscript"
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
    _ok "no netinstall configs found (package list only)"
end

# ── Summary ─────────────────────────────────────────────

_step "Summary"

echo "" >&2
if test "$DRY" = true
    _warn "DRY RUN complete — no changes were made"
    echo "" >&2
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

exit 0
