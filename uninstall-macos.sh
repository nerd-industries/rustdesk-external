#!/bin/bash
# RustDesk macOS Uninstaller
# Usage: curl -fsSL https://your-url/uninstall-macos.sh | bash

set -e

# Configuration
API_SERVER="https://rustdesk-api.nerdyneighbor.net"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    error "This script is for macOS only"
fi

header "RustDesk Uninstaller for macOS"

# Get RustDesk ID before uninstalling
info "Looking for RustDesk installation..."
DEVICE_ID=""

if [[ -d "/Applications/RustDesk.app" ]]; then
    DEVICE_ID=$(/Applications/RustDesk.app/Contents/MacOS/RustDesk --get-id 2>/dev/null | grep -oE '[0-9]{9,}' | head -1)
fi

if [[ -n "$DEVICE_ID" ]]; then
    info "Found device ID: $DEVICE_ID"
else
    warn "No device ID found"
fi

# Stop RustDesk
info "Stopping RustDesk..."
osascript -e 'quit app "RustDesk"' 2>/dev/null || true
pkill -f "RustDesk" 2>/dev/null || true
sleep 2
success "RustDesk stopped"

# Unregister from API
if [[ -n "$DEVICE_ID" ]]; then
    info "Removing device from dashboard..."

    response=$(curl -s -X POST "$API_SERVER/api/device/unregister" \
        -H "Content-Type: application/json" \
        -d "{\"device_id\": \"$DEVICE_ID\"}" 2>/dev/null || echo "")

    if echo "$response" | grep -q "success"; then
        success "Device removed from dashboard"
    else
        warn "Could not remove from dashboard: $response"
    fi
else
    warn "No device ID found, skipping API unregistration"
fi

# Remove application
if [[ -d "/Applications/RustDesk.app" ]]; then
    info "Removing /Applications/RustDesk.app..."
    rm -rf "/Applications/RustDesk.app"
    success "Application removed"
else
    warn "RustDesk.app not found in /Applications"
fi

# Remove config files
info "Removing configuration files..."

config_dirs=(
    "$HOME/Library/Preferences/com.carriez.RustDesk"
    "$HOME/Library/Application Support/com.carriez.RustDesk"
    "$HOME/Library/Application Support/RustDesk"
    "$HOME/Library/Caches/RustDesk"
    "$HOME/Library/Logs/RustDesk"
)

for dir in "${config_dirs[@]}"; do
    if [[ -e "$dir" ]]; then
        rm -rf "$dir"
        info "Removed: $dir"
    fi
done

success "Configuration files removed"

# Done
header "Uninstall Complete!"

echo -e "  RustDesk has been completely removed from your Mac."
echo ""
echo -e "  ${YELLOW}Note:${NC} The privacy permissions (Accessibility, Screen Recording,"
echo -e "  Input Monitoring) will remain in System Settings but are now inactive."
echo -e "  You can manually remove them if desired."
echo ""
