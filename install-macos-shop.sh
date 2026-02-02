#!/bin/bash
# RustDesk macOS Shop Installation Script
# For technician machines - sets permanent password and registers with API
# Usage: curl -fsSL https://your-url/install-macos-shop.sh | sudo bash

set -e

# Check for root - needed to set password
if [[ $EUID -ne 0 ]]; then
    echo "This script requires sudo to set the permanent password."
    echo "Please run: curl ... | sudo bash"
    exit 1
fi

# Get the actual user's home directory (not root's)
if [[ -n "$SUDO_USER" ]]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
else
    USER_HOME="$HOME"
fi

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

# Generate random password
generate_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9!@#$%' </dev/urandom | head -c 16
}

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    error "This script is for macOS only"
fi

header "RustDesk Shop Installer for macOS"

# Prompt for customer name first
echo -n "Enter customer name: "
read CUSTOMER_NAME < /dev/tty

if [[ -z "$CUSTOMER_NAME" ]]; then
    error "Customer name is required"
fi

echo ""
info "Installing RustDesk for: $CUSTOMER_NAME"
echo ""

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

# Configure RustDesk

# First launch RustDesk to let it initialize
info "Launching RustDesk for initial setup..."
open -a RustDesk
sleep 5

# Close it so we can modify config
info "Closing RustDesk to apply configuration..."
osascript -e 'quit app "RustDesk"' 2>/dev/null || pkill -x RustDesk 2>/dev/null || true
sleep 2

header "Configuring RustDesk"

CONFIG_DIR="$USER_HOME/Library/Preferences/com.carriez/RustDesk"
mkdir -p "$CONFIG_DIR"

# Generate password
PASSWORD=$(generate_password)

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

success "Configuration written"

# Fix ownership so RustDesk can read the config
chown -R $SUDO_USER:$(id -gn $SUDO_USER) "$USER_HOME/Library/Preferences/com.carriez"

# Start RustDesk
header "Starting RustDesk"

info "Launching RustDesk..."
open -a RustDesk
sleep 3

# Set password using command line (already running as root)
info "Setting permanent password..."
/Applications/RustDesk.app/Contents/MacOS/RustDesk --password "$PASSWORD" 2>/dev/null || warn "Could not set password via CLI - set it manually in RustDesk"
sleep 2

# Get RustDesk ID
info "Retrieving RustDesk ID..."
DEVICE_ID=""

# Wait and retry to get ID
ATTEMPTS=0
while [[ -z "$DEVICE_ID" ]] && [[ $ATTEMPTS -lt 10 ]]; do
    ATTEMPTS=$((ATTEMPTS + 1))
    DEVICE_ID=$(/Applications/RustDesk.app/Contents/MacOS/RustDesk --get-id 2>/dev/null | grep -oE '[0-9]{9,}' | head -1)
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

echo -e "  Device ID: ${YELLOW}${DEVICE_ID}${NC}"
echo -e "  Password:  ${YELLOW}${PASSWORD}${NC}"
echo ""

# Register with API
info "Registering device with API server..."

HOSTNAME=$(hostname)

RESPONSE=$(curl -s -X POST "$API_SERVER/api/device/register" \
    -H "Content-Type: application/json" \
    -d "{\"device_id\": \"$DEVICE_ID\", \"password\": \"$PASSWORD\", \"hostname\": \"$HOSTNAME\", \"customer_name\": \"$CUSTOMER_NAME\", \"install_type\": \"shop\"}" 2>/dev/null || echo "")

if [[ -n "$RESPONSE" ]]; then
    success "Device registered successfully"
else
    warn "Could not register device with API server"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Setup Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Device is ready for remote access."
echo -e "  RustDesk will prompt for permissions on first connection."
echo ""
