# omarchy-on-cachyos (fix fork)

> **Fork of [mroboff/omarchy-on-cachyos](https://github.com/mroboff/omarchy-on-cachyos)** with reliability fixes. All credit for the original work goes to mroboff (MIT). See **[§0 Fixes in this fork](#0-fixes-in-this-fork)** below.

- UPDATE 20-May-2026: The install script now includes interactive version selection for choosing between Stable releases and Bleeding Edge.
- UPDATE 1-October-2025: The install script has been updated to support Omarchy 3.0+ out of the box.

## 0. Fixes in this fork

### a) `limine-snapper.sh` no longer breaks the install (main fix)

The upstream script removed Omarchy's `limine-snapper.sh` call with a single brittle `sed` that only edited `install/login/all.sh`. On several Omarchy versions that line lives elsewhere, so the removal silently failed and `limine-snapper.sh` ran anyway — overwriting `/boot/limine.conf` (or aborting with `Error: Limine config not found`), because **CachyOS already manages Limine + Btrfs snapshots via `limine-snapper-sync`** and keeps its config at `/boot/limine.conf`, not `/boot/limine/limine.conf`.

This fork neutralizes it robustly regardless of Omarchy version:

```bash
find install -name 'limine-snapper.sh' -exec sh -c 'printf "#!/bin/bash\nexit 0\n" > "$1"' _ {} \;
find install -name 'all.sh' -exec sed -i '/limine-snapper/d' {} +
```

The script is blanked to `exit 0` **wherever** it lives, and **every** invocation is stripped. Your existing CachyOS Limine + snapshots are left untouched.

### b) NVIDIA is now optional / deferrable (hybrid AMD-or-Intel iGPU + NVIDIA laptops)

The installer now **asks** whether to configure NVIDIA now. Answer **`n`** to boot on your integrated GPU first (recommended on a hybrid laptop — get a working desktop, *then* add the dGPU). A ready-to-run copy is left for later:

```bash
~/.local/share/omarchy/install/config/hardware/nvidia-later.sh
```

The bundled `nvidia.sh` respects whatever driver CachyOS already installed and only falls back to `chwd -a` if none is present (it never force-removes your drivers). NVIDIA troubleshooting notes for RTX 40-series (incl. RTX 4050) are in §4.

### c) Omarchy v5 blockers (found by a multi-agent audit, verified)

These were added in Omarchy v5 and were not handled by the original wrapper:

| Area | Fix |
|---|---|
| **`guard.sh` aborts on CachyOS** | v5's `install/preflight/guard.sh` detects `/etc/cachyos-release` and calls `abort` → `gum confirm \|\| exit 1`, killing the install (or forcing a surprise y/n mid-run). We strip **only** the Arch-derivative marker loop; the other guards (limine/btrfs/x86_64/non-root/secure-boot) stay active and CachyOS satisfies them. |
| **`disable-mkinitcpio.sh` → unbootable after update** | v5 disables the mkinitcpio pacman hooks for install speed and only re-enables them at the bottom of `limine-snapper.sh` (which we blank). Left as-is they'd stay `*.disabled` forever → the next kernel `pacman -Syu` / NVIDIA DKMS rebuild never regenerates the initramfs → unbootable. We skip the disable entirely. |
| **NVIDIA env vars black-screen hybrids** | `nvidia.sh` used to always write `GBM_BACKEND=nvidia-drm` etc. to `uwsm/env`. On a hybrid laptop (AMD iGPU + RTX 4050) that black-screens the iGPU display at login. Now it detects an iGPU and instead installs `nvidia-prime` (use `prime-run <app>`). |
| **`hibernation.sh`** | Skipped: it creates a RAM-sized btrfs swapfile, edits `/etc/fstab`, and injects `resume=` into CachyOS's native Limine stack, all unprompted. |

### d) Other reliability fixes folded in

| Source | Fix |
|---|---|
| **PR #50** | Absolute paths (`$OMARCHY_DIR` / `$SCRIPT_DIR`) so the script works from any CWD, not just `bin/`. |
| **PR #50** | `fetch-omarchy.sh` located via `$SCRIPT_DIR` (not the CWD), so the version selector isn't skipped. |
| **PR #38** | Multi-keyserver fallback for the Omarchy signing key (the default `--recv-keys` fails often). |
| **PR #38** | SDDM autologin uses your real username instead of `root`. |
| **PR #38** | Removes a pre-existing `claude-code` / `/usr/bin/claude` to avoid a pacman file conflict. |
| **Issue #49** | WiFi/iwd block is only appended once (idempotent on re-runs). |
| **Issue #32** | `yay` stripped from every `*.packages` (a pre-existing `yay-bin` would conflict and abort `base.sh`). |
| **tldr/tealdeer** | `tldr` stripped from every `*.packages` **and** `tealdeer` removed pre-install (both provide `/usr/bin/tldr` → `packaging/base.sh` aborts). |
| **fresh copy** | `~/.local/share/omarchy` is wiped and regenerated each run, so a stale un-patched copy can never run (root cause of "patched the script but install still fails"). |
| **non-destructive** | backs up `~/.bashrc` before Omarchy overwrites it; refuses to run as root; mise activation works under fish on CachyOS. |

All credit for the underlying fixes goes to the original PR authors on [mroboff/omarchy-on-cachyos](https://github.com/mroboff/omarchy-on-cachyos).

## 1. Introduction

This project provides an installation script for implementing DHH's Omarchy configuration on top of CachyOS. Omarchy is an 'opinionated' desktop setup, based on Hyprland that emphasizes simplicity and productivity, while CachyOS offers a performance-optimized Arch Linux distribution.

## 2. What This Script Does and Does Not Do

This installation script does the following three things:

  1) Prompts for and fetches your preferred version of Omarchy (Stable tags or Bleeding Edge)
  2) Makes adjustments to the Omarchy install scripts to support installation on CachyOS
  3) Launches the installation of Omarchy on an already setup CachyOS system
  4) Detects/configures the correct NVIDIA driver via CachyOS `chwd` (nvidia-open-dkms for RTX 40-series/Turing+; the legacy nvidia-580xx branch only for pre-Turing Maxwell/Pascal/Volta), respecting any driver CachyOS already installed — and makes it **optional/deferrable** on hybrid AMD/Intel + NVIDIA laptops

This script does not:

 1) Install CachyOS or any other Linux operating system
 2) Partition, format, or encrypt hard disks
 3) Install or configure a boot loader
 5) Install or configure a login display manager

All of the above need to be done when you install CachyOS. 

## 3. Important Notes

This script (and README.md) is intended primarily for the experienced Arch Linux user. The author of this README.md assumes the reader is comfortable using a shell/command line and is familiar with Arch specific terms such as AUR.

The philosophy behind this script is to produce a strong and stable blend of CachyOS and Omarchy that changes as little as possible between the two. This script does not add software or make configuration changes outside of what CachyOS or Omarchy provide as default, except when such software or configurations provided by CachyOS and Omarchy are in conflict. In these cases, the script will choose the following:

1. AUR helper: CachyOS uses Paru by default while Omarchy uses Yay. This script opts for Yay and will install it if not already installed.

2. Shell: CachyOS uses the Fish shell by default while Omarchy uses Bash. This script will keep Fish as the default interactive shell.

3. TLDR implementation: CachyOS installs Tealdeer by default, which is a TLDR implementation written in Rust. This script will preserve use of Tealdeer.

4. Mise: Omarchy will setup Mise to run automatically via mise-activate. This script will supply the right mise-activate command for the fish shell.

5. Login System: As a distribution, Omarchy skips installation of a login display manager. Instead, Hyprland autostarts and password protection is provided upon boot by the LUKS full disk encryption service. This script, however, assumes a display manager is installed. (Note: this script does not install a display manager, but also does not configure Hyprland to start automatically if a display manager is not installed.)

6. Full Disk Encryption: As a distribution, Omarchy automatically turns on full disk encryption via LUKS. This script, however, leaves this decision up to the user. CachyOS can be installed with or without full disk encryption, and this script will install Omarchy on either setup.

7. NVIDIA Drivers: This script does **not** force a specific driver. It respects whatever driver CachyOS already installed and only falls back to `chwd -a` if none is present. For an RTX 40-series (Ada / Turing+ with GSP, including the RTX 4050) that resolves to `nvidia-open-dkms`; the legacy `nvidia-580xx` branch is for pre-Turing GPUs only. On a **hybrid laptop** (AMD/Intel iGPU + NVIDIA dGPU) it does **not** write the NVIDIA-primary env vars (they black-screen the iGPU-driven display) — it installs `nvidia-prime` so you run specific apps on the dGPU with `prime-run <app>`.

## 4. Pre-Requisites

IMPORTANT: This script does not install CachyOS. You must do that separately (and first.) This script is intended to be run on a fresh installation of CachyOS with the following configuration choices made: (Note, for information on installing CachyOS, please refer to https://www.cachyos.org.) 

1. File System: You must choose BTRFS as the file system and Snapper as the snapshot manager. This aligns with CachyOS's default recommendation for most systems, and is required for Omarchy to properly function.

2. Shell: You must choose Fish as the default shell for this installation script to work properly. (This is the default CachyOS shell choice.)

3. Desktop Environment to Install: You can install a minimal system with no desktop environment or you can choose to install the CachyOS Hyprland Desktop Environment. If you have CachyOS install Hyprland, it will also install SDDM as the login display manager by default. Do not install GNOME or KDE.

4. Graphics Drivers for NVIDIA users: 

5. This script defers to CachyOS `chwd` auto-detection (and respects any pre-existing driver). On an RTX 40-series (Ada) laptop this installs `nvidia-open-dkms`. It does **not** pin the legacy 580xx branch. NVIDIA setup is optional at install time — on a hybrid laptop, answer `n` and run it later.

   **Important:** 

   To enable hardware video decode via NVDEC in chromium, you must:
   
   1. Add the following to `~/.config/chromium-flags.conf`:       ```       --enable-features=VaapiOnNvidiaGPUs       ```
   2. Install the [enhanced-h264ify extension](https://chromewebstore.google.com/detail/enhanced-h264ify/omkfmpieigblcllmkgbflkikinpkodlk) and disable **VP8** and **AV1** codecs.
   
   
   
   To fully enable hardware acceleration in Firefox, you must 
   
   1. Install the [enhanced-h264ify add-on](https://addons.mozilla.org/en-US/firefox/addon/enhanced-h264ify/) and disable **VP8** and **AV1** codecs and manually add the following overrides to your `user.js`:
   
   ```js
   // FORCE NVIDIA HARDWARE ACCELERATION
   user_pref("media.hardware-video-decoding.force-enabled", true);
   user_pref("media.hardware-video-encoding.force-enabled", true);
   user_pref("layers.acceleration.force-enabled", true);
   user_pref("webgl.force-enabled", true);
   user_pref("media.ffmpeg.vaapi.enabled", true);
   user_pref("media.rdd-ffmpeg.enabled", true);
   user_pref("media.av1.enabled", true);
   user_pref("widget.dmabuf.force-enabled", true);
   user_pref("gfx.x11-egl.force-enabled", true);
   ```

Other configuration changes are up to you. Note, however, that this script has not been extensively tested on various CachyOS installations other than the author's own machine.

### NVIDIA troubleshooting (RTX 40-series / Ada, incl. RTX 4050)

If the desktop misbehaves after enabling NVIDIA (black screen on login, flicker, no hardware video decode):

1. **Confirm KMS is on.** `nvidia_drm.modeset=1` must be set. On CachyOS-Limine check it is on the kernel cmdline:
   ```bash
   cat /proc/cmdline | tr ' ' '\n' | grep nvidia
   ```
   If missing, add `nvidia_drm.modeset=1` to your cmdline in `/boot/limine.conf` (CachyOS layout) and reboot.

2. **Modules in the initramfs.** Ensure the four NVIDIA modules are loaded early:
   ```bash
   sudo nano /etc/mkinitcpio.conf   # MODULES=(... nvidia nvidia_modeset nvidia_uvm nvidia_drm)
   sudo mkinitcpio -P
   ```
   Avoid having both a manual `nvidia` mkinitcpio hook **and** the modules listed — pick one (modules are simplest). Duplicate hooks are a common cause of build failures.

3. **Hybrid laptops (AMD/Intel iGPU + RTX 4050).** Run the compositor on the iGPU and let NVIDIA do offload/decoding. The env vars the script writes to `~/.config/uwsm/env` (`GBM_BACKEND`, `__GLX_VENDOR_LIBRARY_NAME`, `LIBVA_DRIVER_NAME=nvidia`, etc.) assume NVIDIA-primary; on a hybrid setup you may want to **comment them out** first, confirm the desktop runs on AMD, then enable per-app GPU offload with `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>`.

4. **`open` vs proprietary.** The RTX 4050 (Ada) works on both. If `nvidia-open-dkms` gives you trouble, switch to the proprietary 580xx series via `sudo chwd` and rebuild the initramfs.

5. **Re-running NVIDIA setup later** (if you deferred it): just run
   ```bash
   ~/.local/share/omarchy/install/config/hardware/nvidia-later.sh
   ```

## 5. Installation Instructions

```bash
# Clone this fork
git clone https://github.com/Gingertinian/omarchy-cachyos-fix.git

# Navigate to the project directory
cd omarchy-cachyos-fix/bin

# Make the script executable
chmod +x install-omarchy-on-cachyos.sh

# Run the installation script
./install-omarchy-on-cachyos.sh
```

**Note:** Please review the script contents before running to understand what changes will be made to your system.

## 6. Statement of Lack of Warranty

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Use this script at your own risk. Always backup your system and important data before running installation scripts.

## 7. How to Contribute

We welcome contributions to improve this project! Here's how you can help:

1. **Fork the Repository**: Click the "Fork" button on GitHub to create your own copy
2. **Create a Feature Branch**: `git checkout -b feature/your-feature-name`
3. **Make Your Changes**: Implement your improvements or fixes
4. **Commit Your Changes**: `git commit -m "Add descriptive commit message"`
5. **Push to Your Fork**: `git push origin feature/your-feature-name`
6. **Open a Pull Request**: Submit a PR with a clear description of your changes

### Contribution Guidelines
- Test your changes thoroughly on CachyOS before submitting
- Follow existing code style and conventions
- Update documentation if adding new features
- Report bugs using GitHub Issues 
