#!/bin/bash

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed. Please install git before running this script."
    exit 1
fi

# Fetch Omarchy from repo
echo "Fetching Omarchy source..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_DIR="$SCRIPT_DIR/../../omarchy"

if [ -f "./fetch-omarchy.sh" ]; then
    chmod +x ./fetch-omarchy.sh
    ./fetch-omarchy.sh
else
    # Fallback if script is missing
    echo "fetch-omarchy.sh not found, falling back to default clone..."
    git clone https://www.github.com/basecamp/omarchy "$OMARCHY_DIR"
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

# Update restart-needed for kernel updates to use cachyos instead of arch
sed -i "s/ | sed 's\/-arch\/\\\.arch\/'//" bin/omarchy-update-restart
sed -i "s/'{print \$2}'/'{print \$2 \"-\" \$1}' | sed 's\/-linux\/\/'/" bin/omarchy-update-restart
sed -i '/linux-cachyos/ ! s/pacman -Q linux/pacman -Q linux-cachyos/' bin/omarchy-update-restart

# Remove pacman.sh from preflight/all.sh to prevent conflict with cachyos packages
sed -i '/run_logged \$OMARCHY_INSTALL\/preflight\/pacman\.sh/d' install/preflight/all.sh

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

# Fix omarchy-ai-skill.sh symlink to be idempotent on re-runs
sed -i 's/ln -s/ln -sf/' install/config/omarchy-ai-skill.sh

# Remove plymouth.sh source line from install.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/plymouth\.sh/d' install/login/all.sh

# Neutralize limine-snapper entirely (CachyOS already manages Limine + Btrfs snapshots via
# limine-snapper-sync; letting Omarchy overwrite /boot/limine.conf breaks CachyOS boot).
# Robust: blank the script wherever it lives AND strip every invocation, so it can't fail
# regardless of which Omarchy version was fetched (the old single-path sed missed newer layouts).
find install -name 'limine-snapper.sh' -exec sh -c 'printf "#!/bin/bash\nexit 0\n" > "$1"' _ {} \;
find install -name 'all.sh' -exec sed -i '/limine-snapper/d' {} +

# Remove alt-bootloaders.sh source line from install.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/alt-bootloaders\.sh/d' install/login/all.sh

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

# Pin walker to the omarchy repo so CachyOS doesn't override it with an
# incompatible version that breaks compatibility with elephant.
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

# Update mise activation to support both bash and fish
sed -i 's/omarchy-cmd-present mise && eval "\$(mise activate bash)"/if [ "\$SHELL" = "\/bin\/bash" ] \&\& command -v mise \&> \/dev\/null; then\n  eval "\$(mise activate bash)"\nelif [ "\$SHELL" = "\/bin\/fish" ] \&\& command -v mise \&> \/dev\/null; then\n  mise activate fish | source\nfi/' config/uwsm/env

# Fix SDDM autologin to use the intended username instead of $USER.
# The install runs as root, so without this fix autologin.conf would get User=root (PR #38).
if [ -f install/login/sddm.sh ]; then
  sed -i "s/User=\$USER/User=$OMARCHY_USER_NAME/" install/login/sddm.sh 2>/dev/null || true
fi

# Copy omarchy installation files to ~/.local/share/omarchy
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
echo "IMPORTANT: If you installed CachyOS without a deskop environment, you will not have a display manager installed." 
echo "If this is the case, you will need to run the following command after this installation script is complete:"
echo " 1.) ~/.local/share/omarchy/install/login/plymouth.sh"  
echo ""
echo "The aboves script will modify your boot to start Omarchy's Hyprland desktop automatically." 
echo ""
echo "Press Enter to begin the installation of Omarchy..."
read -r

# Remove existing claude-code to prevent a file conflict during the omarchy install.
# (CachyOS may have installed it separately; pacman aborts if /usr/bin/claude already exists.) PR #38
if pacman -Q claude-code &>/dev/null 2>&1; then
    echo "Removing existing claude-code package to avoid file conflict..."
    sudo pacman -Rdd --noconfirm claude-code
elif [ -f /usr/bin/claude ]; then
    echo "Removing existing /usr/bin/claude to avoid file conflict..."
    sudo rm -f /usr/bin/claude
fi

# Run the modified install.sh script
chmod +x install.sh
./install.sh
