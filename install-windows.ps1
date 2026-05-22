#Requires -RunAsAdministrator
<#
.SYNOPSIS
    RustDesk Customer Installation Script
.NOTES
    Run with: irm https://rustdesk-windows.nerdyneighbor.net | iex
#>

# Configuration
$ApiServer = "https://rustdesk-api.nerdyneighbor.net"
$RelayServer = "rustdesk-relay.nerdyneighbor.net"
$PublicKey = "D11ZYHgpIWTNhltCBMe0f2MQzk+RQp4sI01KbqZj0l4="

$ErrorActionPreference = "Stop"

function Show-Progress {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor White
}

function Get-LatestRustDeskVersion {
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/rustdesk/rustdesk/releases/latest"
    return $releases.tag_name
}

function Get-RustDeskInstaller {
    param([string]$Version)
    $versionClean = $Version -replace '^v', ''
    $installerName = "rustdesk-$versionClean-x86_64.exe"
    $downloadUrl = "https://github.com/rustdesk/rustdesk/releases/download/$Version/$installerName"
    $tempPath = Join-Path $env:TEMP $installerName
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempPath -UseBasicParsing
    $ProgressPreference = 'Continue'
    return $tempPath
}

function Stop-RustDesk {
    Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Install-RustDesk {
    param([string]$InstallerPath)
    Start-Process -FilePath $InstallerPath -ArgumentList "--silent-install"
    $rustdeskPath = "C:\Program Files\RustDesk\rustdesk.exe"
    $maxWait = 120
    $waited = 0
    while (-not (Test-Path $rustdeskPath) -and $waited -lt $maxWait) {
        Start-Sleep -Seconds 3
        $waited += 3
    }
    if (-not (Test-Path $rustdeskPath)) {
        throw "Installation failed"
    }
    Start-Sleep -Seconds 5
    return $rustdeskPath
}

function Set-RustDeskConfig {
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
    $userConfigDir = Join-Path $env:APPDATA "RustDesk\config"
    if (-not (Test-Path $userConfigDir)) {
        New-Item -ItemType Directory -Path $userConfigDir -Force | Out-Null
    }
    $configContent | Out-File -FilePath (Join-Path $userConfigDir "RustDesk2.toml") -Encoding UTF8
}

function Get-RustDeskId {
    param([string]$RustDeskPath)
    $maxAttempts = 10
    $attempt = 0
    $id = $null
    while ($attempt -lt $maxAttempts -and -not $id) {
        $attempt++
        try {
            $output = & $RustDeskPath --get-id 2>&1 | Out-String
            if ($output -match '(\d{7,})') {
                $id = $matches[1]
            }
        } catch { }
        if (-not $id) { Start-Sleep -Seconds 3 }
    }
    if (-not $id) { throw "Could not get ID" }
    return $id
}

function Set-RunAsAdmin {
    param([string]$ExePath)
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name $ExePath -Value "~ RUNASADMIN" -Type String
}

function Remove-RustDeskService {
    $service = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($service) {
        Stop-Service -Name "RustDesk" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        $null = sc.exe delete RustDesk 2>&1
    }
}

function Remove-RustDeskPrinter {
    Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*RustDesk*" } | ForEach-Object {
        Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue
    }
    Get-PrinterDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*RustDesk*" } | ForEach-Object {
        Remove-PrinterDriver -Name $_.Name -ErrorAction SilentlyContinue
    }
}

function Remove-StartupEntries {
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
}

function Setup-Shortcuts {
    param([string]$RustDeskExe)
    $newName = "Nerdy Neighbor Support - RustDesk"
    $iconUrl = "https://nerdyneighbor.net/icon.ico"
    $iconPath = "C:\Program Files\RustDesk\nerdy-neighbor.ico"

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $iconUrl -OutFile $iconPath -UseBasicParsing -ErrorAction SilentlyContinue
        $ProgressPreference = 'Continue'
    } catch { $iconPath = $null }

    $shell = New-Object -ComObject WScript.Shell
    $desktopPaths = @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("CommonDesktopDirectory"))

    foreach ($desktop in $desktopPaths) {
        Remove-Item (Join-Path $desktop "RustDesk.lnk") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $desktop "$newName.lnk") -Force -ErrorAction SilentlyContinue
    }

    $publicDesktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
    $desktopShortcut = Join-Path $publicDesktop "$newName.lnk"
    $lnk = $shell.CreateShortcut($desktopShortcut)
    $lnk.TargetPath = $RustDeskExe
    $lnk.WorkingDirectory = "C:\Program Files\RustDesk"
    $lnk.IconLocation = if ($iconPath) { "$iconPath,0" } else { "$RustDeskExe,0" }
    $lnk.Description = "Nerdy Neighbor Remote Support"
    $lnk.Save()

    $startMenuPaths = @(
        (Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"),
        (Join-Path ([Environment]::GetFolderPath("CommonStartMenu")) "Programs"),
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs")
    )
    foreach ($startMenu in $startMenuPaths) {
        $rustdeskFolder = Join-Path $startMenu "RustDesk"
        if (Test-Path $rustdeskFolder) {
            Remove-Item (Join-Path $rustdeskFolder "RustDesk.lnk") -Force -ErrorAction SilentlyContinue
            $newShortcut = Join-Path $rustdeskFolder "$newName.lnk"
            $lnk = $shell.CreateShortcut($newShortcut)
            $lnk.TargetPath = $RustDeskExe
            $lnk.WorkingDirectory = "C:\Program Files\RustDesk"
            $lnk.IconLocation = if ($iconPath) { "$iconPath,0" } else { "$RustDeskExe,0" }
            $lnk.Save()
            Rename-Item -Path $rustdeskFolder -NewName "Nerdy Neighbor Support" -Force -ErrorAction SilentlyContinue
        }
        $oldShortcut = Join-Path $startMenu "RustDesk.lnk"
        if (Test-Path $oldShortcut) {
            Remove-Item $oldShortcut -Force -ErrorAction SilentlyContinue
        }
    }
}

# =============================================================================
# MAIN
# =============================================================================

try {
    Clear-Host
    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor Cyan
    Write-Host "    Nerdy Neighbor Support Setup" -ForegroundColor Cyan
    Write-Host "  ========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Please wait while we set things up..." -ForegroundColor Gray
    Write-Host ""

    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run as Administrator"
    }

    Show-Progress "Downloading support software..."
    $version = Get-LatestRustDeskVersion
    Stop-RustDesk
    $installerPath = Get-RustDeskInstaller -Version $version

    Show-Progress "Installing..."
    $rustdeskPath = Install-RustDesk -InstallerPath $installerPath

    Show-Progress "Setting up..."
    Start-Process -FilePath $rustdeskPath
    Start-Sleep -Seconds 5
    $deviceId = Get-RustDeskId -RustDeskPath $rustdeskPath
    Stop-RustDesk

    Remove-RustDeskService
    Remove-RustDeskPrinter
    Remove-StartupEntries

    Set-RustDeskConfig
    Set-RunAsAdmin -ExePath $rustdeskPath
    Setup-Shortcuts -RustDeskExe $rustdeskPath

    & ie4uinit.exe -show 2>$null
    Start-Sleep -Seconds 1
    Start-Process -FilePath $rustdeskPath

    Clear-Host
    Write-Host ""
    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor Green
    Write-Host "    Setup Complete!" -ForegroundColor Green
    Write-Host "  ========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host ""
    Write-Host "  Your ID number is:" -ForegroundColor White
    Write-Host ""
    Write-Host "       $deviceId" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ""
    Write-Host "  Please tell this number to your" -ForegroundColor White
    Write-Host "  support technician." -ForegroundColor White
    Write-Host ""
    Write-Host "  A window has opened - you can also" -ForegroundColor Gray
    Write-Host "  find the ID and password there." -ForegroundColor Gray
    Write-Host ""
    Write-Host ""

    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

} catch {
    Write-Host ""
    Write-Host "  Something went wrong." -ForegroundColor Red
    Write-Host "  Please contact support for help." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 1
}
