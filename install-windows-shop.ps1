#Requires -RunAsAdministrator
<#
.SYNOPSIS
    RustDesk Shop Installation Script
    For technician machines - silent install with permanent password and auto-registration

.DESCRIPTION
    This script:
    - Downloads and installs the latest RustDesk
    - Configures it to connect to your self-hosted servers
    - Sets a permanent password for unattended access
    - Registers the device with your API server
    - Prompts for customer name and saves to API

.NOTES
    Run with: irm <your-url>/install-shop.ps1 | iex
#>

# =============================================================================
# CONFIGURATION - Edit these values for your deployment
# =============================================================================
$ApiServer = "https://rustdesk-api.nerdyneighbor.net"
$RelayServer = "rustdesk-relay.nerdyneighbor.net"
$PublicKey = "D11ZYHgpIWTNhltCBMe0f2MQzk+RQp4sI01KbqZj0l4="

# =============================================================================
# DO NOT EDIT BELOW THIS LINE
# =============================================================================

$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    $colors = @{
        "Info" = "Cyan"
        "Success" = "Green"
        "Warning" = "Yellow"
        "Error" = "Red"
    }
    Write-Host "[$Type] $Message" -ForegroundColor $colors[$Type]
}

function Get-RandomPassword {
    param([int]$Length = 16)
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%"
    $password = ""
    $random = New-Object System.Random
    for ($i = 0; $i -lt $Length; $i++) {
        $password += $chars[$random.Next($chars.Length)]
    }
    return $password
}

function Get-LatestRustDeskVersion {
    Write-Status "Fetching latest RustDesk version..."
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/rustdesk/rustdesk/releases/latest"
    return $releases.tag_name
}

function Get-RustDeskInstaller {
    param([string]$Version)

    # Remove 'v' prefix if present for filename
    $versionClean = $Version -replace '^v', ''

    $installerName = "rustdesk-$versionClean-x86_64.exe"
    $downloadUrl = "https://github.com/rustdesk/rustdesk/releases/download/$Version/$installerName"
    $tempPath = Join-Path $env:TEMP $installerName

    Write-Status "Downloading RustDesk $versionClean... (this may take a moment)"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempPath -UseBasicParsing
    $ProgressPreference = 'Continue'

    return $tempPath
}

function Stop-RustDesk {
    Write-Status "Stopping any running RustDesk processes..."
    Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Install-RustDesk {
    param([string]$InstallerPath)

    Write-Status "Installing RustDesk silently..."
    Start-Process -FilePath $InstallerPath -ArgumentList "--silent-install"

    # Wait for installation to complete (don't use -Wait as it can hang)
    $rustdeskPath = "C:\Program Files\RustDesk\rustdesk.exe"
    $maxWait = 120
    $waited = 0

    Write-Status "Waiting for installation to complete..."
    while (-not (Test-Path $rustdeskPath) -and $waited -lt $maxWait) {
        Start-Sleep -Seconds 3
        $waited += 3
    }

    if (-not (Test-Path $rustdeskPath)) {
        throw "RustDesk installation failed - executable not found after ${maxWait}s"
    }

    # Give it a few more seconds to finish writing files
    Start-Sleep -Seconds 5

    # Ensure RustDesk service is set to auto-start
    $service = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($service) {
        Set-Service -Name "RustDesk" -StartupType Automatic
        if ($service.Status -ne 'Running') {
            Start-Service -Name "RustDesk" -ErrorAction SilentlyContinue
        }
        Write-Status "RustDesk service configured for auto-start" "Success"
    }

    Write-Status "RustDesk installed successfully" "Success"
    return $rustdeskPath
}

function Set-RustDeskConfig {
    param([string]$RustDeskPath)

    Write-Status "Configuring RustDesk..."

    $configContent = @"
rendezvous_server = '$RelayServer'
nat_type = 1
serial = 0

[options]
direct-server = 'Y'
relay-server = '$RelayServer'
key = '$PublicKey'
custom-rendezvous-server = '$RelayServer'
api-server = '$ApiServer'
"@

    # Write config to user profile
    $userConfigDir = Join-Path $env:APPDATA "RustDesk\config"
    if (-not (Test-Path $userConfigDir)) {
        New-Item -ItemType Directory -Path $userConfigDir -Force | Out-Null
    }
    $configContent | Out-File -FilePath (Join-Path $userConfigDir "RustDesk2.toml") -Encoding UTF8

    # Write config to service profile (for unattended access)
    $serviceConfigDir = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
    if (-not (Test-Path $serviceConfigDir)) {
        New-Item -ItemType Directory -Path $serviceConfigDir -Force | Out-Null
    }
    $configContent | Out-File -FilePath (Join-Path $serviceConfigDir "RustDesk2.toml") -Encoding UTF8

    Write-Status "Configuration applied" "Success"
}

function Set-RustDeskPassword {
    param([string]$RustDeskPath, [string]$Password)

    Write-Status "Setting permanent password..."
    & $RustDeskPath --permanent-password $Password
    Start-Sleep -Seconds 2
}

function Get-RustDeskId {
    param([string]$RustDeskPath)

    Write-Status "Retrieving RustDesk ID..."

    # Start RustDesk to generate ID
    Start-Process -FilePath $RustDeskPath -WindowStyle Hidden
    Start-Sleep -Seconds 5

    $maxAttempts = 10
    $attempt = 0
    $id = $null

    while ($attempt -lt $maxAttempts -and -not $id) {
        $attempt++

        # Try --get-id command
        $output = & $RustDeskPath --get-id 2>&1 | Out-String

        # Extract any 9+ digit number from output
        if ($output -match '(\d{9,})') {
            $id = $matches[1]
        }

        # Also try reading from config file
        if (-not $id) {
            $configPath = Join-Path $env:APPDATA "RustDesk\config\RustDesk.toml"
            if (Test-Path $configPath) {
                $config = Get-Content $configPath -Raw
                if ($config -match 'id\s*=\s*[''"]?(\d{9,})[''"]?') {
                    $id = $matches[1]
                }
            }
        }

        if (-not $id) {
            Write-Status "Waiting for ID (attempt $attempt/$maxAttempts)..." "Warning"
            Start-Sleep -Seconds 3
        }
    }

    # Stop RustDesk GUI if running
    Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    if (-not $id) {
        throw "Failed to retrieve RustDesk ID"
    }

    return $id
}

function Register-Device {
    param(
        [string]$DeviceId,
        [string]$Password,
        [string]$CustomerName
    )

    Write-Status "Registering device with API server..."

    $hostname = $env:COMPUTERNAME
    $body = @{
        device_id = $DeviceId
        password = $Password
        hostname = $hostname
        customer_name = $CustomerName
        install_type = "shop"
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri "$ApiServer/api/device/register" -Method Post -Body $body -ContentType "application/json"
        Write-Status "Device registered successfully" "Success"
    } catch {
        Write-Status "Warning: Could not register device with API server: $_" "Warning"
    }
}

function Rename-Shortcuts {
    Write-Status "Customizing shortcuts for Nerdy Neighbor Support..."

    $newName = "Nerdy Neighbor Support - RustDesk"
    $iconUrl = "https://nerdyneighbor.net/icon.ico"
    $iconPath = "C:\Program Files\RustDesk\nerdy-neighbor.ico"

    # Download custom icon
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $iconUrl -OutFile $iconPath -UseBasicParsing
        $ProgressPreference = 'Continue'
        Write-Status "Custom icon downloaded" "Success"
    } catch {
        Write-Status "Could not download custom icon, using default" "Warning"
        $iconPath = $null
    }

    $shell = New-Object -ComObject WScript.Shell

    # Desktop shortcuts (current user and public)
    $desktopPaths = @(
        [Environment]::GetFolderPath("Desktop"),
        [Environment]::GetFolderPath("CommonDesktopDirectory")
    )

    foreach ($desktop in $desktopPaths) {
        $oldShortcut = Join-Path $desktop "RustDesk.lnk"
        $newShortcut = Join-Path $desktop "$newName.lnk"
        if (Test-Path $oldShortcut) {
            # Update icon and rename
            $lnk = $shell.CreateShortcut($oldShortcut)
            if ($iconPath) { $lnk.IconLocation = "$iconPath,0" }
            $lnk.Save()
            Move-Item -Path $oldShortcut -Destination $newShortcut -Force -ErrorAction SilentlyContinue
        }
    }

    # Start Menu shortcuts
    $startMenuPaths = @(
        (Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"),
        (Join-Path ([Environment]::GetFolderPath("CommonStartMenu")) "Programs"),
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs")
    )

    foreach ($startMenu in $startMenuPaths) {
        # Check for RustDesk folder
        $rustdeskFolder = Join-Path $startMenu "RustDesk"
        if (Test-Path $rustdeskFolder) {
            $oldShortcut = Join-Path $rustdeskFolder "RustDesk.lnk"
            $newShortcut = Join-Path $rustdeskFolder "$newName.lnk"
            if (Test-Path $oldShortcut) {
                # Update icon and rename
                $lnk = $shell.CreateShortcut($oldShortcut)
                if ($iconPath) { $lnk.IconLocation = "$iconPath,0" }
                $lnk.Save()
                Move-Item -Path $oldShortcut -Destination $newShortcut -Force -ErrorAction SilentlyContinue
            }
            # Rename the folder too
            Rename-Item -Path $rustdeskFolder -NewName "Nerdy Neighbor Support" -Force -ErrorAction SilentlyContinue
        }

        # Check for direct shortcut
        $oldShortcut = Join-Path $startMenu "RustDesk.lnk"
        $newShortcut = Join-Path $startMenu "$newName.lnk"
        if (Test-Path $oldShortcut) {
            $lnk = $shell.CreateShortcut($oldShortcut)
            if ($iconPath) { $lnk.IconLocation = "$iconPath,0" }
            $lnk.Save()
            Move-Item -Path $oldShortcut -Destination $newShortcut -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Status "Shortcuts customized" "Success"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

try {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  RustDesk Shop Installation Script" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Check for admin rights
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator"
    }

    # Prompt for customer name first
    $customerName = Read-Host "Enter customer name"
    if ([string]::IsNullOrWhiteSpace($customerName)) {
        throw "Customer name is required"
    }
    Write-Host ""
    Write-Status "Installing RustDesk for: $customerName"
    Write-Host ""

    # Get latest version and download
    $version = Get-LatestRustDeskVersion
    Stop-RustDesk
    $installerPath = Get-RustDeskInstaller -Version $version

    # Install RustDesk
    $rustdeskPath = Install-RustDesk -InstallerPath $installerPath

    # Get device ID first (this starts RustDesk and lets it do first-run initialization)
    $deviceId = Get-RustDeskId -RustDeskPath $rustdeskPath

    # Now apply our config AFTER first-run (so it doesn't get overwritten)
    Set-RustDeskConfig -RustDeskPath $rustdeskPath

    # Rename shortcuts to branded name
    Rename-Shortcuts

    # Generate and set password
    $password = Get-RandomPassword -Length 16
    Set-RustDeskPassword -RustDeskPath $rustdeskPath -Password $password

    # Restart RustDesk service to apply config
    Stop-RustDesk
    Start-Sleep -Seconds 2

    # Display results
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Installation Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Customer:  $customerName" -ForegroundColor Cyan
    Write-Host "Device ID: $deviceId" -ForegroundColor Yellow
    Write-Host "Password:  $password" -ForegroundColor Yellow
    Write-Host ""

    # Register with API
    Register-Device -DeviceId $deviceId -Password $password -CustomerName $customerName

    Write-Host ""
    Write-Host "Setup complete! Device is ready for remote access." -ForegroundColor Green
    Write-Host ""

    # Launch RustDesk GUI
    Write-Status "Launching RustDesk..."
    Start-Process -FilePath $rustdeskPath

    # Cleanup
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

} catch {
    Write-Status "Error: $_" "Error"
    exit 1
}
