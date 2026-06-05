#!/bin/bash

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed. Please install git before running this script."
    exit 1
fi

# Do NOT run with sudo: omarchy v5's guard.sh aborts when EUID==0. Run as your normal user
# (the script uses sudo only where needed).
if [ "$EUID" -eq 0 ]; then
    echo "Do NOT run this installer with sudo — omarchy aborts as root. Run it as your normal user."
    exit 1
fi

# Fetch Omarchy from repo
echo "Fetching Omarchy source..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_DIR="$SCRIPT_DIR/../../omarchy"

# Locate fetch-omarchy.sh next to this script (absolute), not via the current directory (PR #50).
if [ -f "$SCRIPT_DIR/fetch-omarchy.sh" ]; then
    chmod +x "$SCRIPT_DIR/fetch-omarchy.sh"
    (cd "$SCRIPT_DIR" && ./fetch-omarchy.sh)
else
    # Fallback if script is missing
    echo "fetch-omarchy.sh not found next to the installer, falling back to default clone..."
    git clone https://github.com/basecamp/omarchy "$OMARCHY_DIR"
fi

if [ ! -d "$OMARCHY_DIR" ]; then
    echo "Error: Failed to fetch Omarchy source at $OMARCHY_DIR"
    exit 1
fi

# Check if yay is installed
if ! command -v yay &> /dev/null; then
    echo "yay is not installed. Installing yay..."

    # Install dependencies for building yay
    sudo pacman -S --needed --noconfirm git base-devel

    # Clone and build yay
    git clone https://aur.archlinux.org/yay.git /tmp/yay
    cd /tmp/yay
    makepkg -si --noconfirm
    cd -

    # Clean up
    rm -rf /tmp/yay

    if ! command -v yay &> /dev/null; then
        echo "Error: Failed to install yay."
        exit 1
    fi

    echo "yay has been successfully installed."
else
    echo "yay is already installed."
fi

# Receive the Omarchy signing key (try multiple keyservers — the default one fails often)
OMARCHY_KEY=F0134EE680CAC571
for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org hkp://keyserver.ubuntu.com:80; do
    echo "Trying keyserver: $ks"
    sudo pacman-key --keyserver "$ks" --recv-keys "$OMARCHY_KEY" && break
done

if ! sudo pacman-key --list-keys "$OMARCHY_KEY" &>/dev/null; then
    echo "Error: Failed to import omarchy signing key from all keyservers."
    exit 1
fi

# Locally sign and trust the key
sudo pacman-key --lsign-key "$OMARCHY_KEY"

# Add omarchy repository to pacman.conf (skip if already present)
if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
    echo -e "\n[omarchy]\nSigLevel = Optional TrustedOnly\nServer = https://pkgs.omarchy.org/\$arch" | sudo tee -a /etc/pacman.conf > /dev/null
else
    echo "Omarchy repository already present in pacman.conf, skipping."
fi
sudo pacman -Syu

# Remove CachyOS SDDM config
if [ -f /etc/sddm.conf ]; then
    echo "Removing /etc/sddm.conf"
    sudo rm /etc/sddm.conf
fi

# Prompt user for username
echo ""
echo "Please enter your username:"
read -r OMARCHY_USER_NAME
export OMARCHY_USER_NAME

# Prompt user for email address
echo ""
echo "Please enter your email address:"
read -r OMARCHY_USER_EMAIL
export OMARCHY_USER_EMAIL

# Optional: defer NVIDIA setup.
# Useful on hybrid laptops (AMD/Intel iGPU + NVIDIA dGPU): boot on the integrated GPU first,
# confirm the desktop works, then add NVIDIA later. If you skip it here, a ready-to-run copy is
# left at ~/.local/share/omarchy/install/config/hardware/nvidia-later.sh
echo ""
echo "Do you want to configure NVIDIA drivers NOW?"
echo "  - Say 'n' if you have a hybrid AMD/Intel + NVIDIA laptop and want to boot on the iGPU first."
echo "    You can run NVIDIA setup later with:"
echo "      ~/.local/share/omarchy/install/config/hardware/nvidia-later.sh"
read -r -p "Configure NVIDIA now? [y/N]: " SETUP_NVIDIA

# Make adjustments to Omarchy install scripts to support CachyOS
echo ""
echo "Making adjustments to Omarchy install scripts to support CachyOS..."

# Navigate to Omarchy install scripts (absolute path — robust regardless of CWD; PR #50)
cd "$OMARCHY_DIR"

# Remove tldr from EVERY package list — CachyOS ships tealdeer, which provides the same
# /usr/bin/tldr and conflicts with the `tldr` package, aborting packaging/base.sh.
# Robust: exact-line match across all *.packages, not just the one file (newer Omarchy layouts).
find install -name '*.packages' -exec sed -i '/^tldr$/d' {} +

# Remove `yay` from EVERY package list — CachyOS users commonly run `yay-bin` (provides
# /usr/bin/yay) which CONFLICTS with the `yay` package omarchy lists; base.sh's batch
# `pacman -S --noconfirm --needed` can't resolve it non-interactively and aborts (mroboff #32).
# Safe: this fork already guarantees a working `yay` above. Exact-line match never hits yay-bin/yay-debug.
find install -name '*.packages' -exec sed -i '/^yay$/d' {} +

# omarchy v5 rewrote omarchy-update-restart (vmlinuz + pacman -Qo + uname -r, NOT `pacman -Q linux`),
# which is already kernel-name-agnostic and works on CachyOS. Only patch the legacy pattern if it
# reappears (older tags selectable via fetch-omarchy.sh) — never patch blindly into a no-op.
if grep -q 'pacman -Q linux' bin/omarchy-update-restart 2>/dev/null; then
    sed -i "s/ | sed 's\/-arch\/\\\.arch\/'//" bin/omarchy-update-restart
    sed -i "s/'{print \$2}'/'{print \$2 \"-\" \$1}' | sed 's\/-linux\/\/'/" bin/omarchy-update-restart
    sed -i '/linux-cachyos/ ! s/pacman -Q linux/pacman -Q linux-cachyos/' bin/omarchy-update-restart
fi

# Remove pacman.sh from preflight/all.sh to prevent conflict with cachyos packages
sed -i '/run_logged \$OMARCHY_INSTALL\/preflight\/pacman\.sh/d' install/preflight/all.sh

# Neutralize omarchy v5 guard.sh (BLOCKER on CachyOS): preflight/all.sh SOURCES guard.sh into
# install.sh's main shell (set -eEo pipefail, shares the TTY). On CachyOS /etc/cachyos-release
# exists -> guard.sh calls abort() -> `gum confirm || exit 1`: piped/no-TTY -> exit 1 aborts the
# WHOLE install; with a TTY -> a surprise y/n mid-install. Drop ONLY the Arch-derivative marker
# loop; the other guards (limine/btrfs/x86_64/non-root/secure-boot/no-GNOME-KDE) stay active and
# CachyOS legitimately satisfies them.
if [ -f install/preflight/guard.sh ]; then
    sed -i '/^for marker in .*cachyos-release/,/^done$/d' install/preflight/guard.sh
    grep -q 'cachyos-release' install/preflight/guard.sh && \
        echo "WARN: guard.sh still references cachyos-release after patch — review it" >&2 || true
    # Also drop the "must have Limine" guard so Omarchy installs on a GRUB-based CachyOS too.
    # Omarchy's Limine-specific bits (limine-snapper) are already neutralized above; the rest of
    # Omarchy (Hyprland/UWSM session + configs) is bootloader-agnostic. Snapshots stay on CachyOS's
    # own tooling (grub-btrfs) instead of Omarchy's limine-snapper-sync.
    sed -i '/command -v limine &>\/dev\/null || abort/d' install/preflight/guard.sh
fi

# Do NOT disable the mkinitcpio pacman hooks on CachyOS (BLOCKER, latent). Upstream disables them
# for install speed and only re-enables them at the bottom of login/limine-snapper.sh — which we
# blank out — so they would stay *.disabled FOREVER. The next `pacman -Syu` kernel upgrade and the
# NVIDIA DKMS rebuilds would then never regenerate the initramfs/UKI -> unbootable-after-update.
find install -name 'disable-mkinitcpio.sh' -exec sh -c 'printf "#!/bin/bash\nexit 0\n" > "$1"' _ {} \;
sed -i '/disable-mkinitcpio/d' install/preflight/all.sh

# Replace nvidia.sh with custom CachyOS driver logic (absolute path; PR #50)
cp "$SCRIPT_DIR/nvidia.sh" install/config/hardware/nvidia.sh
chmod +x install/config/hardware/nvidia.sh

# If the user chose to defer NVIDIA, keep a runnable copy as nvidia-later.sh and turn the
# install-time nvidia.sh into a no-op (so the desktop comes up on the AMD/Intel iGPU first).
if [[ ! "${SETUP_NVIDIA,,}" =~ ^(y|yes)$ ]]; then
    cp "$SCRIPT_DIR/nvidia.sh" install/config/hardware/nvidia-later.sh
    chmod +x install/config/hardware/nvidia-later.sh
    printf '#!/bin/bash\necho "[*] NVIDIA setup deferred. Run nvidia-later.sh in this folder to configure it."\nexit 0\n' > install/config/hardware/nvidia.sh
    chmod +x install/config/hardware/nvidia.sh
    echo "[*] NVIDIA setup deferred — will run on the integrated GPU. Use nvidia-later.sh afterwards."
fi

# Fix omarchy-ai-skill.sh symlink to be idempotent — only if upstream still uses the plain
# `ln -s ` form (v5 already uses `ln -sfn`; blindly seding it would make a malformed `ln -sffn`).
if grep -qE 'ln -s ' install/config/omarchy-ai-skill.sh 2>/dev/null; then
    sed -i 's/ln -s /ln -sfn /g' install/config/omarchy-ai-skill.sh
fi

# Remove plymouth.sh source line from install.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/plymouth\.sh/d' install/login/all.sh

# Neutralize limine-snapper entirely (CachyOS already manages Limine + Btrfs snapshots via
# limine-snapper-sync; letting Omarchy overwrite /boot/limine.conf breaks CachyOS boot).
# Robust: blank the script wherever it lives AND strip every invocation, so it can't fail
# regardless of which Omarchy version was fetched (the old single-path sed missed newer layouts).
find install -name 'limine-snapper.sh' -exec sh -c 'printf "#!/bin/bash\nexit 0\n" > "$1"' _ {} \;
find install -name 'all.sh' -exec sed -i '/limine-snapper/d' {} +

# Skip Omarchy's hibernation setup on CachyOS: omarchy-hibernation-setup creates a RAM-sized btrfs
# swapfile, edits /etc/fstab, and injects resume=/resume_offset= + HOOKS+=(resume) into
# /etc/default/limine (i.e. into CachyOS's native Limine stack), all unprompted. Let the user opt
# into hibernation later via CachyOS's own tooling.
find install -name 'all.sh' -exec sed -i '/login\/hibernation\.sh/d' {} +

# Remove alt-bootloaders.sh invocation (gone in v5; defensive for older selectable tags).
find install -name 'all.sh' -exec sed -i '/alt-bootloaders/d' {} +

# Remove pacman.sh from post-install/all.sh to prevent conflict with cachyos packages
sed -i '/run_logged \$OMARCHY_INSTALL\/post-install\/pacman\.sh/d' install/post-install/all.sh

# Disable wpa_supplicant and configure NetworkManager to use iwd backend.
# CachyOS enables wpa_supplicant by default, which conflicts with omarchy's iwd,
# causing WiFi to appear connected but have no IP or connectivity.
# Only append once — avoid duplicating the block on re-runs (issue #49)
if ! grep -q "wifi.backend=iwd" install/config/hardware/network.sh 2>/dev/null; then
cat >> install/config/hardware/network.sh << 'NETEOF'

# Disable wpa_supplicant to prevent conflict with iwd
sudo systemctl disable --now wpa_supplicant.service 2>/dev/null

# Configure NetworkManager to use iwd as its WiFi backend
if ! grep -q "wifi.backend=iwd" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
  sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null << EOF

[device]
wifi.backend=iwd
EOF
fi
NETEOF
fi

# Pin walker to the omarchy repo so CachyOS doesn't override it with an incompatible version that
# breaks compatibility with elephant. Idempotent: the source tree ($OMARCHY_DIR) is reused across
# runs, so only insert the block once (the `1a` would otherwise duplicate it every run).
if ! grep -q 'Pin walker to omarchy repo' install/config/walker-elephant.sh 2>/dev/null; then
sed -i '1a\
# Pin walker to omarchy repo to prevent CachyOS version conflict\
if ! grep -q "^IgnorePkg.*walker" /etc/pacman.conf 2>/dev/null; then\
  if grep -q "^IgnorePkg" /etc/pacman.conf; then\
    sudo sed -i '"'"'s/^IgnorePkg = \\(.*\\)/IgnorePkg = \\1 walker/'"'"' /etc/pacman.conf\
  else\
    sudo sed -i '"'"'/^\\[options\\]/a IgnorePkg = walker'"'"' /etc/pacman.conf\
  fi\
fi\
' install/config/walker-elephant.sh
fi

# Update mise activation to support both bash and fish. Loose match tolerates v5's `--shims`, and
# the shell check is path-agnostic (fish lives in /usr/bin/fish on CachyOS, not /bin/fish).
sed -i 's@omarchy-cmd-present mise && eval "\$(mise activate bash[^)]*)"@if command -v mise \&> /dev/null; then\n  case "$SHELL" in\n    */fish) mise activate fish | source ;;\n    *) eval "$(mise activate bash)" ;;\n  esac\nfi@' config/uwsm/env

# Make Omarchy's `cp default/bashrc ~/.bashrc` non-destructive (back up the user's bashrc first;
# CachyOS defaults to fish and may carry its own dotfiles).
sed -i 's#^cp ~/.local/share/omarchy/default/bashrc ~/.bashrc#[ -f ~/.bashrc ] \&\& cp ~/.bashrc ~/.bashrc.pre-omarchy; cp ~/.local/share/omarchy/default/bashrc ~/.bashrc#' install/config/config.sh

# Fix SDDM autologin to use the intended username instead of literal $USER. Defensive: if the
# wrapper were ever launched with sudo, autologin.conf could get User=root. (install.sh itself
# runs as your user — omarchy v5 aborts as root.) PR #38
if [ -f install/login/sddm.sh ]; then
  sed -i "s/User=\$USER/User=$OMARCHY_USER_NAME/" install/login/sddm.sh 2>/dev/null || true
fi

# Copy omarchy installation files to ~/.local/share/omarchy.
# Regenerate from scratch every run so a stale copy can't keep an un-patched file
# (e.g. an old omarchy-base.packages that still lists tldr). This is the root-cause fix
# for "fixed the script but the install still fails" — the running copy must be fresh.
rm -rf ~/.local/share/omarchy
mkdir -p ~/.local/share/omarchy
cp -r . ~/.local/share/omarchy
cd ~/.local/share/omarchy

# Pause and prompt for acknowledgment to begin installation
echo ""
echo "The following adjustments have been completed."
echo " 1. Added Omarchy repo to pacman.conf"
echo " 2. Removed tldr from packages.sh to avoid conflict with tealdeer on CachyOS."
echo " 3. Disabled further Omarchy changes to pacman.conf, preserving CachyOS settings."
if [[ "${SETUP_NVIDIA,,}" =~ ^(y|yes)$ ]]; then
  echo " 4. NVIDIA: configured now (respects existing CachyOS drivers; only installs if none present)."
else
  echo " 4. NVIDIA: DEFERRED. Boot on the integrated GPU, then run:"
  echo "      ~/.local/share/omarchy/install/config/hardware/nvidia-later.sh"
fi
echo " 5. Removed plymouth.sh from install.sh to avoid conflict with CachyOS login display manager installation."
echo " 6. Removed limine-snapper.sh from install.sh to avoid conflict with CachyOS boot loader installation."
echo " 7. Removed alt-bootloaders.sh from install.sh to avoid conflict with CachyOS boot loader installation."
echo " 8. Removed /etc/sddm.conf to avoid conflict with Omarchy UWSM session autologin."
echo " 9. Disabled wpa_supplicant and configured NetworkManager to use iwd backend."
echo "10. Pinned walker to omarchy repo to prevent CachyOS version conflict."
echo ""
echo "NOTE: Omarchy installs and ENABLES SDDM on every install (sddm/hyprland/uwsm are in"
echo "omarchy-base.packages and login/sddm.sh runs the enable), so after reboot you go straight"
echo "into the graphical Omarchy/Hyprland (UWSM) login automatically."
echo "plymouth.sh is NOT needed for that — it only sets the boot splash theme."
echo ""
echo "If you ever land on a TTY after reboot, the DM is already installed, so just run:"
echo "  sudo systemctl enable --now sddm.service"
echo ""
echo "Press Enter to begin the installation of Omarchy..."
read -r

# CachyOS ships tealdeer (which Provides+Conflicts tldr). Omarchy lists the real `tldr` directly in
# omarchy-base.packages, so the batch `pacman -S` hits tealdeer's Conflicts and aborts
# packaging/base.sh. Stripping tldr from the lists (above) already fixes the abort; we ALSO remove
# tealdeer as belt-and-suspenders (and to use the upstream tldr client) — both give /usr/bin/tldr.
if pacman -Q tealdeer &>/dev/null 2>&1; then
    echo "Removing tealdeer (conflicts with the tldr dependency Omarchy needs)..."
    sudo pacman -Rdd --noconfirm tealdeer || true
fi

# Remove existing claude-code to prevent a file conflict during the omarchy install.
# (CachyOS may have installed it separately; pacman aborts if /usr/bin/claude already exists.) PR #38
if pacman -Q claude-code &>/dev/null 2>&1; then
    echo "Removing existing claude-code package to avoid file conflict..."
    sudo pacman -Rdd --noconfirm claude-code || true
elif [ -f /usr/bin/claude ]; then
    echo "Removing existing /usr/bin/claude to avoid file conflict..."
    sudo rm -f /usr/bin/claude
fi

# Self-heal: if a previous (un-patched) run disabled the mkinitcpio pacman hooks, re-enable them
# now. Upstream's only re-enable lives in limine-snapper.sh (which we blank), so without this a
# system left mid-install would never regenerate its initramfs -> unbootable on the next update.
for h in 90-mkinitcpio-install 60-mkinitcpio-remove; do
    if [ -f "/usr/share/libalpm/hooks/$h.hook.disabled" ]; then
        echo "Re-enabling mkinitcpio hook: $h"
        sudo mv "/usr/share/libalpm/hooks/$h.hook.disabled" "/usr/share/libalpm/hooks/$h.hook" || true
    fi
done

# Run the modified install.sh script
chmod +x install.sh
./install.sh
