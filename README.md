# Nerdy Neighbor Support - RustDesk Installation Scripts

Quick installation scripts for Nerdy Neighbor remote support.

## Windows Installation

### Customer Computer

Run in PowerShell as Administrator:

```powershell
irm https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/install-customer.ps1 | iex
```

### Shop Computer (Permanent Password)

Run in PowerShell as Administrator:

```powershell
irm https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/install-shop.ps1 | iex
```

## macOS Installation

### Customer Computer

Run in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/install-macos.sh | bash
```

### Shop Computer (Permanent Password)

Run in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/install-macos-shop.sh | bash
```

## Uninstallation

### Windows

Run in PowerShell as Administrator:

```powershell
irm https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/uninstall.ps1 | iex
```

### macOS

Run in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/uninstall-macos.sh | bash
```

## What Gets Installed

- RustDesk remote desktop client (latest version)
- Pre-configured connection to Nerdy Neighbor support servers
- Desktop shortcut: "Nerdy Neighbor Support - RustDesk"

## Support

Contact Nerdy Neighbor for assistance.
