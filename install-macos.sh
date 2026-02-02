#!/bin/bash
# RustDesk macOS Installer
# Usage: curl -fsSL https://rustdesk.evanhouston.com/install-macos.sh | bash

set -e

# Configuration
RELAY_SERVER="rustdesk-relay.nerdyneighbor.net"
API_SERVER="https://rustdesk-api.nerdyneighbor.net"
PUBLIC_KEY="D11ZYHgpIWTNhltCBMe0f2MQzk+RQp4sI01KbqZj0l4="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Print functions
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

# Fetch latest RustDesk version
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
    sleep 2
fi

# Mount DMG
info "Mounting disk image..."
MOUNT_OUTPUT=$(hdiutil attach "$TEMP_DIR/$DMG_NAME" -nobrowse 2>&1)
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep -o '/Volumes/[^"]*' | head -1)

# If that didn't work, try finding it
if [[ -z "$MOUNT_POINT" ]] || [[ ! -d "$MOUNT_POINT" ]]; then
    # Look for any RustDesk volume
    MOUNT_POINT=$(find /Volumes -maxdepth 1 -name "*RustDesk*" -o -name "*rustdesk*" 2>/dev/null | head -1)
fi

if [[ -z "$MOUNT_POINT" ]] || [[ ! -d "$MOUNT_POINT" ]]; then
    error "Failed to mount DMG. Mount output: $MOUNT_OUTPUT"
fi

success "Mounted at $MOUNT_POINT"

# Find the app in the mount
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

# Configure RustDesk
header "Configuring RustDesk"

CONFIG_DIR="$HOME/Library/Preferences/com.carriez/RustDesk"
mkdir -p "$CONFIG_DIR"

# Write RustDesk config
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

success "Configuration written to $CONFIG_DIR/RustDesk2.toml"

# Launch RustDesk
header "Launching RustDesk"

info "Starting RustDesk..."
open -a RustDesk

success "RustDesk is now running!"

# Verify config
if grep -q "${RELAY_SERVER}" "$CONFIG_DIR/RustDesk2.toml" 2>/dev/null; then
    success "Server configuration verified"
else
    warn "Could not verify server config - please check Settings in RustDesk"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Installation Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Relay:  ${CYAN}${RELAY_SERVER}${NC}"
echo -e "  API:    ${CYAN}${API_SERVER}${NC}"
echo ""
echo -e "  RustDesk will prompt for permissions when you first connect."
echo ""
