#!/bin/bash
###############################################################################
# install.sh - One-command installer for Zero-Latency Endoscopy Live Feed
#
# Usage: sudo bash install.sh
###############################################################################

set -euo pipefail

INSTALL_DIR="/opt/livefeed"
SERVICE_NAME="livefeed"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }
info()  { echo -e "${CYAN}[i]${NC} $*"; }

# ─── Check root ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root. Use: sudo bash install.sh"
    exit 1
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Zero-Latency Endoscopy Live Feed - Installer${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""

# ─── Step 1: Install dependencies ───────────────────────────────────────────
info "Step 1/6: Installing GStreamer and dependencies..."
apt-get update -qq
apt-get install -y -qq \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-gl \
    gstreamer1.0-libav \
    v4l-utils \
    libgstreamer1.0-0 \
    libgstreamer-plugins-base1.0-0 \
    util-linux \
    2>/dev/null
log "Dependencies installed."

# ─── Step 2: Create install directory ────────────────────────────────────────
info "Step 2/6: Setting up ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
cp "${SCRIPT_DIR}/livefeed.sh" "${INSTALL_DIR}/livefeed.sh"
chmod +x "${INSTALL_DIR}/livefeed.sh"
log "Script installed to ${INSTALL_DIR}/livefeed.sh"

# ─── Step 3: Install systemd service ────────────────────────────────────────
info "Step 3/6: Installing systemd service..."
cp "${SCRIPT_DIR}/livefeed.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
log "Service installed."

# ─── Step 4: Enable service for auto-start ───────────────────────────────────
info "Step 4/6: Enabling auto-start on boot..."
systemctl enable "${SERVICE_NAME}.service"
log "Service enabled. Live feed will start automatically on boot."

# ─── Step 5: Disable screen blanking ────────────────────────────────────────
info "Step 5/6: Disabling screen blanking..."

# Disable console blanking via kernel parameter
if [ -f /boot/cmdline.txt ]; then
    if ! grep -q "consoleblank=0" /boot/cmdline.txt; then
        sed -i 's/$/ consoleblank=0/' /boot/cmdline.txt
        log "Console blanking disabled in /boot/cmdline.txt"
    else
        log "Console blanking already disabled."
    fi
fi

# Also for firmware config
if [ -f /boot/config.txt ]; then
    # Disable screen blanking
    if ! grep -q "hdmi_blanking=0" /boot/config.txt; then
        echo "" >> /boot/config.txt
        echo "# Live Feed: Disable HDMI blanking" >> /boot/config.txt
        echo "hdmi_blanking=0" >> /boot/config.txt
    fi

    # Force HDMI output (don't switch off if no signal)
    if ! grep -q "hdmi_force_hotplug=1" /boot/config.txt; then
        echo "hdmi_force_hotplug=1" >> /boot/config.txt
    fi

    # Boost GPU memory for video processing
    if ! grep -q "gpu_mem=" /boot/config.txt; then
        echo "" >> /boot/config.txt
        echo "# Live Feed: GPU memory for video" >> /boot/config.txt
        echo "gpu_mem=256" >> /boot/config.txt
    fi

    log "Boot config updated."
fi

# Also check /boot/firmware/ (newer Pi OS)
if [ -f /boot/firmware/cmdline.txt ]; then
    if ! grep -q "consoleblank=0" /boot/firmware/cmdline.txt; then
        sed -i 's/$/ consoleblank=0/' /boot/firmware/cmdline.txt
        log "Console blanking disabled in /boot/firmware/cmdline.txt"
    fi
fi

if [ -f /boot/firmware/config.txt ]; then
    if ! grep -q "hdmi_blanking=0" /boot/firmware/config.txt; then
        echo "" >> /boot/firmware/config.txt
        echo "# Live Feed: Disable HDMI blanking" >> /boot/firmware/config.txt
        echo "hdmi_blanking=0" >> /boot/firmware/config.txt
    fi
    if ! grep -q "hdmi_force_hotplug=1" /boot/firmware/config.txt; then
        echo "hdmi_force_hotplug=1" >> /boot/firmware/config.txt
    fi
    if ! grep -q "gpu_mem=" /boot/firmware/config.txt; then
        echo "" >> /boot/firmware/config.txt
        echo "# Live Feed: GPU memory for video" >> /boot/firmware/config.txt
        echo "gpu_mem=256" >> /boot/firmware/config.txt
    fi
    log "Boot firmware config updated."
fi

# ─── Step 6: Start the service now ──────────────────────────────────────────
info "Step 6/6: Starting live feed..."
systemctl start "${SERVICE_NAME}.service" || warn "Could not start now (no display/device?). Will start on next boot."

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Check status:${NC}  sudo systemctl status livefeed"
echo -e "  ${CYAN}View logs:${NC}     sudo journalctl -u livefeed -f"
echo -e "  ${CYAN}Stop feed:${NC}     sudo systemctl stop livefeed"
echo -e "  ${CYAN}Restart feed:${NC}  sudo systemctl restart livefeed"
echo ""
echo -e "  ${YELLOW}Reboot recommended for all changes to take effect.${NC}"
echo ""
