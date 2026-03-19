#!/bin/bash
# ry-install first-boot validation
# Runs once via ConditionPathExists, then self-disables
# v3.7.14 — 2026-03-19
set -euo pipefail

# Persistent log — consistent with ry-install-post.sh
LOG="/var/log/ry-install-firstboot.log"
exec > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)

log() { echo "[ry-install-firstboot] $*"; }
warn() { echo "[ry-install-firstboot] WARN: $*" >&2; }

# ssh-agent user preset is deployed at build time via airootfs overlay
# (etc/systemd/user-preset/50-ry-install.preset) — no runtime creation needed.

# Run ry-install static verification if available
if command -v ry-install.fish &>/dev/null; then
    log "Running ry-install --verify-static..."
    if ! ry-install.fish --verify-static; then
        warn "Verification reported issues (check output above)"
    fi
else
    warn "ry-install.fish not found in PATH — skipping verification"
fi

# Disable self (belt and suspenders with ConditionPathExists)
systemctl disable ry-install-firstboot.service 2>/dev/null || true

log "First-boot complete"
exit 0
