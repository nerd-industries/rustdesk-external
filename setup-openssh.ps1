#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install Win32-OpenSSH from GitHub, authorize Claude's diagnostic SSH key,
    and restrict inbound TCP 22 to LAN traffic only.

.DESCRIPTION
    Downloads the latest OpenSSH-Win64.zip from the PowerShell/Win32-OpenSSH
    GitHub release, extracts it to C:\Program Files\OpenSSH, installs and
    starts the sshd service, drops the pubkey into
    C:\ProgramData\ssh\administrators_authorized_keys with the correct ACL
    (only SYSTEM and Administrators, no inheritance), and creates a firewall
    rule for TCP 22 limited to LocalSubnet on Domain/Private profiles.

.NOTES
    Run with: irm https://raw.githubusercontent.com/nerd-industries/rustdesk-external/main/setup-openssh.ps1 | iex
    Or save and run: powershell.exe -ExecutionPolicy Bypass -File setup-openssh.ps1
#>

$ErrorActionPreference = "Stop"

# Public key authorized for incoming SSH (lives in administrators_authorized_keys
# so it works for any account in the Administrators group)
$PubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAQwebAP+RXnuDkk5VFYlQlvWpf6BZFZU6kX/HrQsOhE claude-debug"

$InstallDir = "C:\Program Files\OpenSSH"
$FirewallRuleName = "OpenSSH-Server-In-TCP-LAN"

function Show-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

try {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator"
    }

    Show-Step "Fetching latest Win32-OpenSSH release info from GitHub..."
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest" -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -eq "OpenSSH-Win64.zip" } | Select-Object -First 1
    if (-not $asset) { throw "OpenSSH-Win64.zip not found in latest release ($($release.tag_name))" }
    Write-Host "    Version: $($release.tag_name)"

    Show-Step "Downloading $($asset.name)..."
    $zipPath = Join-Path $env:TEMP $asset.name
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
    $ProgressPreference = 'Continue'

    # Stop existing services so we can replace files
    Stop-Service sshd -Force -ErrorAction SilentlyContinue
    Stop-Service ssh-agent -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Show-Step "Extracting to $InstallDir..."
    $stagingDir = Join-Path $env:TEMP "OpenSSH-stage-$([System.Guid]::NewGuid())"
    Expand-Archive -Path $zipPath -DestinationPath $stagingDir -Force
    $extracted = Get-ChildItem -Path $stagingDir -Directory | Select-Object -First 1
    if (-not $extracted) { throw "Archive layout unexpected - no directory inside zip" }

    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Move-Item -Path $extracted.FullName -Destination $InstallDir -Force
    Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    Show-Step "Running install-sshd.ps1..."
    $installScript = Join-Path $InstallDir "install-sshd.ps1"
    if (-not (Test-Path $installScript)) { throw "install-sshd.ps1 not found in extracted archive" }
    & powershell.exe -ExecutionPolicy Bypass -File $installScript

    Show-Step "Setting sshd to automatic startup and starting service..."
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd

    Show-Step "Installing authorized public key for administrators..."
    $sshDir = "C:\ProgramData\ssh"
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    $authKeysPath = Join-Path $sshDir "administrators_authorized_keys"

    # Match by the key body (column 2 of the key), not full line — survives comment changes
    $keyBody = ($PubKey -split '\s+')[1]
    $existing = if (Test-Path $authKeysPath) { Get-Content $authKeysPath -ErrorAction SilentlyContinue } else { @() }
    $alreadyPresent = $existing | Where-Object { $_ -match [regex]::Escape($keyBody) }
    if (-not $alreadyPresent) {
        Add-Content -Path $authKeysPath -Value $PubKey -Encoding UTF8
        Write-Host "    Key added"
    } else {
        Write-Host "    Key already present, skipping"
    }

    Show-Step "Setting required ACL on administrators_authorized_keys..."
    # Per Microsoft docs and Win32-OpenSSH security guide: only SYSTEM and
    # BUILTIN\Administrators may access this file, with no inherited permissions.
    & icacls.exe $authKeysPath /inheritance:r /grant "SYSTEM:F" /grant "BUILTIN\Administrators:F" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "icacls returned $LASTEXITCODE on $authKeysPath" }

    Show-Step "Configuring firewall: TCP 22 inbound, LocalSubnet only..."
    # Strip any broad-scope OpenSSH inbound rules created by install-sshd.ps1
    # or the Microsoft optional-feature OpenSSH server, so they don't override
    # our locked-down rule.
    foreach ($displayName in @("OpenSSH-Server-In-TCP", "OpenSSH SSH Server", "OpenSSH SSH Server (sshd)", "sshd")) {
        Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
    Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    New-NetFirewallRule `
        -Name $FirewallRuleName `
        -DisplayName "OpenSSH SSH Server (LAN only)" `
        -Description "Inbound TCP 22 restricted to LocalSubnet for sshd.exe" `
        -Enabled True `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 22 `
        -RemoteAddress LocalSubnet `
        -Profile Domain,Private `
        -Program (Join-Path $InstallDir "sshd.exe") | Out-Null

    Show-Step "Verifying..."
    $sshd = Get-Service sshd
    Write-Host "    sshd service: $($sshd.Status) (startup: $($sshd.StartType))"
    $rule = Get-NetFirewallRule -Name $FirewallRuleName
    $addr = $rule | Get-NetFirewallAddressFilter
    $port = $rule | Get-NetFirewallPortFilter
    Write-Host "    Firewall rule enabled: $($rule.Enabled), profile: $($rule.Profile)"
    Write-Host "    LocalPort: $($port.LocalPort), RemoteAddress: $($addr.RemoteAddress -join ',')"

    $ip = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notlike "169.254.*" } |
           Select-Object -First 1 -ExpandProperty IPAddress)

    Write-Host ""
    Write-Host "OpenSSH installed and locked down to LAN." -ForegroundColor Green
    Write-Host ""
    Write-Host "Connect from the LAN with:"
    Write-Host "  ssh -i <your-private-key> Administrator@$($env:COMPUTERNAME)"
    if ($ip) { Write-Host "  ssh -i <your-private-key> Administrator@$ip" }
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo.ScriptLineNumber) {
        Write-Host "  at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
    }
    exit 1
}
