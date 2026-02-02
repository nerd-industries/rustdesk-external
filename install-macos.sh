#!/bin/bash
# RustDesk macOS Installer
# Usage: curl -fsSL https://rustdesk-macos.nerdyneighbor.net | bash

set -e

# Configuration
RELAY_SERVER="rustdesk-relay.nerdyneighbor.net"
API_SERVER="https://rustdesk-api.nerdyneighbor.net"
PUBLIC_KEY="D11ZYHgpIWTNhltCBMe0f2MQzk+RQp4sI01KbqZj0l4="

# Colors
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
BLUE='\\033[0;34m'
CYAN='\\033[0;36m'
NC='\\033[0m'
BOLD='\\033[1m'

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

DMG_NAME="rustdesk-${VERSION_NUM}-${ARCH_TYPE}.dmg"
DOWNLOAD_URL="https://github.com/rustdesk/rustdesk/releases/download/${LATEST_VERSION}/${DMG_NAME}"

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

info "Downloading RustDesk..."
curl -fSL "$DOWNLOAD_URL" -o "$TEMP_DIR/$DMG_NAME" --progress-bar
success "Download complete"

# Close RustDesk if running
if pgrep -x "RustDesk" > /dev/null; then
    warn "RustDesk is running. Closing it..."
    osascript -e 'quit app "RustDesk"' 2>/dev/null || true
    sleep 2
fi

# Mount DMG
info "Mounting disk image..."
hdiutil attach "$TEMP_DIR/$DMG_NAME" -nobrowse -quiet
MOUNT_POINT=$(find /Volumes -maxdepth 1 -name "*RustDesk*" -o -name "*rustdesk*" 2>/dev/null | head -1)

if [[ -z "$MOUNT_POINT" ]] || [[ ! -d "$MOUNT_POINT" ]]; then
    error "Failed to mount DMG"
fi
success "Mounted at $MOUNT_POINT"

APP_PATH=$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" | head -1)
if [[ -z "$APP_PATH" ]]; then
    error "Could not find .app in mounted volume"
fi

# Install
info "Installing to /Applications..."
rm -rf "/Applications/RustDesk.app" 2>/dev/null || true
cp -R "$APP_PATH" /Applications/
success "Installed"

# Unmount
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true

# Remove quarantine
xattr -rd com.apple.quarantine /Applications/RustDesk.app 2>/dev/null || true

header "Configuring RustDesk"

# Launch RustDesk first to let it initialize and create default config
info "Launching RustDesk for initial setup..."
open /Applications/RustDesk.app
sleep 5

# Close it so we can modify config
info "Closing RustDesk to apply configuration..."
osascript -e 'quit app "RustDesk"' 2>/dev/null || pkill -x RustDesk 2>/dev/null || true
sleep 2

# Now write our config (after RustDesk created its defaults)
CONFIG_DIR="$HOME/Library/Preferences/com.carriez.RustDesk"
mkdir -p "$CONFIG_DIR"

info "Writing server configuration..."
cat > "$CONFIG_DIR/RustDesk2.toml" << EOF
rendezvous_server = '${RELAY_SERVER}'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '${RELAY_SERVER}'
relay-server = '${RELAY_SERVER}'
key = '${PUBLIC_KEY}'
api-server = '${API_SERVER}'
direct-server = 'Y'
EOF

success "Configuration written"

# Relaunch RustDesk
header "Launching RustDesk"
info "Starting RustDesk with new configuration..."
open /Applications/RustDesk.app
sleep 2

success "RustDesk is now running!"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Installation Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Server: ${CYAN}${RELAY_SERVER}${NC}"
echo ""
echo -e "  RustDesk will prompt for permissions when you first connect."
echo ""
