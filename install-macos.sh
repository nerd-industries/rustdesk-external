#!/bin/bash
# RustDesk macOS Installer
# Usage: curl -fsSL https://rustdesk-macos.nerdyneighbor.net | bash

set -e

# Configuration
RELAY_SERVER="rustdesk-relay.nerdyneighbor.net"
API_SERVER="https://rustdesk-api.nerdyneighbor.net"
PUBLIC_KEY="D11ZYHgpIWTNhltCBMe0f2MQzk+RQp4sI01KbqZj0l4="

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

if [[ "$(uname)" != "Darwin" ]]; then
    error "This script is for macOS only"
fi

header "RustDesk Installer for macOS"

# Get architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    ARCH_TYPE="aarch64"
    info "Detected Apple Silicon (arm64)"
else
    ARCH_TYPE="x86_64"
    info "Detected Intel (x86_64)"
fi

# Fetch latest version
info "Fetching latest RustDesk version..."
LATEST_VERSION=$(curl -fsSL "https://api.github.com/repos/rustdesk/rustdesk/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
VERSION_NUM="${LATEST_VERSION#v}"
info "Latest version: $LATEST_VERSION"

# Download URL
DMG_NAME="rustdesk-${VERSION_NUM}-${ARCH_TYPE}.dmg"
DOWNLOAD_URL="https://github.com/rustdesk/rustdesk/releases/download/${LATEST_VERSION}/${DMG_NAME}"

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Download RustDesk
info "Downloading RustDesk..."
curl -fSL "$DOWNLOAD_URL" -o "$TEMP_DIR/$DMG_NAME" --progress-bar
success "Download complete"

# Check if RustDesk is running and close it
if pgrep -x "RustDesk" > /dev/null; then
    warn "RustDesk is running. Closing it..."
    osascript -e 'quit app "RustDesk"' 2>/dev/null || true
    pkill -f RustDesk 2>/dev/null || true
    sleep 2
fi

# Mount DMG
info "Mounting disk image..."
MOUNT_OUTPUT=$(hdiutil attach "$TEMP_DIR/$DMG_NAME" -nobrowse 2>&1)
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep -o '/Volumes/[^"]*' | head -1)

if [[ -z "$MOUNT_POINT" ]] || [[ ! -d "$MOUNT_POINT" ]]; then
    MOUNT_POINT=$(find /Volumes -maxdepth 1 -name "*RustDesk*" -o -name "*rustdesk*" 2>/dev/null | head -1)
fi

if [[ -z "$MOUNT_POINT" ]] || [[ ! -d "$MOUNT_POINT" ]]; then
    error "Failed to mount DMG"
fi

success "Mounted at $MOUNT_POINT"

# Find the app
APP_PATH=$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" | head -1)
if [[ -z "$APP_PATH" ]]; then
    error "Could not find .app in mounted volume"
fi

# Copy to Applications
info "Installing to /Applications..."
if [[ -d "/Applications/RustDesk.app" ]]; then
    warn "Removing existing installation..."
    rm -rf "/Applications/RustDesk.app"
fi
cp -R "$APP_PATH" /Applications/
success "Installed to /Applications/RustDesk.app"

# Unmount DMG
info "Unmounting disk image..."
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true
success "Unmounted"

# Remove quarantine attribute
info "Removing quarantine attribute..."
xattr -rd com.apple.quarantine /Applications/RustDesk.app 2>/dev/null || true
success "Quarantine removed"

# Set custom icon
info "Setting custom icon..."
ICON_URL="https://nerdyneighbor.net/icon.png"
ICON_TMP="$TEMP_DIR/icon.png"
ICONSET_DIR="$TEMP_DIR/AppIcon.iconset"

if curl -fsSL "$ICON_URL" -o "$ICON_TMP" 2>/dev/null; then
    mkdir -p "$ICONSET_DIR"
    sips -z 16 16     "$ICON_TMP" --out "$ICONSET_DIR/icon_16x16.png"      > /dev/null 2>&1
    sips -z 32 32     "$ICON_TMP" --out "$ICONSET_DIR/icon_16x16@2x.png"   > /dev/null 2>&1
    sips -z 32 32     "$ICON_TMP" --out "$ICONSET_DIR/icon_32x32.png"      > /dev/null 2>&1
    sips -z 64 64     "$ICON_TMP" --out "$ICONSET_DIR/icon_32x32@2x.png"   > /dev/null 2>&1
    sips -z 128 128   "$ICON_TMP" --out "$ICONSET_DIR/icon_128x128.png"    > /dev/null 2>&1
    sips -z 256 256   "$ICON_TMP" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null 2>&1
    sips -z 256 256   "$ICON_TMP" --out "$ICONSET_DIR/icon_256x256.png"    > /dev/null 2>&1
    sips -z 512 512   "$ICON_TMP" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null 2>&1
    sips -z 512 512   "$ICON_TMP" --out "$ICONSET_DIR/icon_512x512.png"    > /dev/null 2>&1
    sips -z 1024 1024 "$ICON_TMP" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null 2>&1

    if iconutil -c icns "$ICONSET_DIR" -o "$TEMP_DIR/AppIcon.icns" 2>/dev/null; then
        cp "$TEMP_DIR/AppIcon.icns" "/Applications/RustDesk.app/Contents/Resources/AppIcon.icns"
        touch /Applications/RustDesk.app
        success "Custom icon applied"
    else
        warn "Could not convert icon to icns, using default"
    fi
else
    warn "Could not download custom icon, using default"
fi

# Configure RustDesk
header "Configuring RustDesk"

# First launch RustDesk to let it create its config directory
info "Launching RustDesk for initial setup..."
open /Applications/RustDesk.app
sleep 5

# Close it so we can modify config
info "Closing RustDesk to apply configuration..."
osascript -e 'quit app "RustDesk"' 2>/dev/null || pkill -x RustDesk 2>/dev/null || true
sleep 2

CONFIG_DIR="$HOME/Library/Preferences/com.carriez.RustDesk"
mkdir -p "$CONFIG_DIR"

info "Writing server configuration..."
cat > "$CONFIG_DIR/RustDesk2.toml" << EOF
rendezvous_server = '${RELAY_SERVER}'
nat_type = 1
serial = 0

[options]
direct-server = 'Y'
relay-server = '${RELAY_SERVER}'
key = '${PUBLIC_KEY}'
custom-rendezvous-server = '${RELAY_SERVER}'
api-server = '${API_SERVER}'
EOF

success "Configuration written"

# Start RustDesk
header "Starting RustDesk"

info "Launching RustDesk..."
open /Applications/RustDesk.app
sleep 3

# Get RustDesk ID
info "Retrieving RustDesk ID..."
DEVICE_ID=""

ATTEMPTS=0
while [[ -z "$DEVICE_ID" ]] && [[ $ATTEMPTS -lt 10 ]]; do
    ATTEMPTS=$((ATTEMPTS + 1))
    DEVICE_ID=$(/Applications/RustDesk.app/Contents/MacOS/RustDesk --get-id 2>/dev/null | grep -oE '[0-9]{7,}' | head -1)
    if [[ -z "$DEVICE_ID" ]]; then
        warn "Waiting for ID (attempt $ATTEMPTS/10)..."
        sleep 3
    fi
done

if [[ -z "$DEVICE_ID" ]]; then
    error "Failed to retrieve RustDesk ID"
fi

# Display results
header "Installation Complete!"

printf "  Device ID: %s%s%s\n" "$YELLOW" "$DEVICE_ID" "$NC"
echo ""
printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$GREEN" "$NC"
printf "%s  Share this ID with your technician!%s\n" "$BOLD" "$NC"
printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$GREEN" "$NC"
echo ""
echo "  RustDesk will prompt for permissions on first connection."
echo "  Please grant Accessibility and Screen Recording access when asked."
echo ""
