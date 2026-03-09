#!/bin/bash
# ry-install first-boot validation
# Runs once via ConditionPathExists, then self-disables
# v3.5.2 — 2026-03-07
set -euo pipefail

log() { echo "[ry-install-firstboot] $*"; }

# Enable ssh-agent for all users with a login session
# Can't run systemctl --user in Calamares chroot (no user session/DBUS)
# Instead, create the preset so it activates on first user login
log "Creating ssh-agent user preset..."
mkdir -p /etc/systemd/user-preset
echo "enable ssh-agent.service" > /etc/systemd/user-preset/50-ry-install.preset

# Run ry-install static verification if available
if command -v ry-install.fish &>/dev/null; then
    log "Running ry-install --verify-static..."
    ry-install.fish --verify-static 2>&1 || log "Verification reported issues (check output)"
fi

# Disable self (belt and suspenders with ConditionPathExists)
systemctl disable ry-install-firstboot.service 2>/dev/null || true

log "First-boot complete"
