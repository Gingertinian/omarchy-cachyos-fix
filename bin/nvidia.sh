#!/bin/bash
set -e

# --- NVIDIA Configuration for Omarchy on CachyOS ---
# Philosophy: detect and use whatever NVIDIA driver CachyOS has installed.
# Only install a driver if none is present. Never downgrade or force-replace.

# Exit early if no NVIDIA GPU is present
if ! lspci -nn -d 10de: | grep -qE "VGA|3D"; then
    echo "[*] No NVIDIA GPU found. Skipping."
    exit 0
fi

GPU_NAME=$(lspci -d 10de: | grep -E "VGA|3D" | head -n1 | sed 's/.*: //')
echo "[*] NVIDIA GPU detected: $GPU_NAME"

# Determine if a working NVIDIA driver is already installed
NVIDIA_DRIVER=$(pacman -Qq | grep -E '^nvidia-(dkms|open-dkms|utils)$' | head -n1 || true)

if [[ -n "$NVIDIA_DRIVER" ]]; then
    DRIVER_VERSION=$(pacman -Q "$NVIDIA_DRIVER" 2>/dev/null | awk '{print $2}')
    echo "[*] Active NVIDIA driver found: $NVIDIA_DRIVER $DRIVER_VERSION"
    echo "[*] Respecting existing CachyOS driver installation."
else
    echo "[!] No NVIDIA driver detected — installing via chwd..."
    sudo chwd -a
    echo "[*] Driver installed via CachyOS hardware detection."
fi

# Ensure VA-API utils are present for hardware video acceleration
sudo pacman -S --needed --noconfirm libva-utils

# Detect an integrated GPU (AMD 1002: / Intel 8086:) => hybrid laptop.
# IMPORTANT: '|| true' is required because this script runs with 'set -e' (line 2); a failing
# grep on an NVIDIA-only machine would otherwise abort the script here.
HAS_IGPU=$(lspci -nn | grep -iE 'VGA|3D|Display' | grep -iE '1002:|8086:' || true)
mkdir -p "$HOME/.config/uwsm"

if [[ -n "$HAS_IGPU" ]]; then
    # HYBRID laptop (e.g. AMD iGPU + RTX 4050): the compositor runs on the integrated GPU.
    # Do NOT export GBM_BACKEND=nvidia-drm / __GLX_VENDOR_LIBRARY_NAME=nvidia / LIBVA_DRIVER_NAME=nvidia
    # globally — UWSM sources them for the whole session and they force GBM/GLX onto the NVIDIA
    # device, black-screening the AMD-driven display at login (Hyprland #8308/#1878/#4274) and
    # breaking hardware VA-API on AMD. Install nvidia-prime for per-app offload instead.
    echo "[*] Hybrid GPU detected (integrated GPU present) — NOT setting global NVIDIA env vars."
    sudo pacman -S --needed --noconfirm nvidia-prime   # provides the canonical /usr/bin/prime-run
    echo "[*] Desktop runs on the iGPU. Render a specific app on the NVIDIA dGPU with: prime-run <app>"
elif ! grep -q "GBM_BACKEND=nvidia-drm" "$HOME/.config/uwsm/env" 2>/dev/null; then
    # NVIDIA-only machine: make NVIDIA the primary GBM/GLX backend.
    cat >>"$HOME/.config/uwsm/env" <<'EOF'

# NVIDIA (primary)
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
    echo "[*] NVIDIA (primary) environment variables written to ~/.config/uwsm/env"
else
    echo "[*] NVIDIA environment variables already present."
fi

echo "[*] NVIDIA configuration complete."
