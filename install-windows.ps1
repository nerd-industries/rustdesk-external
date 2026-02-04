#Requires -RunAsAdministrator
<#
.SYNOPSIS
    RustDesk Customer Installation Script
    For customer machines - installs and opens RustDesk so customer can share their ID

.DESCRIPTION
    This script:
    - Downloads and installs the latest RustDesk
    - Configures it to connect to your self-hosted servers
    - Opens RustDesk GUI so customer can read their ID and one-time password
    - Does NOT set a permanent password (uses one-time passwords only)

.NOTES
    Run with: irm https://rustdesk-windows.nerdyneighbor.net | iex
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

function Get-LatestRustDeskVersion {
    Write-Status "Fetching latest RustDesk version..."
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/rustdesk/rustdesk/releases/latest"
    return $releases.tag_name
}

function Get-RustDeskInstaller {
    param([string]$Version)

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

    Start-Sleep -Seconds 5
    Write-Status "RustDesk installed successfully" "Success"
    return $rustdeskPath
}

function Set-RustDeskConfig {
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

    # Write config to service profile (required for UAC prompt visibility)
    $serviceConfigDir = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
    if (-not (Test-Path $serviceConfigDir)) {
        New-Item -ItemType Directory -Path $serviceConfigDir -Force | Out-Null
    }
    $configContent | Out-File -FilePath (Join-Path $serviceConfigDir "RustDesk2.toml") -Encoding UTF8

    Write-Status "Configuration applied" "Success"
}

function Get-RustDeskId {
    param([string]$RustDeskPath)

    Write-Status "Retrieving RustDesk ID..."

    $maxAttempts = 10
    $attempt = 0
    $id = $null

    while ($attempt -lt $maxAttempts -and -not $id) {
        $attempt++

        try {
            $output = & $RustDeskPath --get-id 2>&1 | Out-String
            $output = $output.Trim()

            if ($output -match '(\d{7,})') {
                $id = $matches[1]
                Write-Status "Got ID: $id" "Success"
            }
        } catch {
            # Command failed, will retry
        }

        if (-not $id) {
            Write-Status "Waiting for ID (attempt $attempt/$maxAttempts)..." "Warning"
            Start-Sleep -Seconds 3
        }
    }

    if (-not $id) {
        throw "Failed to retrieve RustDesk ID after $maxAttempts attempts"
    }

    return $id
}

function Set-RunAsAdmin {
    param([string]$ExePath)

    Write-Status "Setting RustDesk to always run as administrator..."

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"

    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }

    Set-ItemProperty -Path $regPath -Name $ExePath -Value "~ RUNASADMIN" -Type String
    Write-Status "Run as administrator compatibility setting applied" "Success"
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
        $rustdeskFolder = Join-Path $startMenu "RustDesk"
        if (Test-Path $rustdeskFolder) {
            $oldShortcut = Join-Path $rustdeskFolder "RustDesk.lnk"
            $newShortcut = Join-Path $rustdeskFolder "$newName.lnk"
            if (Test-Path $oldShortcut) {
                $lnk = $shell.CreateShortcut($oldShortcut)
                if ($iconPath) { $lnk.IconLocation = "$iconPath,0" }
                $lnk.Save()
                Move-Item -Path $oldShortcut -Destination $newShortcut -Force -ErrorAction SilentlyContinue
            }
            Rename-Item -Path $rustdeskFolder -NewName "Nerdy Neighbor Support" -Force -ErrorAction SilentlyContinue
        }

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

function Configure-Service {
    Write-Status "Configuring RustDesk service..."

    $service = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($service) {
        # Set to Manual - won't auto-start on boot, but we start it now for the session
        # This allows UAC interaction while not having it always running
        Set-Service -Name "RustDesk" -StartupType Manual

        # Start the service for this session (needed for UAC/secure desktop access)
        if ($service.Status -ne 'Running') {
            Start-Service -Name "RustDesk" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        Write-Status "RustDesk service configured (manual start, running now)" "Success"
    } else {
        Write-Status "RustDesk service not found" "Warning"
    }

    # Disable RustDesk from startup apps (prevents GUI from auto-launching)
    $startupPaths = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    )
    foreach ($regPath in $startupPaths) {
        if (Test-Path $regPath) {
            Remove-ItemProperty -Path $regPath -Name "RustDesk" -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $regPath -Name "RustDesk Tray" -ErrorAction SilentlyContinue
        }
    }
    Write-Status "Disabled RustDesk auto-start on login" "Success"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

try {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  RustDesk Remote Support Setup" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Check for admin rights
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator. Right-click PowerShell and select 'Run as Administrator'"
    }

    # Get latest version and download
    $version = Get-LatestRustDeskVersion
    Stop-RustDesk
    $installerPath = Get-RustDeskInstaller -Version $version

    # Install RustDesk
    $rustdeskPath = Install-RustDesk -InstallerPath $installerPath

    # Let RustDesk do first-run initialization (generates ID)
    Write-Status "Initializing RustDesk (generating ID)..."
    Start-Process -FilePath $rustdeskPath
    Start-Sleep -Seconds 5

    # Get device ID WHILE RustDesk is running (critical for ID persistence)
    $deviceId = Get-RustDeskId -RustDeskPath $rustdeskPath

    # Now stop RustDesk to apply our config
    Stop-RustDesk

    # Apply our config AFTER first-run and ID generation
    Set-RustDeskConfig

    # Configure service (manual start but running for this session)
    Configure-Service

    # Rename shortcuts to branded name
    Rename-Shortcuts

    # Set RustDesk to always run as administrator
    Set-RunAsAdmin -ExePath $rustdeskPath

    # Refresh desktop to show new icons
    Write-Status "Refreshing desktop icons..."
    & ie4uinit.exe -show
    Start-Sleep -Seconds 1

    # Open RustDesk GUI
    Write-Status "Launching RustDesk..."
    Start-Process -FilePath $rustdeskPath

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Setup Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Your Device ID: $deviceId" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "RustDesk is now open." -ForegroundColor Cyan
    Write-Host "Please read your ID and one-time password" -ForegroundColor Cyan
    Write-Host "to the support technician." -ForegroundColor Cyan
    Write-Host ""

    # Cleanup
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

} catch {
    Write-Status "Error: $_" "Error"
    Write-Host ""
    Write-Host "Please contact support for assistance." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}
