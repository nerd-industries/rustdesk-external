#!/bin/bash
# RustDesk macOS Uninstaller
# Usage: curl -fsSL https://rustdesk-macos-uninstall.nerdyneighbor.net | bash
# For shop installs: curl -fsSL https://rustdesk-macos-uninstall.nerdyneighbor.net | sudo bash

set -e

# Configuration
API_SERVER="https://rustdesk-api.nerdyneighbor.net"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
BOLD=$'\033[1m'

info() { printf "%s[INFO]%s %s\n" "$BLUE" "$NC" "$1"; }
success() { printf "%s[OK]%s %s\n" "$GREEN" "$NC" "$1"; }
warn() { printf "%s[WARN]%s %s\n" "$YELLOW" "$NC" "$1"; }
error() { printf "%s[ERROR]%s %s\n" "$RED" "$NC" "$1"; exit 1; }

header() {
    echo ""
    printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$CYAN" "$NC"
    printf "%s  %s%s\n" "$BOLD" "$1" "$NC"
    printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$CYAN" "$NC"
    echo ""
}

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    error "This script is for macOS only"
fi

# Get the user home directory (handle sudo case)
if [[ -n "$SUDO_USER" ]]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
else
    USER_HOME="$HOME"
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
        warn "Could not remove from dashboard"
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

config_paths=(
    "$USER_HOME/Library/Preferences/com.carriez.RustDesk"
    "$USER_HOME/Library/Preferences/com.carriez/RustDesk"
    "$USER_HOME/Library/Preferences/com.carriez"
    "$USER_HOME/Library/Application Support/com.carriez.RustDesk"
    "$USER_HOME/Library/Application Support/RustDesk"
    "$USER_HOME/Library/Caches/RustDesk"
    "$USER_HOME/Library/Logs/RustDesk"
)

for path in "${config_paths[@]}"; do
    if [[ -e "$path" ]]; then
        rm -rf "$path"
        info "Removed: $path"
    fi
done

success "Configuration files removed"

# Done
header "Uninstall Complete!"

echo "  RustDesk has been completely removed from your Mac."
echo ""
printf "  %sNote:%s The privacy permissions (Accessibility, Screen Recording,\n" "$YELLOW" "$NC"
echo "  Input Monitoring) will remain in System Settings but are now inactive."
echo "  You can manually remove them if desired."
echo ""
