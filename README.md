# Nerdy Neighbor Support - RustDesk Installation Scripts

Quick installation scripts for Nerdy Neighbor remote support.

## Windows

### Install (Customer)

```powershell
irm https://rustdesk.nerdyneighbor.net | iex
```

### Install (Shop)

```powershell
irm https://rustdesk-shop.nerdyneighbor.net | iex
```

### Uninstall

```powershell
irm https://rustdesk-uninstall.nerdyneighbor.net | iex
```

## macOS

### Install (Customer)

```bash
curl -fsSL https://rustdesk-macos.nerdyneighbor.net | bash
```

### Install (Shop)

```bash
curl -fsSL https://rustdesk-macos-shop.nerdyneighbor.net | sudo bash
```

### Uninstall (Customer)

```bash
curl -fsSL https://rustdesk-macos-uninstall.nerdyneighbor.net | bash
```

### Uninstall (Shop)

```bash
curl -fsSL https://rustdesk-macos-uninstall.nerdyneighbor.net | sudo bash
```

## What Gets Installed

- RustDesk remote desktop client (latest version)
- Pre-configured connection to Nerdy Neighbor support servers
- Desktop shortcut: "Nerdy Neighbor Support - RustDesk"
