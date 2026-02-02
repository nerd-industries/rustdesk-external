# Nerdy Neighbor Support - RustDesk Installation Scripts

Quick installation scripts for Nerdy Neighbor remote support.

## Windows

### Install (Customer)

```powershell
irm https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/install-windows.ps1 | iex
```

### Install (Shop)

```powershell
irm https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/install-windows-shop.ps1 | iex
```

### Uninstall

```powershell
irm https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/uninstall-windows.ps1 | iex
```

## macOS

### Install (Customer)

```bash
curl -fsSL https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/install-macos.sh | bash
```

### Install (Shop)

```bash
curl -fsSL https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/install-macos-shop.sh | bash
```

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/uninstall-macos.sh | bash
```

## What Gets Installed

- RustDesk remote desktop client (latest version)
- Pre-configured connection to Nerdy Neighbor support servers
- Desktop shortcut: "Nerdy Neighbor Support - RustDesk"
