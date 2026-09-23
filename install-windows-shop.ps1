#Requires -RunAsAdministrator
<#
.SYNOPSIS
    RustDesk Shop Installation Script
    For technician machines - silent install with permanent password

.DESCRIPTION
    This script:
    - Downloads and installs the latest RustDesk
    - Configures it to connect to your self-hosted servers
    - Sets a permanent password for unattended access
    - The API server will see the device when it connects

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

function Save-CustomerName {
    param([string]$Name)
    # Persist the customer name to a hidden file so a later convert run can
    # recover it without re-prompting. Hidden attribute keeps it out of sight.
    $dir = "C:\ProgramData\NerdyNeighbor"
    $path = Join-Path $dir "rustdesk-customer.txt"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Name | Out-File -FilePath $path -Encoding UTF8
    attrib.exe +h $path | Out-Null
    Write-Status "Customer name saved" "Success"
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

function Set-ServiceRecovery {
    # Restart on failure. Stop-RustDesk clears this, so re-apply after the last stop.
    sc.exe failure RustDesk reset= 86400 actions= restart/5000/restart/10000/restart/30000 *>$null
}

function Stop-RustDesk {
    Write-Status "Stopping RustDesk service and processes..."

    # IMPORTANT: the service has auto-restart recovery (sc.exe failure ... restart).
    # If we only kill processes, the SCM relaunches the service within seconds and it
    # re-locks the exe, which then breaks the installer's "restart service" step.
    # Reset recovery FIRST so nothing relaunches while we work, then stop the service
    # and WAIT until it is actually stopped.
    # '""' (not "") so Windows PowerShell 5.1 actually passes an empty argument;
    # a bare "" is dropped and sc.exe rejects the command.
    sc.exe failure RustDesk reset= 0 actions= '""' *>$null

    # Kill GUI/tray/agent processes first so they release file locks. Do NOT kill the
    # --service process directly; the service must be stopped through the SCM so it
    # is not left in a half-dead state. (All three processes share the same exe path,
    # so distinguish them by command line, not path.)
    Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -notlike "*--service*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2

    # Stop the service and wait for it to actually stop. Do NOT delete it here: a
    # stopped-but-present service is what the RustDesk installer expects to update.
    # Deleting a stopped service can leave it in DELETE_PENDING, which makes the
    # installer fail with "Cannot open RustDesk service on computer '.'".
    $svc = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name "RustDesk" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        sc.exe stop RustDesk *>$null
        $waited = 0
        while ($waited -lt 30) {
            $s = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
            if (-not $s -or $s.Status -eq 'Stopped') { break }
            Start-Sleep -Seconds 2
            $waited += 2
        }
        $s = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') {
            # Only as a last resort: the service refuses to stop. Kill its process
            # and delete it, then wait for the delete to fully land (SCM needs the
            # process to exit before the pending delete clears).
            Write-Status "Service refuses to stop; deleting it so the installer can replace it" "Warning"
            Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            sc.exe delete RustDesk *>$null
            $delWaited = 0
            while ($delWaited -lt 30) {
                if (-not (Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Seconds 2
                $delWaited += 2
            }
        } else {
            Write-Status "RustDesk service stopped" "Success"
        }
    } else {
        Write-Status "RustDesk service not present" "Info"
    }
}

function Install-RustDesk {
    param([string]$InstallerPath)

    Write-Status "Installing RustDesk silently..."
    # The downloaded exe is only a launcher: it exits within ~2s and hands the real
    # install to another process, so neither -Wait nor WaitForExit tells us when
    # the install is done. Poll for the result instead.
    Start-Process -FilePath $InstallerPath -ArgumentList "--silent-install"

    $rustdeskPath = "C:\Program Files\RustDesk\rustdesk.exe"
    $maxWait = 180

    # The installer also registers the service TWICE: first a temporary one running
    # "--import-config <user toml>", then it deletes that and registers the real
    # "--service" one. Touching the service in between fails with
    # "Cannot open RustDesk service on computer '.'" (it is DELETE_PENDING), so
    # wait until the exe exists AND the final --service registration has settled.
    Write-Status "Waiting for installation to complete..."
    $settled = $false
    $waited = 0
    while ($waited -lt $maxWait) {
        $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "RustDesk" }
        if ((Test-Path $rustdeskPath) -and $svc -and $svc.PathName -like "*--service*" -and
            $svc.State -in @('Running', 'Stopped')) {
            $settled = $true
            break
        }
        Start-Sleep -Seconds 3
        $waited += 3
    }

    if (-not (Test-Path $rustdeskPath)) {
        throw "RustDesk installation failed - executable not found after ${maxWait}s"
    }

    if ($settled) {
        # sc.exe instead of Set-Service/Start-Service: it reports failure via exit
        # code rather than throwing, so a transient SCM hiccup can't abort the run.
        sc.exe config RustDesk start= auto *>$null
        sc.exe start RustDesk *>$null
        Set-ServiceRecovery
        Write-Status "RustDesk service configured for auto-start with recovery" "Success"
    } else {
        Write-Status "RustDesk service did not settle after ${maxWait}s; continuing" "Warning"
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

    # Write config to user profile (the interactive GUI)
    $userConfigDir = Join-Path $env:APPDATA "RustDesk\config"
    if (-not (Test-Path $userConfigDir)) {
        New-Item -ItemType Directory -Path $userConfigDir -Force | Out-Null
    }
    $configContent | Out-File -FilePath (Join-Path $userConfigDir "RustDesk2.toml") -Encoding UTF8

    # Write config to BOTH service-account profiles. The RustDesk service can run as
    # either LocalSystem (shop install default) or LocalService (customer install),
    # and each reads config from a different profile directory. Writing to both, plus
    # the systemprofile path that LocalSystem actually uses, guarantees the service
    # connects to OUR servers no matter which account it runs under.
    $serviceConfigDirs = @(
        "C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config",
        "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
    )
    foreach ($serviceConfigDir in $serviceConfigDirs) {
        if (-not (Test-Path $serviceConfigDir)) {
            New-Item -ItemType Directory -Path $serviceConfigDir -Force | Out-Null
        }
        $configContent | Out-File -FilePath (Join-Path $serviceConfigDir "RustDesk2.toml") -Encoding UTF8
    }

    Write-Status "Configuration applied" "Success"
}

function Set-RustDeskPassword {
    param([string]$RustDeskPath, [string]$Password)

    Write-Status "Setting permanent password..."

    # Ensure RustDesk service is running (required for IPC)
    $service = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Running") {
        Start-Service -Name "RustDesk" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    # Set the password via command line
    & $RustDeskPath --password $Password
    Start-Sleep -Seconds 2

    Write-Status "Password set" "Success"
}

function Set-RunAsAdmin {
    param([string]$ExePath)

    Write-Status "Setting RustDesk to always run as administrator..."

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"

    # Create the registry key if it doesn't exist
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }

    # Set the RUNASADMIN flag for RustDesk
    Set-ItemProperty -Path $regPath -Name $ExePath -Value "~ RUNASADMIN" -Type String

    Write-Status "Run as administrator compatibility setting applied" "Success"
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

    Write-Status "Sending to: $ApiServer/api/device/register" "Info"

    try {
        $response = Invoke-RestMethod -Uri "$ApiServer/api/device/register" -Method Post -Body $body -ContentType "application/json"
        Write-Status "Device registered successfully" "Success"
    } catch {
        Write-Status "API Error: $($_.Exception.Message)" "Warning"
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

    # Let RustDesk do first-run initialization (generates ID)
    Write-Status "Initializing RustDesk (generating ID)..."
    Start-Process -FilePath $rustdeskPath
    Start-Sleep -Seconds 5

    # Get device ID while RustDesk is running
    $deviceId = Get-RustDeskId -RustDeskPath $rustdeskPath

    # Stop RustDesk to apply config
    Stop-RustDesk

    # Now apply our config AFTER first-run (so it doesn't get overwritten)
    Set-RustDeskConfig -RustDeskPath $rustdeskPath

    # Rename shortcuts to branded name
    Rename-Shortcuts

    # Set RustDesk to always run as administrator
    Set-RunAsAdmin -ExePath $rustdeskPath

    # Generate and set password
    $password = Get-RandomPassword -Length 16
    Set-RustDeskPassword -RustDeskPath $rustdeskPath -Password $password

    # Restart RustDesk service to apply config
    Stop-RustDesk
    Start-Sleep -Seconds 2

    # Start the service so it connects to the API server
    $service = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($service) {
        Start-Service -Name "RustDesk" -ErrorAction SilentlyContinue
        Set-ServiceRecovery
    }

    # Register with API server
    Register-Device -DeviceId $deviceId -Password $password -CustomerName $customerName

    # Save the customer name to a hidden file for later convert runs
    Save-CustomerName -Name $customerName

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

    # Refresh desktop to show new icons
    Write-Status "Refreshing desktop icons..."
    & ie4uinit.exe -show
    Start-Sleep -Seconds 1

    # Launch RustDesk GUI so technician can see the ID
    Write-Status "Launching RustDesk..."
    Start-Process -FilePath $rustdeskPath

    Write-Host ""
    Write-Host "Setup complete! Device is ready for remote access." -ForegroundColor Green
    Write-Host "Note the Device ID shown in the RustDesk window." -ForegroundColor Yellow
    Write-Host ""

    # Cleanup
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

} catch {
    Write-Status "Error: $_" "Error"
    exit 1
}
