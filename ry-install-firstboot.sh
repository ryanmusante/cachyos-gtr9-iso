#!/bin/bash
# ry-install first-boot validation
# Runs once via ConditionPathExists, then self-disables
# v3.7.13 — 2026-03-16
set -euo pipefail

log() { echo "[ry-install-firstboot] $*"; }

# ssh-agent user preset is deployed at build time via airootfs overlay
# (etc/systemd/user-preset/50-ry-install.preset) — no runtime creation needed.

# Run ry-install static verification if available
if command -v ry-install.fish &>/dev/null; then
    log "Running ry-install --verify-static..."
    ry-install.fish --verify-static 2>&1 || log "Verification reported issues (check output)"
fi

# Disable self (belt and suspenders with ConditionPathExists)
systemctl disable ry-install-firstboot.service 2>/dev/null || true

log "First-boot complete"
