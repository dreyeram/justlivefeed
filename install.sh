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

# ─── Step 0: Stop ALL previous applications ─────────────────────────────────
info "Step 0/7: Stopping all previous applications..."

# Stop and disable any old endoscopy-suite systemd services
for svc in endoscopy endoscopy-suite camera-server camera_server endo-camera endo-feed nextjs next; do
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        warn "Stopping old service: ${svc}"
        systemctl stop "${svc}.service" 2>/dev/null || true
    fi
    if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
        warn "Disabling old service: ${svc}"
        systemctl disable "${svc}.service" 2>/dev/null || true
    fi
done

# Stop PM2 if it's running (common for Node.js apps on Pi)
if command -v pm2 &>/dev/null; then
    warn "Stopping PM2 processes..."
    pm2 kill 2>/dev/null || true
    # Remove PM2 startup hook so it doesn't restart on boot
    pm2 unstartup systemd 2>/dev/null || true
    # Also try for the 'lm' user
    su - lm -c "pm2 kill" 2>/dev/null || true
    su - lm -c "pm2 unstartup systemd" 2>/dev/null || true
fi

# Kill any running Node.js / Next.js processes
warn "Killing any Node.js / camera server processes..."
pkill -f "node" 2>/dev/null || true
pkill -f "next" 2>/dev/null || true
pkill -f "npm" 2>/dev/null || true

# Kill any Python camera servers
pkill -f "camera_server" 2>/dev/null || true
pkill -f "camera-server" 2>/dev/null || true
pkill -f "python.*camera" 2>/dev/null || true
pkill -f "uvicorn" 2>/dev/null || true
pkill -f "flask" 2>/dev/null || true

# Kill any old GStreamer pipelines
pkill -f "gst-launch" 2>/dev/null || true

# Disable old cron jobs or rc.local entries that might start old apps
if [ -f /etc/rc.local ]; then
    if grep -q "endoscopy\|camera\|next\|node\|pm2" /etc/rc.local 2>/dev/null; then
        warn "Commenting out old entries in /etc/rc.local..."
        sed -i '/endoscopy\|camera_server\|camera-server\|next\|pm2/s/^/#DISABLED_BY_LIVEFEED# /' /etc/rc.local
    fi
fi

# Remove any old crontab entries for the lm user
crontab -u lm -l 2>/dev/null | grep -v "endoscopy\|camera\|next\|node\|pm2" | crontab -u lm - 2>/dev/null || true

# Disable old autostart desktop entries
for f in /home/lm/.config/autostart/*.desktop /etc/xdg/autostart/*endoscop*.desktop; do
    if [ -f "$f" ]; then
        warn "Disabling autostart: $f"
        mv "$f" "${f}.disabled" 2>/dev/null || true
    fi
done

# Remove PM2 startup service if it exists
rm -f /etc/systemd/system/pm2-*.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

log "All previous applications stopped and disabled."

# ─── Step 1: Install dependencies ───────────────────────────────────────────
info "Step 1/7: Installing GStreamer and dependencies..."
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
info "Step 2/7: Setting up ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
cp "${SCRIPT_DIR}/livefeed.sh" "${INSTALL_DIR}/livefeed.sh"
chmod +x "${INSTALL_DIR}/livefeed.sh"
log "Script installed to ${INSTALL_DIR}/livefeed.sh"

# ─── Step 3: Install systemd service ────────────────────────────────────────
info "Step 3/7: Installing systemd service..."
cp "${SCRIPT_DIR}/livefeed.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
log "Service installed."

# ─── Step 4: Enable service for auto-start ───────────────────────────────────
info "Step 4/7: Enabling auto-start on boot..."
systemctl enable "${SERVICE_NAME}.service"
log "Service enabled. Live feed will start automatically on boot."

# ─── Step 5: Disable screen blanking ────────────────────────────────────────
info "Step 5/7: Disabling screen blanking..."

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
info "Step 6/7: Starting live feed..."
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
