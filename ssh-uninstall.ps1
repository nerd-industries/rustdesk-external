#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Cleanly removes the diagnostic OpenSSH installation created by
    ssh-install.ps1 -- service, files, host keys, authorized keys, firewall
    rule, PATH entry. Designed to leave no trace.

.DESCRIPTION
    Tear-down companion for ssh-install.ps1. Idempotent: re-runnable, no-ops
    if pieces are already gone. Also removes Microsoft's optional-feature
    OpenSSH server if present, so an attacker can't slip in via that channel
    after we tear down ours.

    What it removes:
      - sshd and ssh-agent services (via official uninstall-sshd.ps1 if
        present, then sc.exe delete as a fallback)
      - Windows optional-feature OpenSSH.Server* capabilities
      - C:\Program Files\OpenSSH (our install dir)
      - C:\ProgramData\ssh (host keys, sshd_config, administrators_authorized_keys)
      - The claude-debug entry from every per-user ~\.ssh\authorized_keys
      - All OpenSSH firewall rules (our LAN-only one + any broad-scope ones)
      - PATH entry pointing at our install dir
      - Stray sshd/ssh-agent/ssh.exe processes

.NOTES
    Run with: irm https://ssh-uninstall.nerdyneighbor.net | iex
    Or save and run: powershell.exe -ExecutionPolicy Bypass -File ssh-uninstall.ps1
#>

# Use Continue so cleanup keeps going past individual failures -- the goal
# is "remove as much as possible", not "stop at the first missing thing".
$ErrorActionPreference = "Continue"

$InstallDir = "C:\Program Files\OpenSSH"
$FirewallRuleName = "OpenSSH-Server-In-TCP-LAN"
$KeyMarker = "claude-debug"   # match key by trailing comment, not full line

function Show-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Must run as Administrator." -ForegroundColor Red
    exit 1
}

Show-Step "Stopping OpenSSH services..."
foreach ($svc in @("sshd", "ssh-agent")) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

# Use the official uninstall script if present -- it knows the right
# deregistration sequence for whatever Win32-OpenSSH version is installed.
$uninstallScript = Join-Path $InstallDir "uninstall-sshd.ps1"
if (Test-Path $uninstallScript) {
    Show-Step "Running official uninstall-sshd.ps1..."
    & powershell.exe -ExecutionPolicy Bypass -File $uninstallScript 2>&1 | Out-Null
}

Show-Step "Force-deleting any leftover sshd / ssh-agent services..."
foreach ($svc in @("sshd", "ssh-agent")) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        & sc.exe delete $svc | Out-Null
    }
}

Show-Step "Removing Windows OpenSSH.Server optional feature (if installed)..."
try {
    Get-WindowsCapability -Online -ErrorAction Stop |
        Where-Object { $_.Name -like "OpenSSH.Server*" -and $_.State -eq "Installed" } |
        ForEach-Object {
            Write-Host "    Removing capability: $($_.Name)"
            Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null
        }
} catch {
    # Get-WindowsCapability can fail on some editions; not fatal
}

Show-Step "Killing any lingering ssh / sshd / ssh-agent processes..."
foreach ($name in @("sshd", "ssh-agent", "ssh")) {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

Show-Step "Removing install directory $InstallDir..."
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Also nuke the Microsoft optional-feature install dir, just in case
$msInstallDir = "C:\Windows\System32\OpenSSH"
if (Test-Path $msInstallDir) {
    Show-Step "Note: Microsoft OpenSSH binaries still in $msInstallDir (these belong to"
    Write-Host "    the Windows component; uninstalled via Remove-WindowsCapability above)"
}

Show-Step "Removing C:\ProgramData\ssh (host keys + config + admin authorized_keys)..."
$progDataSsh = "C:\ProgramData\ssh"
if (Test-Path $progDataSsh) {
    Remove-Item -Path $progDataSsh -Recurse -Force -ErrorAction SilentlyContinue
}

Show-Step "Scrubbing $KeyMarker from every per-user authorized_keys..."
$scrubbed = 0
foreach ($userDir in Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue) {
    $authKeys = Join-Path $userDir.FullName ".ssh\authorized_keys"
    if (Test-Path $authKeys) {
        $content = @(Get-Content $authKeys -ErrorAction SilentlyContinue)
        $filtered = @($content | Where-Object { $_ -notmatch [regex]::Escape($KeyMarker) })
        if ($filtered.Count -lt $content.Count) {
            if ($filtered.Count -eq 0) {
                Remove-Item $authKeys -Force -ErrorAction SilentlyContinue
            } else {
                Set-Content -Path $authKeys -Value $filtered -Encoding UTF8 -Force
            }
            Write-Host "    Cleaned: $authKeys"
            $scrubbed++
        }
    }
}
if ($scrubbed -eq 0) { Write-Host "    No per-user authorized_keys files contained the marker" }

Show-Step "Removing OpenSSH firewall rules..."
$removedRules = 0
foreach ($n in @($FirewallRuleName, "OpenSSH-Server-In-TCP", "sshd")) {
    $r = Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
    if ($r) {
        $r | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        $removedRules++
    }
}
# Also catch any display-name matches we missed
Get-NetFirewallRule -DisplayName "OpenSSH*" -ErrorAction SilentlyContinue | ForEach-Object {
    $_ | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    $removedRules++
}
Write-Host "    Removed $removedRules firewall rule(s)"

Show-Step "Cleaning system PATH..."
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -like "*$InstallDir*") {
    $newPath = ($currentPath -split ';' |
                Where-Object { $_ -and ($_.TrimEnd('\') -ne $InstallDir.TrimEnd('\')) }) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
    Write-Host "    Removed $InstallDir from system PATH"
} else {
    Write-Host "    $InstallDir not in PATH, nothing to clean"
}

# Final verification pass
Show-Step "Verifying removal..."
$residual = @()
if (Test-Path $InstallDir)        { $residual += "Install dir still present: $InstallDir" }
if (Test-Path $progDataSsh)       { $residual += "$progDataSsh still present" }
foreach ($svc in @("sshd","ssh-agent")) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        $residual += "Service '$svc' still registered"
    }
}
if (Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue) {
    $residual += "Firewall rule '$FirewallRuleName' still present"
}
if (Get-NetFirewallRule -DisplayName "OpenSSH*" -ErrorAction SilentlyContinue) {
    $residual += "Other OpenSSH* firewall rules still present"
}

Write-Host ""
if ($residual.Count -eq 0) {
    Write-Host "OpenSSH removed cleanly. No trace remaining." -ForegroundColor Green
} else {
    Write-Host "Removal completed, but the following items still exist:" -ForegroundColor Yellow
    $residual | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "These usually clear after a reboot. Re-run this script after rebooting if they persist." -ForegroundColor DarkGray
}
Write-Host ""
