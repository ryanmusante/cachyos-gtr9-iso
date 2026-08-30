#!/usr/bin/env fish
# setup.fish — Prepare a custom CachyOS ISO build tree carrying the GTR9 Pro profile
# Requires: configured GTR9 Pro host, ry-install.fish + ry-verify.fish 7.195.0, git
# v7.195.0 r1 — 2026-08-30

set -g VERSION "7.195.0"
set -g SCRIPT_DIR (command realpath -- (status dirname))
set -g ISO_DIR "$SCRIPT_DIR/cachyos-custom-iso"
set -g AIROOTFS "$ISO_DIR/archiso/airootfs"
set -g STAGE_REL "usr/local/share/ry-install"
set -g LOCKFILE "$SCRIPT_DIR/.setup.lock"
set -g ISO_REPO "https://github.com/CachyOS/CachyOS-Live-ISO.git"
set -g LAUNCHER_REL "usr/local/bin/calamares-online.sh"
set -g ROOT_STAGE_ABS "/$STAGE_REL"

# ── Colors ──────────────────────────────────────────────

set -g NO_COLOR_SET (set -q NO_COLOR; and test -n "$NO_COLOR"; and echo true; or echo false)

# All progress/status output targets stderr; check isatty stderr for color.
function _c
    test "$NO_COLOR_SET" = true; and return
    isatty stderr; or return
    set_color $argv
end

function _info
    begin; _c blue; echo "  [INFO] $argv"; _c normal; end >&2
    return 0
end

function _ok
    begin; _c green; echo "  [OK]   $argv"; _c normal; end >&2
    return 0
end

function _warn
    begin; _c yellow; echo "  [WARN] $argv"; _c normal; end >&2
    return 0
end

function _err
    begin; _c red; echo "  [FAIL] $argv"; _c normal; end >&2
    return 0
end

function _step
    begin; _c cyan; echo ""; echo "══ $argv ══"; _c normal; end >&2
    return 0
end

# ── Options ─────────────────────────────────────────────

argparse 'h/help' 'v/version' 'dry-run' 'force' -- $argv
or begin
    echo "Usage: setup.fish [--dry-run] [--force]" >&2
    exit 2
end

if set -q _flag_help
    echo "setup.fish v$VERSION — Prepare a custom CachyOS ISO build tree"
    echo ""
    echo "Usage: setup.fish [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run     Preview changes without modifying anything"
    echo "  --force       Overwrite an existing ISO directory; bypass the version"
    echo "                lockstep and the ry-verify integrity gate"
    echo "  -h, --help    Show this help"
    echo "  -v, --version Show version"
    echo ""
    echo "Environment:"
    echo "  RY_INSTALL_PATH  Path to ry-install.fish (default: search ~/ry-install, ..)"
    echo "  RY_VERIFY_PATH   Path to ry-verify.fish  (default: search ~/ry-verify, ..)"
    echo "  NO_COLOR         Disable colored output when set non-empty (no-color.org)"
    echo ""
    echo "Run from the bundle directory, on a configured GTR9 Pro whose host"
    echo "verifies clean. Every list is extracted from ry-install.fish."
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

function _cp --description "Copy a file into the build tree, escalating to sudo only when the read fails"
    # _cp SOURCE DEST — dest parents are created; a sudo fallback re-owns the copy
    # to the invoking user so the tree stays user-editable (git diff, rm -rf).
    set -l src $argv[1]
    set -l dst $argv[2]

    if not test -f "$src"
        _warn "source missing, skipping: $src"
        return 1
    end

    if test "$DRY" = true
        _info "would copy: $src → $dst"
        return 0
    end

    mkdir -p (dirname "$dst")
    if not cp -- "$src" "$dst" 2>/dev/null
        sudo cp -- "$src" "$dst"
        or begin
            _err "copy failed: $src → $dst"
            return 1
        end
        sudo chown (id -u):(id -g) -- "$dst"
        or _warn "could not re-own $dst to the invoking user"
    end
    _ok "copied: $src → $dst"
    return 0
end

function _ry_decl --description "Join one fish global declaration to a single line, prefix and comment stripped"
    # _ry_decl VARNAME FILE — handles backslash continuations and a trailing ` # comment`.
    if test (count $argv) -lt 2
        _err "_ry_decl: requires VARNAME FILE"
        return 1
    end
    set -l varname $argv[1]
    set -l srcfile $argv[2]

    if not test -f "$srcfile"
        _err "_ry_decl: file not found: $srcfile"
        return 1
    end

    # The comment strip runs per LINE, before the join: an inline comment on a
    # non-final continuation line would otherwise swallow every token after it.
    set -l joined (command awk -v v="$varname" '
        BEGIN { pat = "^[ \t]*set -g ([-][-][ \t]+)?" v "[ \t]" }
        done { next }
        !started && $0 !~ pat { next }
        {
            line = $0
            sub(/[ \t]+#.*$/, "", line)
            if (!started) { started = 1; buf = line } else { buf = buf " " line }
            if (buf ~ /\\\\[ \t]*$/) { sub(/\\\\[ \t]*$/, "", buf); next }
            print buf; done = 1
        }
    ' "$srcfile")

    if test -z "$joined"
        _err "_ry_decl: no declaration of $varname in $srcfile"
        return 1
    end

    # Strip the `set -g [--] NAME` prefix, then any trailing ` # comment`.
    set -l body (string replace -r '^[ \t]*set -g ([-][-][ \t]+)?'"$varname"'[ \t]+' '' -- "$joined")
    set body (string replace -r ' +#.*$' '' -- "$body") # backstop; awk already stripped per line
    set body (string replace -a '"' '' -- "$body")
    set body (string trim -- (string replace -ra '[ \t]+' ' ' -- "$body"))
    # printf, not the string builtins: those return 1 when they change nothing,
    # which a caller's `; or exit 1` would read as an extraction failure.
    printf '%s\n' "$body"
    return 0
end

function _ry_tokens --description "Split a joined declaration into a token list"
    set -l decl (_ry_decl $argv); or return 1
    printf '%s\n' (string split -n ' ' -- "$decl")
    return 0
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
    echo $fish_pid > "$LOCKFILE"
    function _cleanup_lock --on-event fish_exit
        rm -f "$LOCKFILE" 2>/dev/null
    end
end

# ── Preflight ───────────────────────────────────────────

_step "Preflight checks"

# Must run from the bundle directory
for _f in ry-install-post.sh ry-install-stage.sh ry-calamares-register.sh shellprocess-ry-install.conf
    if not test -f "$SCRIPT_DIR/$_f"
        _err "Run from the bundle directory ($_f not found)"
        exit 1
    end
end

# Locate the pair — env override wins, then the usual checkout locations
set -g RY_INSTALL ""
for cand in "$RY_INSTALL_PATH" "$HOME/ry-install/ry-install.fish" "$SCRIPT_DIR/../ry-install/ry-install.fish" "$SCRIPT_DIR/../ry-install.fish"
    if test -n "$cand"; and test -f "$cand"
        set -g RY_INSTALL "$cand"
        break
    end
end
set -g RY_VERIFY ""
for cand in "$RY_VERIFY_PATH" "$HOME/ry-verify/ry-verify.fish" "$SCRIPT_DIR/../ry-verify/ry-verify.fish" "$SCRIPT_DIR/../ry-verify.fish"
    if test -n "$cand"; and test -f "$cand"
        set -g RY_VERIFY "$cand"
        break
    end
end

if test -z "$RY_INSTALL"
    _err "ry-install.fish not found — set RY_INSTALL_PATH or clone to ~/ry-install/"
    exit 1
end
if test -z "$RY_VERIFY"
    _err "ry-verify.fish not found — set RY_VERIFY_PATH or clone to ~/ry-verify/"
    exit 1
end
_ok "ry-install.fish: $RY_INSTALL"
_ok "ry-verify.fish:  $RY_VERIFY"

# Version lockstep — the pair ships one version; the bundle mirrors it
set -l mismatch 0
for pair in "ry-install:$RY_INSTALL" "ry-verify:$RY_VERIFY"
    set -l name (string split -m1 ':' -- "$pair")[1]
    set -l path (string split -m1 ':' -- "$pair")[2]
    set -l ver (command grep -m1 '^set -g VERSION ' "$path" | string replace -r '^set -g VERSION "([^"]+)".*' '$1')
    if test "$ver" != "$VERSION"
        _err "$name version mismatch: $ver (bundle expects $VERSION)"
        set mismatch 1
    else
        _ok "$name v$ver"
    end
end
if test $mismatch -ne 0
    if set -q _flag_force
        _warn "continuing despite version mismatch (--force)"
    else
        _err "Update the bundle to match the pair, or use --force to bypass"
        exit 1
    end
end

# Derive the managed-file set from ry-install itself — never hardcode paths here
set -g SYSTEM_DSTS (_ry_tokens SYSTEM_DESTINATIONS "$RY_INSTALL")
or exit 1
set -g USER_DSTS (string replace -a '$HOME' "$HOME" -- (_ry_tokens USER_DESTINATIONS "$RY_INSTALL"))
or exit 1
set -g DST_TOTAL (math (count $SYSTEM_DSTS) + (count $USER_DSTS))

# _RY_MANAGED_FILE_COUNT is packed mid-line, so read it directly rather than via _ry_decl
set -g MANAGED_COUNT (command grep -m1 -o 'set -g _RY_MANAGED_FILE_COUNT [0-9][0-9]*' "$RY_INSTALL" | string replace -r '^.* ' '')
if test -n "$MANAGED_COUNT"; and test "$MANAGED_COUNT" != "$DST_TOTAL"
    _err "managed-file drift: ry-install declares $MANAGED_COUNT, destinations total $DST_TOTAL"
    exit 1
end
_ok "$DST_TOTAL managed destinations ("(count $SYSTEM_DSTS)" system + "(count $USER_DSTS)" user)"

# /etc/kernel/cmdline carries the host root UUID — regenerated in the chroot, never staged
set -g STAGE_SRCS (string match -v '/etc/kernel/cmdline' -- $SYSTEM_DSTS)

# Payload scripts that must be executable in the live squashfs. profiledef.sh
# file_permissions is what actually sets the bit (mkarchiso copies the overlay
# with --no-preserve=mode); the chmod below only keeps the worktree honest.
set -g EXEC_PAYLOAD ry-install-stage.sh ry-calamares-register.sh ry-install-post.sh ry-install.fish ry-verify.fish
set -g EXEC_PAYLOAD_ABS
for f in $EXEC_PAYLOAD
    set -a EXEC_PAYLOAD_ABS "$AIROOTFS/$STAGE_REL/$f"
end

# Every managed destination must exist on the running host
set -l missing 0
for f in $SYSTEM_DSTS $USER_DSTS
    if not test -f "$f"
        _warn "missing on running system: $f"
        set missing (math $missing + 1)
    end
end
if test $missing -gt 0
    _err "Deploy the profile first (run ry-install.fish as your user), then re-run this setup"
    exit 1
end
_ok "all $DST_TOTAL managed files present on the running system"

# Integrity gate: the staged bytes are only trustworthy if the host verifies clean
if test "$DRY" = true
    _info "would run: $RY_VERIFY --verify"
else if set -q _flag_force
    _warn "skipping the ry-verify integrity gate (--force)"
else
    _info "running $RY_VERIFY --verify (sudo required; this takes a moment)"
    if fish "$RY_VERIFY" --verify
        _ok "host verifies clean"
    else
        _err "ry-verify reported drift (exit $status) — fix the host or re-run with --force"
        exit 1
    end
end

command -q git; or begin; _err "git not found"; exit 1; end

if test -d "$ISO_DIR"
    if set -q _flag_force
        _warn "removing existing $ISO_DIR"
        test "$DRY" = false; and rm -rf --preserve-root -- "$ISO_DIR"
    else
        _err "$ISO_DIR already exists (use --force to overwrite)"
        exit 1
    end
end

_ok "preflight complete"

# ── Step 1: Clone ───────────────────────────────────────

_step "Step 1: Clone CachyOS-Live-ISO"

if test "$DRY" = true
    _info "would run: git clone $ISO_REPO → $ISO_DIR"
    _info "would run: git checkout -b gtr9-pro"
else
    git clone "$ISO_REPO" "$ISO_DIR"
    or begin; _err "git clone failed"; exit 1; end

    # Try create-and-switch, then switch-only; surface stderr only on final failure
    if not git -C "$ISO_DIR" checkout -b gtr9-pro 2>/dev/null
        git -C "$ISO_DIR" checkout gtr9-pro
        or begin; _err "git checkout gtr9-pro failed (see git error above)"; exit 1; end
    end
    _ok "cloned and branched"
end

# ── Step 2: Create overlay directories ──────────────────

_step "Step 2: Create overlay directories"

# Every directory is derived: the staging root plus one parent per user config.
set -l dirs "$STAGE_REL/system" "$STAGE_REL/user"
for f in $USER_DSTS
    set -a dirs "$STAGE_REL/user/"(dirname (string replace -- "$HOME/" '' "$f"))
end
set dirs (printf '%s\n' $dirs | sort -u)

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

# ── Step 3: Stage the managed configs ───────────────────

_step "Step 3: Stage "(count $STAGE_SRCS)" system configs + "(count $USER_DSTS)" user configs"

# System configs are staged, not overlaid: /boot in the airootfs is the live ISO's
# boot directory, not the target ESP, and an /etc overlay would also apply the
# profile to the live environment. ry-install-post.sh installs them in the chroot.
set -l staged 0
for f in $STAGE_SRCS
    _cp "$f" "$AIROOTFS/$STAGE_REL/system$f"
    and set staged (math $staged + 1)
end
_ok "$staged/"(count $STAGE_SRCS)" system configs staged"

# User configs ride in the payload rather than /etc/skel: ry-install-stage.sh
# writes them into the new account's home at 0600 after the users module and the
# stock shellprocess /etc/skel copy have both run. An /etc/skel overlay would
# also land at whatever mode mkarchiso's `cp --no-preserve=mode` produced, and
# ry-verify FAILs any USER_DESTINATIONS file that is not 0600.
set -l skelled 0
for f in $USER_DSTS
    set -l rel (string replace -- "$HOME/" '' "$f")
    _cp "$f" "$AIROOTFS/$STAGE_REL/user/$rel"
    and set skelled (math $skelled + 1)
end
_ok "$skelled/"(count $USER_DSTS)" user configs staged"

if test (math $staged + $skelled) -lt (math (count $STAGE_SRCS) + (count $USER_DSTS))
    _err "incomplete stage: "(math $staged + $skelled)" of "(math (count $STAGE_SRCS) + (count $USER_DSTS))" files copied"
    _err "An ISO built from a partial stage installs an incomplete profile — refusing to continue"
    exit 1
end

# ── Step 4: Bundle overlay files ────────────────────────

_step "Step 4: Place bundle overlay files"

# Everything lives under the staging root. ry-install-stage.sh copies the tree
# into the target and installs the three target-side scripts into
# /usr/local/bin there; nothing goes to the live /usr/local/bin, because the
# overlay reaches the live squashfs only and never the installed system.
for f in ry-install-post.sh ry-install-stage.sh ry-calamares-register.sh shellprocess-ry-install.conf
    _cp "$SCRIPT_DIR/$f" "$AIROOTFS/$STAGE_REL/$f"
end

# The pair itself — ry-verify is what the operator runs after the first reboot
_cp "$RY_INSTALL" "$AIROOTFS/$STAGE_REL/ry-install.fish"
_cp "$RY_VERIFY" "$AIROOTFS/$STAGE_REL/ry-verify.fish"

if test "$DRY" = false
    chmod 755 $EXEC_PAYLOAD_ABS
    _ok (count $EXEC_PAYLOAD)" payload scripts marked executable"
end

# ── Step 4b: Write the profile manifest ─────────────────

_step "Step 4b: Write profile.env from ry-install"

# ry-install-post.sh sources this instead of carrying @@PLACEHOLDER@@ text, so the
# script in the repo and the script on the ISO are byte-identical.
set -g PROFILE_ENV "$AIROOTFS/$STAGE_REL/profile.env"

set -l kernel_params (_ry_decl KERNEL_PARAMS "$RY_INSTALL"); or exit 1
set -l mask_list (_ry_decl MASK "$RY_INSTALL"); or exit 1
set -l enable_list (_ry_decl EXPECTED_SERVICES "$RY_INSTALL"); or exit 1
set -l pkgs_add (_ry_decl PKGS_ADD "$RY_INSTALL"); or exit 1
set -l pkgs_del (_ry_decl PKGS_DEL "$RY_INSTALL"); or exit 1
set -l country (_ry_decl COUNTRY "$RY_INSTALL"); or exit 1

# Every value is emitted single-quoted and read back by a POSIX shell
for val in $kernel_params $mask_list $enable_list $pkgs_add $pkgs_del $country
    if string match -q "*'*" -- "$val"; or string match -q '*#*' -- "$val"
        _err "extracted value contains a quote or '#' — refusing to write profile.env"
        exit 1
    end
end

if test "$DRY" = true
    _info "would write: $PROFILE_ENV"
else
    printf '%s\n' \
        "# generated by setup.fish v$VERSION — do not edit" \
        "RY_VERSION='$VERSION'" \
        "RY_STAGED_COUNT='"(count $STAGE_SRCS)"'" \
        "RY_USER_COUNT='"(count $USER_DSTS)"'" \
        "RY_COUNTRY='$country'" \
        "RY_KERNEL_PARAMS='$kernel_params'" \
        "RY_MASK='$mask_list'" \
        "RY_ENABLE='$enable_list'" \
        "RY_PKGS_ADD='$pkgs_add'" \
        "RY_PKGS_DEL='$pkgs_del'" > "$PROFILE_ENV"
end
_ok "profile.env: STAGED="(count $STAGE_SRCS)", USER="(count $USER_DSTS)", KERNEL_PARAMS="(count (string split ' ' -- $kernel_params))", MASK="(count (string split ' ' -- $mask_list))", ENABLE="(count (string split ' ' -- $enable_list))", PKGS_ADD="(count (string split ' ' -- $pkgs_add))", PKGS_DEL="(count (string split ' ' -- $pkgs_del))

# ── Step 5: Modify package list ─────────────────────────

_step "Step 5: Sync the live-environment package list with PKGS_ADD / PKGS_DEL"

# LIVE ENVIRONMENT ONLY. CachyOS installs online: the target is built by
# pacstrap plus the netinstall selection, so this list never reaches it.
# ry-install-post.sh installs PKGS_ADD and removes PKGS_DEL inside the chroot;
# this step only makes the live/rescue environment match the profile.
# CachyOS ships packages_desktop.x86_64 (copied to packages.x86_64 at build
# time); the older name is still accepted so an older checkout keeps working.
set -l pkgfile ""
for cand in "$ISO_DIR/archiso/packages_desktop.x86_64" "$ISO_DIR/archiso/packages.x86_64"
    test -f "$cand"; and set pkgfile "$cand"; and break
end
if test -z "$pkgfile"
    _warn "packages*.x86_64 not found — check the ISO repo structure"
    _warn "you may need to modify the Calamares netinstall YAML instead"
else
    _info "using "(basename $pkgfile)
    set -l add_pkgs (string split -n ' ' -- $pkgs_add)
    set -l del_pkgs (string split -n ' ' -- $pkgs_del)

    if test "$DRY" = true
        _info "would add to "(basename $pkgfile)": $add_pkgs"
        _info "would comment out in "(basename $pkgfile)": $del_pkgs"
    else
        # Batch add: collect the not-yet-present candidates, append once
        set -l tmp_add (mktemp)
        set -l added 0
        for pkg in $add_pkgs
            if not grep -qx -- "$pkg" "$pkgfile"
                echo "$pkg" >> "$tmp_add"
                set added (math $added + 1)
            end
        end
        test -s "$tmp_add"; and cat "$tmp_add" >> "$pkgfile"
        rm -f "$tmp_add"
        _ok "added $added packages"

        # Batch comment-out: one sed call carrying every pattern
        set -l sed_args
        set -l removed 0
        for pkg in $del_pkgs
            if grep -qx -- "$pkg" "$pkgfile"
                set -a sed_args -e "s/^$pkg\$/#$pkg/"
                set removed (math $removed + 1)
            end
        end
        test (count $sed_args) -gt 0; and sed -i $sed_args "$pkgfile"
        _ok "commented out $removed packages"

        # Sort: keep the file-header comment block, then commented-out entries,
        # then the active package list sorted and de-duplicated.
        set -l tmp (mktemp)
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
        if test $header_end -gt 0
            head -n "$header_end" "$pkgfile" > "$tmp"
            tail -n +(math $header_end + 1) "$pkgfile" | grep '^#' >> "$tmp"; or true
        else
            grep '^#' "$pkgfile" >> "$tmp"; or true
        end
        grep -v '^#' "$pkgfile" | grep -v '^\s*$' | sort -u >> "$tmp"; or true
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
    set -l perms
    for f in $EXEC_PAYLOAD
        set -a perms '  ["/'"$STAGE_REL/$f"'"]="0:0:755"'
    end

    if test "$DRY" = true
        _info "would add "(count $perms)" file_permissions entries to profiledef.sh"
    else if grep -q 'ry-install' "$profiledef"
        _ok "file_permissions already present"
    else
        # Find the file_permissions array and the closing paren that follows it.
        set -l fp_start (grep -n 'file_permissions' "$profiledef" | head -1 | cut -d: -f1)
        if test -n "$fp_start"
            # Match a closing ) that is the sole non-whitespace content on its line
            set -l close_line (tail -n +"$fp_start" "$profiledef" | grep -n '^\s*)' | head -1 | cut -d: -f1)
            if test -n "$close_line"
                # close_line is relative to fp_start — convert to absolute
                set close_line (math "$fp_start + $close_line - 1")
                set -l tmp (mktemp)
                for p in $perms
                    echo "$p" >> "$tmp"
                end
                set -l before_close (math "$close_line - 1")
                # GNU sed: r inserts the file's content after line N
                sed -i "$before_close r $tmp" "$profiledef"
                rm -f "$tmp"
                _ok "added "(count $perms)" file_permissions entries"
            else
                _warn "could not find the closing ) for file_permissions — add manually:"
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

# ── Step 7: Calamares registration ──────────────────────

_step "Step 7: Patch calamares-online.sh to register shellprocess@ry-install"

# The Calamares configuration cannot be patched at build time. Its settings
# files ship at /usr/share/calamares/, not /etc/calamares/, and the live session
# reinstalls cachyos-calamares-next before launching the installer, restoring
# every package-owned file. What the live session does create is
# /etc/calamares/settings.conf, copied from the package moments before calamares
# is exec'd — so registration has to happen in that window, from the launcher
# script itself. calamares-online.sh belongs to the ISO tree, not to a package,
# so patching it here is durable.
set -g LAUNCHER "$AIROOTFS/$LAUNCHER_REL"
if not test -f "$LAUNCHER"
    _err "$LAUNCHER_REL not found in the ISO tree — the upstream launcher moved"
    _err "Register by hand: run ry-calamares-register.sh after settings.conf is written"
    exit 1
end

set -l reg_call "    sudo /bin/sh $ROOT_STAGE_ABS/ry-calamares-register.sh"
if grep -q 'ry-calamares-register' "$LAUNCHER"
    _ok "launcher already patched"
else if test "$DRY" = true
    _info "would insert before the calamares exec in $LAUNCHER_REL:"
    _info "$reg_call"
else
    set -l anchor (grep -n '^[[:space:]]*exec .*calamares' "$LAUNCHER" | head -1 | cut -d: -f1)
    if test -z "$anchor"
        _err "no 'exec ... calamares' line in $LAUNCHER_REL — register by hand"
        exit 1
    end
    set -l tmp (mktemp)
    printf '%s\n' "$reg_call" > "$tmp"
    sed -i (math "$anchor - 1")" r $tmp" "$LAUNCHER"
    rm -f "$tmp"
    if grep -q 'ry-calamares-register' "$LAUNCHER"
        _ok "patched $LAUNCHER_REL at line $anchor"
        _info (grep -n -B1 -A1 'ry-calamares-register' "$LAUNCHER" | string collect)
    else
        _err "launcher patch did not take — register by hand"
        exit 1
    end
end

# A settings file inside the overlay would be a second, conflicting registration
# point; upstream ships none, so finding one is worth a warning.
set -l settings_files (find "$AIROOTFS" -name 'settings*.conf' -path '*/calamares/*' 2>/dev/null)
if test (count $settings_files) -gt 0
    _warn "a Calamares settings file is already in the airootfs overlay:"
    for sf in $settings_files
        _info "  $sf"
    end
    _warn "check for a double registration"
else
    _ok "no settings.conf in the overlay (expected)"
end

# ── Step 8: Also check for netinstall configs ───────────

_step "Step 8: Check for Calamares netinstall configs"

# Informational. The target's package set comes from pacstrap basePackages plus
# the netinstall selection, and netinstall.conf fetches its group list from
# GitHub before falling back to the local YAML — neither is patchable from here,
# which is why ry-install-post.sh installs PKGS_ADD in the chroot.
set -l netinstall_files (find "$AIROOTFS" -name 'netinstall*' -path '*/calamares/*' 2>/dev/null)
if test (count $netinstall_files) -gt 0
    _warn "Calamares netinstall configs in the overlay — a second package source:"
    for nf in $netinstall_files
        _info "  $nf"
    end
    _warn "Review these files for PKGS_ADD/PKGS_DEL overlap"
else
    _ok "no netinstall configs in the overlay (target packages come from the chroot hook)"
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
    echo "  Files placed in the airootfs overlay:"

    if test -d "$AIROOTFS"
        set -l file_count (find "$AIROOTFS" -type f | wc -l | string trim)
        echo "    $file_count files total"
    end

    echo ""
    echo "  Next steps:"
    echo "    1. Review the changes:"
    echo "       cd $ISO_DIR"
    echo "       git status"
    echo "       git diff"
    echo ""
    echo "    2. Install build deps:"
    echo "       sudo pacman -S --needed archiso mkinitcpio-archiso squashfs-tools grub"
    echo ""
    echo "    3. Build the ISO (buildiso.sh writes no log file — tee it):"
    echo "       cd $ISO_DIR"
    echo "       ./buildiso.sh -p desktop -v 2>&1 | tee build.log"
    echo ""
    echo "    4. Confirm the payload is in the squashfs:"
    echo "       grep -n 'ry-install' build.log | head"
    echo "       grep -n 'ry-calamares-register' archiso/$LAUNCHER_REL"
    echo ""
    echo "    5. Test in a VM first:"
    echo "       qemu-img create -f qcow2 test-disk.qcow2 40G"
    echo "       cp /usr/share/edk2/x64/OVMF_VARS.4m.fd ovmf-vars.fd"
    echo "       qemu-system-x86_64 -enable-kvm -m 8G -cpu host \\"
    echo "           -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \\"
    echo "           -drive if=pflash,format=raw,file=ovmf-vars.fd \\"
    echo "           -cdrom $ISO_DIR/out/desktop/*.iso \\"
    echo "           -drive file=test-disk.qcow2,if=virtio,format=qcow2 -boot d"
    echo ""
    echo "    6. In the live session, before starting the installer, confirm:"
    echo "       the installer window shows a step named 'Applying the GTR9 Pro profile'"
    echo ""
    echo "    7. After the install completes, reboot, then verify as your user:"
    echo "       /usr/local/bin/ry-verify.fish --verify"
    echo "       (root is refused by design; --verify needs an interactive sudo)"
    echo ""
    echo "    Install log on the target: /var/log/ry-install-post.log"
end

exit 0
