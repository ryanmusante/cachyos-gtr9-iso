![version](https://img.shields.io/badge/version-3.8.1-green?style=flat-square) ![license](https://img.shields.io/badge/license-MIT-blue?style=flat-square) ![fish](https://img.shields.io/badge/fish-3.4%2B-orange?style=flat-square) · [CHANGELOG](CHANGELOG.txt)

# Custom CachyOS ISO Implementation Plan

**Goal:** Build a custom CachyOS ISO that installs a fully-configured GTR9 Pro system — all 17 ry-install configs pre-applied, packages pre-selected, services pre-masked — with ry-install.fish bundled for ongoing maintenance.

**Architecture:** Fork CachyOS-Live-ISO, inject static configs via archiso's `airootfs/` overlay, customize package lists at build-time, and add a Calamares `shellprocess` module to handle runtime-dependent post-install tasks (UUID-based cmdline, service masking, initramfs rebuild). A first-boot service handles anything that can't run in Calamares's chroot.

**Tech Stack:** CachyOS-Live-ISO (archiso), Calamares (shellprocess module), systemd (first-boot service), fish shell (ry-install.fish)

---

## Context

ry-install.fish is a 7.5K-line post-install script with 17 embedded configs. Today the workflow is: install CachyOS from stock ISO → run ry-install.fish. The custom ISO eliminates that second step.

### What belongs where

| Layer | What | Why |
|-------|------|-----|
| **Build-time** (package list) | Package add/remove | Baked into squashfs, available in live env and installed system |
| **Build-time** (airootfs/) | 16 static config files (incl. 2 service units, 3 user files), ssh-agent user preset, wrapper scripts, ry-install.fish | Copied verbatim to installed root by Calamares |
| **Calamares post-install** (shellprocess → wrapper script) | /etc/kernel/cmdline (needs UUID), LINUX_OPTIONS verification, service masking (9 units), service enable (4 services), package removal (7 packages), mkinitcpio -P, sdboot-manage | Runs in chroot of installed system before first boot; KERNEL_PARAMS, MASK, PKGS_DEL injected from ry-install.fish at build time |
| **First-boot** (systemd oneshot) | ry-install --verify-static | Self-disabling after success; validates config deployment |

### Static vs dynamic configs

Of ry-install's 17 managed files, 16 are fully static (no runtime detection needed). Only `/etc/kernel/cmdline` requires the root UUID, which is only known after Calamares partitions the disk. Everything else can be a plain file overlay.

---

## Phase 1: Repository Setup

### Task 1: Fork and clone CachyOS-Live-ISO

```bash
git clone https://github.com/CachyOS/CachyOS-Live-ISO.git cachyos-custom-iso
cd cachyos-custom-iso
git checkout -b gtr9-pro
```

Verify structure exists:
- `archiso/packages.x86_64` (or `packages_desktop.x86_64`) — package list for live env + install
- `archiso/airootfs/` — root filesystem overlay
- `archiso/profiledef.sh` — build profile
- `buildiso.sh` — build script

### Task 2: Create overlay directory structure

```bash
mkdir -p archiso/airootfs/boot/loader
mkdir -p archiso/airootfs/etc/kernel
mkdir -p archiso/airootfs/etc/modprobe.d
mkdir -p archiso/airootfs/etc/sysctl.d
mkdir -p archiso/airootfs/etc/udev/rules.d
mkdir -p archiso/airootfs/etc/systemd/resolved.conf.d
mkdir -p archiso/airootfs/etc/systemd/logind.conf.d
mkdir -p archiso/airootfs/etc/systemd/system/multi-user.target.wants
mkdir -p archiso/airootfs/etc/systemd/user-preset
mkdir -p archiso/airootfs/etc/iwd
mkdir -p archiso/airootfs/etc/NetworkManager/conf.d
mkdir -p archiso/airootfs/etc/conf.d
mkdir -p archiso/airootfs/etc/skel/.config/fish/conf.d
mkdir -p archiso/airootfs/etc/skel/.config/environment.d
mkdir -p archiso/airootfs/etc/skel/.config/systemd/user
mkdir -p archiso/airootfs/etc/calamares/modules
mkdir -p archiso/airootfs/usr/local/bin
```

**Note:** User-home files go under `etc/skel/` so Calamares copies them to the created user's home. Do NOT use `airootfs/home/` — Calamares creates the user at install time.

---

## Phase 2: Package Customization

### Task 3: Modify package list

Open `archiso/packages.x86_64` (may be named `packages_desktop.x86_64` on CachyOS repos from early 2026+; `setup.fish` auto-detects both). This is a newline-delimited list of packages.

**Add** (13 packages, one per line, alphabetical):
```
bottom
cachyos-gaming-applications
cachyos-gaming-meta
dust
fd
git-delta
iw
lm_sensors
mkinitcpio-firmware
nvme-cli
procs
sd
stress-ng
```

**Remove** (7 packages — comment out if present):
```
#btop
#cachyos-micro-settings
#cachyos-plymouth-bootanimation
#micro
#octopi
#plymouth
#ufw
```

**Note:** `power-profiles-daemon` is masked (not removed) to prevent dependency reinstallation conflicts. `pipewire-libcamera` is not listed — it's pulled automatically as a dependency. `bat` and `eza` are not listed — they're hard dependencies of `cachyos-fish-config` (installed by default on CachyOS desktops).

**Verify:** Some of these may not be in the ISO package list (they might be installed by Calamares netinstall module instead). Check both the package list file and any Calamares netinstall YAML files under `archiso/airootfs/etc/calamares/modules/` for the package lists.

**CachyOS-specific note:** CachyOS may split packages between the ISO package list (live env) and Calamares netinstall groups. Search for netinstall configs:
```bash
find archiso/ -name 'netinstall*.yaml' -o -name 'netinstall*.conf' 2>/dev/null
find archiso/ -path '*/calamares/*' -name '*.yaml' 2>/dev/null
```

If CachyOS uses online package groups, you may need to modify those YAML files instead of (or in addition to) the package list file.

---

## Phase 3: Static Config Files (airootfs overlay)

### Task 4: Extract configs from ry-install.fish

Copy the 16 static files from your running, verified system:

```fish
set -l overlay ./airootfs-overlay

# 11 system configs (excluding /etc/kernel/cmdline — generated at install time)
set -l static_files \
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

for f in $static_files
    set -l dest $overlay$f
    mkdir -p (dirname $dest)
    sudo cp $f $dest
end

# 2 service files
for f in /etc/systemd/system/amdgpu-performance.service /etc/systemd/system/cpupower-epp.service
    set -l dest $overlay$f
    mkdir -p (dirname $dest)
    sudo cp $f $dest
end

# 3 user files → etc/skel (NOT home)
mkdir -p $overlay/etc/skel/.config/fish/conf.d
mkdir -p $overlay/etc/skel/.config/environment.d
mkdir -p $overlay/etc/skel/.config/systemd/user
cp ~/.config/fish/conf.d/10-ssh-auth-sock.fish $overlay/etc/skel/.config/fish/conf.d/
cp ~/.config/environment.d/10-environment.conf $overlay/etc/skel/.config/environment.d/
cp ~/.config/systemd/user/ssh-agent.service $overlay/etc/skel/.config/systemd/user/
```

Then copy the overlay into the ISO tree:
```bash
cp -a airootfs-overlay/* archiso/airootfs/
```

### Task 5: Bundle ry-install.fish

```bash
cp ~/ry-install/ry-install.fish archiso/airootfs/usr/local/bin/ry-install.fish
chmod 755 archiso/airootfs/usr/local/bin/ry-install.fish
```

This makes ry-install available system-wide on the installed system for `--verify-static`, `--verify-runtime`, `--diff`, `--diagnose`, etc.

### Task 6: Set file permissions in profiledef.sh

Add to the `file_permissions` array in `archiso/profiledef.sh`:

```bash
["/usr/local/bin/ry-install.fish"]="0:0:755"
["/usr/local/bin/ry-install-post.sh"]="0:0:755"
["/usr/local/bin/ry-install-firstboot.sh"]="0:0:755"
```

Verify existing CachyOS entries aren't overriding your config file paths.

---

## Phase 4: Calamares Post-Install Hook

### Task 7: Create post-install wrapper script and shellprocess module

CachyOS's Calamares config lives under `archiso/airootfs/etc/calamares/`. Find the existing module execution order:

```bash
find archiso/ -name 'settings.conf' -path '*/calamares/*'
```

The `settings.conf` has an `exec:` list defining module execution order. You need a shellprocess entry that runs **after** bootloader install but **before** the final `umount` module.

**Strategy:** Use a single wrapper script deployed via airootfs instead of inline YAML. Avoids fragile nested quoting in YAML and makes the logic testable independently.

**File:** `archiso/airootfs/usr/local/bin/ry-install-post.sh` — see `ry-install-post.sh`

Key operations (in order):
1. Generate `/etc/kernel/cmdline` with root UUID (fallback: `/etc/fstab` parse if `findmnt` fails in chroot); read-back verification confirms UUID in written content. **Note:** sdboot-manage reads `LINUX_OPTIONS` from `/etc/sdboot-manage.conf` (static overlay) — not this file. The cmdline file is kept for UKI compatibility and diagnostics.
1b. Verify `LINUX_OPTIONS` in `/etc/sdboot-manage.conf`; inject from build-time params if missing or commented out (safety net for stale overlays)
2. Mask 9 services/targets (unconditional — no LVM guard needed for GTR9 Pro); logs count
3. Enable 4 services (amdgpu-performance, cpupower-epp, fstrim.timer, NM-dispatcher); logs count
4. Remove 7 conflicting packages (batch with per-package fallback); logs targets or "nothing to remove"
5. Rebuild initramfs (`mkinitcpio -P`)
6. Regenerate boot entries (`sdboot-manage gen` + `update`)

All operations log to `/var/log/ry-install-post.log` with stdout/stderr separation preserved via `exec > >(tee) 2> >(tee >&2)`. Log pipes are flushed before exit to prevent truncation.

**Note:** The post-install script uses `@@KERNEL_PARAMS@@`, `@@MASK@@`, and `@@PKGS_DEL@@` placeholders that `setup.fish` replaces at build time by extracting values from `ry-install.fish`. This keeps the bundle in sync automatically. Runtime guards abort if any placeholder is unreplaced.

**File:** `archiso/airootfs/etc/calamares/modules/shellprocess-ry-install.conf`

```yaml
---
dontChroot: false
# Timeout budget: mkinitcpio ~120s + pacman ~30s + sdboot-manage ~10s + overhead ~40s
# = ~200s typical, 600s provides 3x safety margin.
script:
    - command: "/usr/local/bin/ry-install-post.sh"
      timeout: 600
```

### Task 8: Register module in Calamares settings.conf

Edit `archiso/airootfs/etc/calamares/settings.conf`. In the `exec:` sequence, add `shellprocess@ry-install` **after** the bootloader module and **before** `umount`:

```yaml
exec:
    # ... existing modules ...
    - bootloader
    - shellprocess@ry-install    # ← add here
    - umount
    # ... existing modules ...
```

**Important:** The exact module names and order vary by CachyOS version. Read the existing `settings.conf` carefully. Look for existing `shellprocess` entries to understand the naming convention CachyOS uses.

---

## Phase 5: First-Boot Service (safety net)

### Task 9: Create first-boot validation service

Handles post-boot validation: runs `ry-install --verify-static` to confirm config deployment. The ssh-agent user preset is deployed at build time via `airootfs/etc/systemd/user-preset/50-ry-install.preset` (not at first boot — systemd reads presets at user session start, so runtime creation would be too late).

Logs to `/var/log/ry-install-firstboot.log` with the same `exec > >(tee) 2> >(tee >&2)` pattern as the post-install script (log pipes flushed before exit). Uses separate `log()` (stdout) and `warn()` (stderr) functions. Warns explicitly if `ry-install.fish` is not found in PATH.

**File:** `archiso/airootfs/etc/systemd/system/ry-install-firstboot.service`

```ini
[Unit]
Description=ry-install first-boot validation
After=multi-user.target
ConditionPathExists=!/var/lib/ry-install-firstboot-done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ry-install-firstboot.sh
ExecStartPost=/usr/bin/touch /var/lib/ry-install-firstboot-done

[Install]
WantedBy=multi-user.target
```

**File:** `archiso/airootfs/usr/local/bin/ry-install-firstboot.sh` — see `ry-install-firstboot.sh`

Enable the service in the overlay (directory already created in Task 2):

```bash
ln -s /etc/systemd/system/ry-install-firstboot.service \
    archiso/airootfs/etc/systemd/system/multi-user.target.wants/ry-install-firstboot.service
```

Add permissions in `profiledef.sh`:
```bash
["/usr/local/bin/ry-install-firstboot.sh"]="0:0:755"
```

**Note:** The first-boot service does NOT write sysfs values — that's already handled by `amdgpu-performance.service` (WantedBy=graphical.target) and `cpupower-epp.service` (WantedBy=multi-user.target), both enabled by the Calamares hook.

---

## Phase 6: Build and Test

### Task 10: Install build dependencies

```bash
sudo pacman -S archiso mkinitcpio-archiso git squashfs-tools grub --needed
```

### Task 11: Build the ISO

```bash
cd cachyos-custom-iso
sudo ./buildiso.sh -p desktop -v -w
```

Output appears in `out/`. Build takes 20-40 minutes depending on hardware and network speed. The `-w` flag removes the work directory after build to save space.

### Task 12: Test in VM first

```bash
# Create test disk
qemu-img create -f qcow2 test-disk.qcow2 40G

# Copy OVMF vars (writable copy needed for UEFI variable persistence)
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd ovmf-vars.fd

# UEFI boot with pflash (not -bios) for proper systemd-boot testing
qemu-system-x86_64 \
    -enable-kvm -m 4G -cpu host \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
    -drive if=pflash,format=raw,file=ovmf-vars.fd \
    -cdrom out/cachyos-desktop-*.iso \
    -drive file=test-disk.qcow2,if=virtio,format=qcow2 \
    -boot d
```

**Verify in VM:**
1. ISO boots to live environment
2. Calamares runs without errors
3. After install + reboot, run `ry-install.fish --verify-static` then `--verify-runtime`
4. Check: configs deployed, services masked, packages correct, kernel params applied

### Task 13: Test on real hardware

Flash to USB: `sudo dd if=out/cachyos-desktop-*.iso of=/dev/sdX bs=4M status=progress conv=fsync`

Install on GTR9 Pro (or spare drive). After reboot:

```fish
ry-install.fish --verify-static    # Check config files
ry-install.fish --verify-runtime   # Check live state (after reboot)
ry-install.fish --diagnose         # System overview + problem detection
ry-install.fish --diff           # Should show no drift
```

---

## Risks and Decisions

| Risk | Mitigation |
|------|------------|
| CachyOS updates their ISO profile and your fork drifts | Pin to a release tag; rebase periodically |
| Calamares module order changes between versions | Document the expected module order; test after CachyOS updates |
| Some PKGS_DEL are pulled in by CachyOS meta-packages | Check reverse deps with `pactree -r`; may need to mask instead of remove |
| `/etc/skel` permissions don't propagate correctly | Test user creation; add `file_permissions` entries if needed |
| `mkinitcpio -P` fails in chroot (missing /proc, /sys) | Calamares binds these before running shellprocess; verify |
| `findmnt -no UUID /` fails in chroot | Fallback to `blkid` on the mounted root device; verify UUID matches target disk in VM test |
| ssh-agent user preset doesn't activate on first login | Preset deployed at build time via airootfs overlay (`etc/systemd/user-preset/`); verify with `systemctl --user is-enabled ssh-agent.service` after first login |
| Secure Boot rejects custom ISO | CachyOS ISOs may ship with shim/MOK; custom hooks shouldn't affect this but test with SB enabled |
| CachyOS auto-configures wireless-regdom from timezone (March 2026) | Static overlay may be overwritten on upgrade; verify regdom persists after `pacman -Syu` |
| CachyOS defaults to Limine bootloader (Jan 2026) | Select systemd-boot explicitly in Calamares; document in install instructions |
| `sdboot-manage` standalone repo archived (Oct 2025) | Reference `CachyOS-PKGBUILDS/systemd-boot-manager/` for current source |
| `packages.x86_64` renamed to `packages_desktop.x86_64` upstream | setup.fish auto-detects both names (v3.8.0) |
| `/etc/kernel/cmdline` not read by sdboot-manage for boot entries | Authoritative params are `LINUX_OPTIONS` in `/etc/sdboot-manage.conf` (static overlay); cmdline file kept for UKI compat and diagnostics; post.sh verifies LINUX_OPTIONS at install time, including commented-out variants (v3.8.0, v3.8.1) |

## Decisions (resolved)

1. **Live environment:** Unchanged — stock CachyOS live env (doubles as recovery)
2. **WiFi credentials:** Not embedded — user connects manually after first boot
3. **Distribution:** Personal use only
4. **Upstream base:** Latest stable tag at build time
5. **power-profiles-daemon:** Masked, not removed — prevents dep reinstallation conflicts (v3.1.0)
6. **LVM guard:** Removed — GTR9 Pro has no LVM; unconditional mask is simpler (v3.1.0)
7. **Bootloader selection:** systemd-boot (explicit choice during Calamares install); Limine is new CachyOS default but project requires systemd-boot for sdboot-manage integration (v3.8.0)
8. **Display manager:** plasma-login-manager is new CachyOS default (Jan 2026); no project impact — not customized (v3.8.0)
9. **Kernel params authority:** `LINUX_OPTIONS` in `/etc/sdboot-manage.conf` is authoritative for boot entries; `/etc/kernel/cmdline` retained for UKI compatibility and `ry-install --verify-runtime` diagnostics (v3.8.0)

---

## Maintenance

After initial build works:

- **ry-install updates:** When you bump ry-install, copy the new script into the ISO tree and rebuild. The configs in `airootfs/` should match what ry-install generates — use `ry-install.fish --diff` on a running system as the source of truth.
- **CachyOS upstream updates:** Periodically rebase your `gtr9-pro` branch on upstream master. Conflicts will be in `packages_desktop.x86_64` (or `packages.x86_64` on older tags) and Calamares configs.
- **CI (optional):** CachyOS has `ci.build.sh` in their repo. Adapt for GitHub Actions to auto-build ISOs on push.
