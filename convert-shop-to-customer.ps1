#Requires -RunAsAdministrator
<#
.SYNOPSIS
    RustDesk Convert Script — Shop install -> Customer install
.NOTES
    Run with: irm https://rustdesk-convert.nerdyneighbor.net | iex

    Converts an existing SHOP RustDesk install into a CUSTOMER install:
      - Unregisters the device from the API dashboard (shop record).
      - Clears the permanent password so every connection requires "Accept".
      - Adds stop-service = '' and the watchdog + launcher (customer behavior).
      - Re-registers as a customer (blank password) under the SAME customer name
        originally saved by the shop installer.
#>

# Configuration (must match the shop/customer installs)
$ApiServer   = "https://rustdesk-api.nerdyneighbor.net"
$RelayServer = "rustdesk-relay.nerdyneighbor.net"
$PublicKey   = "D11ZYHgpIWTNhltCBMe0f2MQzk+RQp4sI01KbqZj0l4="

$InstallDir = "C:\Program Files\RustDesk"
$WatchdogTaskName = "RustDesk Watchdog"
$NameFile = "C:\ProgramData\NerdyNeighbor\rustdesk-customer.txt"

$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    $colors = @{ "Info" = "Cyan"; "Success" = "Green"; "Warning" = "Yellow"; "Error" = "Red" }
    Write-Host "[$Type] $Message" -ForegroundColor $colors[$Type]
}

function Get-RustDeskId {
    param([string]$RustDeskPath)
    $id = $null
    # Try reading from config first
    $configPaths = @(
        (Join-Path $env:APPDATA "RustDesk\config\RustDesk.toml"),
        (Join-Path $env:APPDATA "RustDesk\config\RustDesk2.toml"),
        "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml"
    )
    foreach ($p in $configPaths) {
        if (Test-Path $p) {
            $c = Get-Content $p -Raw -ErrorAction SilentlyContinue
            if ($c -match 'id\s*=\s*[''" ]?(\d{7,})') { $id = $matches[1]; break }
        }
    }
    if (-not $id -and (Test-Path $RustDeskPath)) {
        $out = & $RustDeskPath --get-id 2>&1 | Out-String
        if ($out -match '(\d{7,})') { $id = $matches[1] }
    }
    return $id
}

function Get-SavedCustomerName {
    if (Test-Path $NameFile) {
        $name = (Get-Content $NameFile -Raw -ErrorAction SilentlyContinue).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    }
    return $null
}

function Unregister-Device {
    param([string]$DeviceId)
    if (-not $DeviceId) { Write-Status "No device ID found, skipping unregister" "Warning"; return }
    try {
        $body = @{ device_id = $DeviceId } | ConvertTo-Json
        Invoke-RestMethod -Uri "$ApiServer/api/device/unregister" -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
        Write-Status "Unregistered from dashboard" "Success"
    } catch {
        Write-Status "Unregister failed (may already be gone): $($_.Exception.Message)" "Warning"
    }
}

function Register-Device {
    param([string]$DeviceId, [string]$CustomerName)
    $hostname = $env:COMPUTERNAME
    $body = @{
        device_id     = $DeviceId
        password      = ""
        hostname      = $hostname
        customer_name = $CustomerName
        install_type  = "customer"
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "$ApiServer/api/device/register" -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
        Write-Status "Re-registered as customer" "Success"
    } catch {
        Write-Status "Re-register failed: $($_.Exception.Message)" "Warning"
    }
}

function Clear-RustDeskPassword {
    param([string]$RustDeskPath)
    $service = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Running") {
        Start-Service -Name "RustDesk" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    & $RustDeskPath --password "" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    Write-Status "Permanent password cleared" "Success"
}

function Set-RustDeskConfig {
    # Customer config: stop-service = '' and no permanent password.
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
stop-service = ''
"@
    $userConfigDir = Join-Path $env:APPDATA "RustDesk\config"
    if (-not (Test-Path $userConfigDir)) { New-Item -ItemType Directory -Path $userConfigDir -Force | Out-Null }
    $configContent | Out-File -FilePath (Join-Path $userConfigDir "RustDesk2.toml") -Encoding UTF8

    $serviceConfigDir = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
    if (-not (Test-Path $serviceConfigDir)) { New-Item -ItemType Directory -Path $serviceConfigDir -Force | Out-Null }
    $configContent | Out-File -FilePath (Join-Path $serviceConfigDir "RustDesk2.toml") -Encoding UTF8

    Write-Status "Customer config applied" "Success"
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

function Write-LauncherScripts {
    $launcherPs1 = @'
$ErrorActionPreference = "SilentlyContinue"
$cfg = Join-Path $env:APPDATA "RustDesk\config\RustDesk2.toml"
if (Test-Path $cfg) {
    $c = Get-Content $cfg -Raw
    if ($c -and $c -match "stop-service\s*=\s*['"]Y['"]") {
        $c = $c -replace "stop-service\s*=\s*['"]Y['"]", "stop-service = ''"
        Set-Content -Path $cfg -Value $c -NoNewline -Encoding UTF8
    }
}
Start-Process -FilePath "C:\Program Files\RustDesk\rustdesk.exe"
'@
    $launcherPs1 | Out-File -FilePath (Join-Path $InstallDir "StartRustDesk.ps1") -Encoding UTF8

    $launcherCmd = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"%~dp0StartRustDesk.ps1`""
    $launcherCmd | Out-File -FilePath (Join-Path $InstallDir "StartRustDesk.cmd") -Encoding ASCII

    $watchdogPs1 = @'
$ErrorActionPreference = "SilentlyContinue"

$svc = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
if (-not $svc) {
    $exe = "C:\Program Files\RustDesk\rustdesk.exe"
    if (Test-Path $exe) {
        Start-Process -FilePath $exe -ArgumentList "--install-service" -WindowStyle Hidden -Wait
        Start-Sleep -Seconds 3
        Set-Service -Name "RustDesk" -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    }
} else {
    if ($svc.StartType -ne 'Automatic') {
        Set-Service -Name "RustDesk" -StartupType Automatic -ErrorAction SilentlyContinue
    }
    if ($svc.Status -ne 'Running') {
        Start-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    }
}

$tomlPaths = @("C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml")
foreach ($u in Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue) {
    $tomlPaths += Join-Path $u.FullName "AppData\Roaming\RustDesk\config\RustDesk2.toml"
}

foreach ($p in $tomlPaths) {
    if (Test-Path $p) {
        $c = Get-Content $p -Raw -ErrorAction SilentlyContinue
        if ($c -and $c -match "stop-service\s*=\s*['"]Y['"]") {
            $c = $c -replace "stop-service\s*=\s*['"]Y['"]", "stop-service = ''"
            Set-Content -Path $p -Value $c -NoNewline -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }
}
'@
    $watchdogPs1 | Out-File -FilePath (Join-Path $InstallDir "Watchdog.ps1") -Encoding UTF8
}

function Register-Watchdog {
    Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $watchdog = Join-Path $InstallDir "Watchdog.ps1"
    $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdog`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argString
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $WatchdogTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

# =============================================================================
# MAIN
# =============================================================================

try {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  RustDesk: Convert Shop -> Customer" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator"
    }

    $rustdeskPath = Join-Path $InstallDir "rustdesk.exe"
    if (-not (Test-Path $rustdeskPath)) {
        throw "RustDesk is not installed at $rustdeskPath — nothing to convert."
    }

    # 1. Recover the customer name from the saved file (fall back to prompt)
    $customerName = Get-SavedCustomerName
    if ($customerName) {
        Write-Status "Customer name found: $customerName"
    } else {
        $customerName = Read-Host "Saved customer name not found. Enter customer name"
        if ([string]::IsNullOrWhiteSpace($customerName)) { throw "Customer name is required" }
    }

    # 2. Stop RustDesk + get ID
    Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $deviceId = Get-RustDeskId -RustDeskPath $rustdeskPath
    if (-not $deviceId) { throw "Could not determine RustDesk device ID" }
    Write-Status "Device ID: $deviceId"

    # 3. Unregister from API (clear the shop record)
    Unregister-Device -DeviceId $deviceId

    # 4. Clear permanent password
    Clear-RustDeskPassword -RustDeskPath $rustdeskPath

    # 5. Apply customer config (stop-service = '')
    Set-RustDeskConfig

    # 6. Remove printer + startup entries (customer parity)
    Remove-RustDeskPrinter
    Remove-StartupEntries

    # 7. Write launcher + watchdog, register task
    Write-LauncherScripts
    Register-Watchdog

    # 8. Restart service
    Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $service = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($service) { Start-Service -Name "RustDesk" -ErrorAction SilentlyContinue }

    # 9. Re-register as customer (blank password)
    Register-Device -DeviceId $deviceId -CustomerName $customerName

    # 10. Launch GUI
    Start-Process -FilePath $rustdeskPath

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Conversion Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Customer:  $customerName" -ForegroundColor Cyan
    Write-Host "Device ID: $deviceId" -ForegroundColor Yellow
    Write-Host "Password:  (none — customer must click Accept)" -ForegroundColor White
    Write-Host ""

} catch {
    $logPath = Join-Path $env:TEMP "nerdy-rustdesk-convert.log"
    try {
        $errMsg = "$(Get-Date -Format o)`r`n$_`r`n`r$($_.ScriptStackTrace)"
        $errMsg | Out-File -FilePath $logPath -Force -Encoding UTF8
    } catch { }
    Write-Host ""
    Write-Host "  Something went wrong." -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor White
    Write-Host "  Log: $logPath" -ForegroundColor Gray
    Write-Host ""
    exit 1
}
