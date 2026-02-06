#Requires -RunAsAdministrator
<#
.SYNOPSIS
    RustDesk Uninstall Script
    Removes RustDesk and unregisters from the API dashboard

.NOTES
    Run with: irm https://rustdesk-windows-uninstall.nerdyneighbor.net | iex
#>

# =============================================================================
# CONFIGURATION
# =============================================================================
$ApiServer = "https://rustdesk-api.nerdyneighbor.net"

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

function Get-RustDeskId {
    $id = $null

    # Try reading from config file
    $configPaths = @(
        (Join-Path $env:APPDATA "RustDesk\config\RustDesk.toml"),
        (Join-Path $env:APPDATA "RustDesk\config\RustDesk2.toml"),
        "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml"
    )

    foreach ($configPath in $configPaths) {
        if (Test-Path $configPath) {
            $config = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
            if ($config -match 'id\s*=\s*[''"]?(\d{7,})[''"]?') {
                $id = $matches[1]
                break
            }
        }
    }

    # Try --get-id command if RustDesk is installed
    if (-not $id) {
        $rustdeskPath = "C:\Program Files\RustDesk\rustdesk.exe"
        if (Test-Path $rustdeskPath) {
            $output = & $rustdeskPath --get-id 2>&1 | Out-String
            if ($output -match '(\d{7,})') {
                $id = $matches[1]
            }
        }
    }

    return $id
}

function Unregister-Device {
    param([string]$DeviceId)

    if (-not $DeviceId) {
        Write-Status "No device ID found, skipping API unregistration" "Warning"
        return
    }

    Write-Status "Removing device from dashboard..."

    try {
        $body = @{ device_id = $DeviceId } | ConvertTo-Json
        $response = Invoke-RestMethod -Uri "$ApiServer/api/device/unregister" -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
        Write-Status "Device removed from dashboard" "Success"
    } catch {
        Write-Status "Could not remove from dashboard (may already be removed): $_" "Warning"
    }
}

function Stop-RustDesk {
    Write-Status "Stopping RustDesk processes..."

    # Stop the service
    Stop-Service -Name "RustDesk" -Force -ErrorAction SilentlyContinue

    # Kill any remaining processes
    Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Uninstall-RustDesk {
    Write-Status "Uninstalling RustDesk..."

    $uninstallPaths = @(
        "C:\Program Files\RustDesk\rustdesk.exe",
        "${env:ProgramFiles}\RustDesk\rustdesk.exe",
        "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe"
    )

    foreach ($path in $uninstallPaths) {
        if (Test-Path $path) {
            try {
                Start-Process -FilePath $path -ArgumentList "--uninstall" -Wait -ErrorAction Stop
                break
            } catch {
                Write-Status "Uninstall command failed, trying manual removal..." "Warning"
            }
        }
    }

    Start-Sleep -Seconds 3

    # Remove program files (including launcher and custom icon)
    $programDirs = @(
        "C:\Program Files\RustDesk",
        "${env:ProgramFiles}\RustDesk",
        "${env:ProgramFiles(x86)}\RustDesk"
    )

    foreach ($dir in $programDirs) {
        if (Test-Path $dir) {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Removed $dir" "Info"
        }
    }

    # Remove config directories
    $configDirs = @(
        (Join-Path $env:APPDATA "RustDesk"),
        "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk"
    )

    foreach ($dir in $configDirs) {
        if (Test-Path $dir) {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Removed config: $dir" "Info"
        }
    }

    # Remove service
    $null = sc.exe delete RustDesk 2>&1

    # Remove ALL shortcuts (original and branded names)
    Write-Status "Removing shortcuts..."
    $shortcutNames = @("RustDesk.lnk", "Nerdy Neighbor Support - RustDesk.lnk")
    $shortcutLocations = @(
        [Environment]::GetFolderPath("Desktop"),
        [Environment]::GetFolderPath("CommonDesktopDirectory"),
        (Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"),
        (Join-Path ([Environment]::GetFolderPath("CommonStartMenu")) "Programs"),
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs")
    )

    foreach ($location in $shortcutLocations) {
        foreach ($name in $shortcutNames) {
            $shortcut = Join-Path $location $name
            if (Test-Path $shortcut) {
                Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
                Write-Status "Removed shortcut: $shortcut" "Info"
            }
        }
        # Remove RustDesk and Nerdy Neighbor Support folders
        foreach ($folder in @("RustDesk", "Nerdy Neighbor Support")) {
            $folderPath = Join-Path $location $folder
            if (Test-Path $folderPath) {
                Remove-Item -Path $folderPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status "Removed folder: $folderPath" "Info"
            }
        }
    }

    # Remove registry entries
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk",
        "HKCU:\SOFTWARE\RustDesk",
        "HKLM:\SOFTWARE\RustDesk"
    )

    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Removed registry: $regPath" "Info"
        }
    }

    # Remove "Run as Admin" compatibility flags for RustDesk and launcher
    $compatPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
    if (Test-Path $compatPath) {
        $filesToRemove = @(
            "C:\Program Files\RustDesk\rustdesk.exe",
            "C:\Program Files\RustDesk\StartRustDesk.cmd"
        )
        foreach ($file in $filesToRemove) {
            Remove-ItemProperty -Path $compatPath -Name $file -ErrorAction SilentlyContinue
        }
        Write-Status "Removed compatibility flags" "Info"
    }

    # Remove startup entries
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

    # Remove firewall rules
    Remove-NetFirewallRule -DisplayName "*RustDesk*" -ErrorAction SilentlyContinue

    Write-Status "RustDesk uninstalled" "Success"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

try {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  RustDesk Uninstall Script" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Check for admin rights
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator"
    }

    # Get device ID before uninstalling
    $deviceId = Get-RustDeskId
    if ($deviceId) {
        Write-Status "Found device ID: $deviceId" "Info"
    }

    # Stop RustDesk
    Stop-RustDesk

    # Unregister from API
    Unregister-Device -DeviceId $deviceId

    # Uninstall RustDesk
    Uninstall-RustDesk

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Uninstall Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

} catch {
    Write-Status "Error: $_" "Error"
    exit 1
}
