#!/bin/sh
# ry-install-stage.sh — copy the ry-install payload into the Calamares target,
# run the post-install hook inside it, then place the user configs in the new
# account's home.
# Runs as root in the LIVE system (shellprocess, dontChroot: true).
# v7.302.0 — 2026-11-22
set -eu

ROOT="${1:-}"
TARGET_USER="${2:-}"
STAGE="/usr/local/share/ry-install"
DST_STAGE=""
LOGFILE=""

say()  { if [ -n "$LOGFILE" ]; then echo "$1" | tee -a "$LOGFILE"; else echo "$1"; fi; }
log()  { say "[ry-install-stage] $*"; }
warn() { say "[ry-install-stage] WARN: $*" >&2; }
die()  { say "[ry-install-stage] CRITICAL: $*" >&2; exit 1; }

[ -n "$ROOT" ] || die "no target root passed (Calamares ROOT unset)"
[ "$ROOT" != "/" ] || die "refusing to run against / as the target root"
[ -d "$ROOT" ] || die "target root is not a directory: $ROOT"
[ -d "$STAGE/system" ] || die "$STAGE/system missing — setup.fish did not stage the profile"
[ -r "$STAGE/profile.env" ] || die "$STAGE/profile.env missing — setup.fish did not stage the profile"

# One log for the whole hook: ry-install-post.sh appends to the same file from
# inside the chroot, so a post-mortem needs only this one path on the target.
install -d -m 0755 "$ROOT/var/log"
LOGFILE="$ROOT/var/log/ry-install-post.log"
log "target root: $ROOT"

# 1. Payload across. The airootfs overlay is part of the live squashfs only; an
# online install builds the target with pacstrap, so nothing here arrives on the
# target by itself.
DST_STAGE="$ROOT$STAGE"
install -d -m 0755 -- "$(dirname "$DST_STAGE")"
rm -rf --preserve-root -- "$DST_STAGE"
cp -a -- "$STAGE" "$(dirname "$DST_STAGE")/"
log "payload copied to $DST_STAGE"

for s in ry-install-post.sh ry-install.fish ry-verify.fish; do
    if [ -f "$STAGE/$s" ]; then
        install -D -m 0755 -- "$STAGE/$s" "$ROOT/usr/local/bin/$s"
        log "installed /usr/local/bin/$s"
    else
        warn "$STAGE/$s missing — not installed"
    fi
done

# 2. Resolve the target root UUID here, outside the chroot. `findmnt -no UUID /`
# inside a chroot reads the live system's mountinfo and answers for the ISO
# rather than for the target.
ROOT_UUID=$(findmnt -no UUID -- "$ROOT" 2>/dev/null) || ROOT_UUID=""
if [ -n "$ROOT_UUID" ]; then
    printf "RY_ROOT_UUID='%s'\n" "$ROOT_UUID" >> "$DST_STAGE/profile.env"
    log "root UUID: $ROOT_UUID"
else
    warn "could not resolve the target root UUID — the hook falls back to fstab"
fi

# 3. The profile itself, inside the target.
log "running /usr/local/bin/ry-install-post.sh in the chroot..."
chroot "$ROOT" /usr/local/bin/ry-install-post.sh

# 4. User configs. The account exists by now (the users module and the stock
# shellprocess /etc/skel copy both run earlier in the sequence), so these are
# written straight into the home directory at the 0600 ry-verify expects.
if [ -z "$TARGET_USER" ]; then
    warn "no username passed (Calamares USER unset) — user configs not placed"
elif [ ! -d "$STAGE/user" ]; then
    warn "$STAGE/user missing — no user configs to place"
else
    HOME_DIR=$(awk -F: -v u="$TARGET_USER" '$1 == u { print $6; exit }' "$ROOT/etc/passwd" 2>/dev/null) || HOME_DIR=""
    OWNER=$(awk -F: -v u="$TARGET_USER" '$1 == u { print $3 ":" $4; exit }' "$ROOT/etc/passwd" 2>/dev/null) || OWNER=""
    if [ -z "$HOME_DIR" ] || [ -z "$OWNER" ]; then
        warn "user $TARGET_USER not found in $ROOT/etc/passwd — user configs not placed"
    else
        LIST=$(mktemp)
        ( cd "$STAGE/user" && find . -type f ) | sed 's|^\./||' > "$LIST"
        placed=0
        total=0
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            total=$((total + 1))
            if install -D -m 0600 -o "${OWNER%:*}" -g "${OWNER#*:}" -- "$STAGE/user/$f" "$ROOT$HOME_DIR/$f"; then
                placed=$((placed + 1))
            else
                warn "failed to place $HOME_DIR/$f"
            fi
        done < "$LIST"
        rm -f "$LIST"
        # Parent directories belong to the user and must not be group/world-writable.
        chown -R "$OWNER" -- "$ROOT$HOME_DIR/.config" 2>/dev/null || true
        log "placed $placed/$total user config(s) in $HOME_DIR at 0600 ($OWNER)"
        [ "$placed" -eq "$total" ] || warn "CRITICAL: not every user config was placed"
        # setup.fish records how many user configs it staged; a short payload
        # places fewer and still matches its own count, so compare against that.
        USER_COUNT=$(sed -n "s/^RY_USER_COUNT='\([0-9]*\)'$/\1/p" "$STAGE/profile.env")
        [ "$total" = "${USER_COUNT:-}" ] \
            || warn "CRITICAL: user config drift — profile.env declares ${USER_COUNT:-?}, found $total"
        # ry-install keeps its .ry.bak copies under ~/ry-install/backups with
        # slash-encoded names; move the hook's fstab copy there so ry-verify finds it.
        if [ -f "$ROOT/etc/fstab.ry.bak" ]; then
            BAK_DIR="$ROOT$HOME_DIR/ry-install/backups"
            if install -d -m 0700 -o "${OWNER%:*}" -g "${OWNER#*:}" -- "$ROOT$HOME_DIR/ry-install" "$BAK_DIR" \
                && mv -- "$ROOT/etc/fstab.ry.bak" "$BAK_DIR/_etc_fstab.ry.bak"; then
                log "fstab backup moved to $HOME_DIR/ry-install/backups/_etc_fstab.ry.bak"
            else
                warn "could not move /etc/fstab.ry.bak into $HOME_DIR/ry-install/backups"
            fi
        fi
    fi
fi

log "Stage complete — verify after reboot with: ry-verify.fish --verify"
exit 0
