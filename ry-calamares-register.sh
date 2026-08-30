#!/bin/sh
# ry-calamares-register.sh — insert shellprocess@ry-install into Calamares
# Runs from a pacman hook during the ISO build only. Never fails the build:
# every branch reports and exits 0 so a pacman transaction cannot be aborted.
# v7.195.0 — 2026-08-30

STAGE="/usr/local/share/ry-install"
SRC="$STAGE/shellprocess-ry-install.conf"
MODDIR="/etc/calamares/modules"
FOUND=0

if [ ! -r "$SRC" ]; then
    echo "ry-install: $SRC missing — module not registered" >&2
    exit 0
fi

mkdir -p "$MODDIR" 2>/dev/null
if cp -- "$SRC" "$MODDIR/shellprocess-ry-install.conf"; then
    echo "ry-install: installed $MODDIR/shellprocess-ry-install.conf"
else
    echo "ry-install: could not install the module config" >&2
    exit 0
fi

for settings in /etc/calamares/settings*.conf; do
    [ -f "$settings" ] || continue
    FOUND=$((FOUND + 1))
    if grep -q 'shellprocess@ry-install' "$settings"; then
        echo "ry-install: already registered in $settings"
        continue
    fi
    if ! grep -qE '^[[:space:]]*-[[:space:]]+bootloader[[:space:]]*$' "$settings"; then
        echo "ry-install: no '- bootloader' line in $settings — register by hand" >&2
        continue
    fi
    # Match the indentation of the bootloader entry so the YAML list stays valid
    indent=$(grep -m1 -E '^[[:space:]]*-[[:space:]]+bootloader[[:space:]]*$' "$settings" | sed 's/-[[:space:]]*bootloader.*//')
    if sed -i "0,/^[[:space:]]*-[[:space:]]\{1,\}bootloader[[:space:]]*$/s//&\\n${indent}- shellprocess@ry-install/" "$settings"; then
        echo "ry-install: registered shellprocess@ry-install in $settings"
        grep -n -A1 -E '^[[:space:]]*-[[:space:]]+bootloader[[:space:]]*$' "$settings"
    else
        echo "ry-install: sed failed on $settings — register by hand" >&2
    fi
done

if [ "$FOUND" -eq 0 ]; then
    echo "ry-install: no /etc/calamares/settings*.conf found — register by hand" >&2
fi
exit 0
