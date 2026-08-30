#!/bin/sh
# ry-calamares-register.sh — insert shellprocess@ry-install into Calamares
# Runs in the LIVE session, from calamares-online.sh, after that script has
# copied /usr/share/calamares/settings_<mode>.conf to /etc/calamares/settings.conf
# and before it execs calamares. Never fails the launcher: every branch reports
# and exits 0.
# v7.195.0 r1 — 2026-08-30

STAGE="/usr/local/share/ry-install"
SRC="$STAGE/shellprocess-ry-install.conf"
SETTINGS="/etc/calamares/settings.conf"
MODDIR="/etc/calamares/modules"

say() { echo "ry-install: $*"; }
err() { echo "ry-install: $*" >&2; }

[ -r "$SRC" ] || { err "$SRC missing — module not registered"; exit 0; }
[ -f "$SETTINGS" ] || { err "$SETTINGS missing — register by hand"; exit 0; }

mkdir -p "$MODDIR" 2>/dev/null
if cp -- "$SRC" "$MODDIR/shellprocess-ry-install.conf"; then
    say "installed $MODDIR/shellprocess-ry-install.conf"
else
    err "could not install the module config"
    exit 0
fi

if grep -q 'shellprocess@ry-install' "$SETTINGS"; then
    say "already registered in $SETTINGS"
    exit 0
fi

# A custom instance needs BOTH an instances: entry naming its config file and a
# sequence entry. The sequence entry goes immediately before `- umount`, the one
# anchor present in every CachyOS settings variant and the last exec step: that
# puts the profile after bootloader, services-systemd, the /etc/skel copy and
# every other shellprocess module, so nothing downstream can undo it.
TMP=$(mktemp) || { err "mktemp failed — register by hand"; exit 0; }
awk '
BEGIN { ins = 0; seq = 0 }
/^instances:[ \t]*$/ && !ins {
    print
    print ""
    print "- id:       ry-install"
    print "  module:   shellprocess"
    print "  config:   shellprocess-ry-install.conf"
    ins = 1
    next
}
match($0, /^[ \t]*-[ \t]+umount[ \t]*$/) && !seq {
    indent = $0
    sub(/-[ \t]+umount[ \t]*$/, "", indent)
    print indent "- shellprocess@ry-install"
    print
    seq = 1
    next
}
{ print }
END { exit (ins && seq) ? 0 : 1 }
' "$SETTINGS" > "$TMP"
rc=$?

if [ "$rc" -ne 0 ] || [ ! -s "$TMP" ]; then
    rm -f "$TMP"
    err "could not patch $SETTINGS (no instances: key or no '- umount' step) — register by hand"
    exit 0
fi

if cp -- "$TMP" "$SETTINGS"; then
    say "registered shellprocess@ry-install in $SETTINGS"
    grep -n 'ry-install' "$SETTINGS"
else
    err "could not write $SETTINGS — register by hand"
fi
rm -f "$TMP"
exit 0
