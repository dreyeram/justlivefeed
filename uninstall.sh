#!/bin/bash
###############################################################################
# uninstall.sh - Remove Zero-Latency Endoscopy Live Feed
###############################################################################

set -euo pipefail

SERVICE_NAME="livefeed"
INSTALL_DIR="/opt/livefeed"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗]${NC} Run as root: sudo bash uninstall.sh"
    exit 1
fi

echo "Removing Zero-Latency Endoscopy Live Feed..."

# Stop and disable service
systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true

# Remove files
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
rm -rf "$INSTALL_DIR"

# Reload systemd
systemctl daemon-reload

echo -e "${GREEN}[✓]${NC} Uninstalled successfully."
echo "Note: GStreamer packages were not removed. Remove manually if needed:"
echo "  sudo apt-get remove gstreamer1.0-tools gstreamer1.0-plugins-*"
