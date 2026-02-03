#Requires -RunAsAdministrator
# RustDesk ID Diagnostic Script
# Run this to find all possible ways to get the RustDesk ID

$rustdeskPath = "C:\Program Files\RustDesk\rustdesk.exe"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  RustDesk ID Diagnostic Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if RustDesk is installed
Write-Host "1. CHECKING INSTALLATION" -ForegroundColor Yellow
Write-Host "   RustDesk path: $rustdeskPath"
if (Test-Path $rustdeskPath) {
    Write-Host "   Status: INSTALLED" -ForegroundColor Green
} else {
    Write-Host "   Status: NOT FOUND" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Check service status
Write-Host "2. CHECKING SERVICE" -ForegroundColor Yellow
$service = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
if ($service) {
    Write-Host "   Service exists: YES"
    Write-Host "   Service status: $($service.Status)"
    Write-Host "   Startup type: $($service.StartType)"
} else {
    Write-Host "   Service exists: NO" -ForegroundColor Red
}
Write-Host ""

# Check running processes
Write-Host "3. CHECKING PROCESSES" -ForegroundColor Yellow
$procs = Get-Process -Name "rustdesk" -ErrorAction SilentlyContinue
Write-Host "   RustDesk processes running: $($procs.Count)"
if ($procs.Count -gt 0) {
    foreach ($p in $procs) {
        Write-Host "   - PID $($p.Id): $($p.MainWindowTitle)" -ForegroundColor Cyan
    }
}

# Check for --server process
$serverProcs = Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue
if ($serverProcs) {
    foreach ($p in $serverProcs) {
        Write-Host "   - PID $($p.ProcessId) CommandLine: $($p.CommandLine)" -ForegroundColor Cyan
    }
}
Write-Host ""

# Method 1: --get-id command
Write-Host "4. METHOD: --get-id COMMAND" -ForegroundColor Yellow
try {
    $output = & $rustdeskPath --get-id 2>&1 | Out-String
    $output = $output.Trim()
    Write-Host "   Raw output: '$output'"
    if ($output -match '(\d{9,})') {
        Write-Host "   FOUND ID: $($matches[1])" -ForegroundColor Green
    } else {
        Write-Host "   No ID found in output" -ForegroundColor Red
    }
} catch {
    Write-Host "   Error: $_" -ForegroundColor Red
}
Write-Host ""

# Method 2: Config files
Write-Host "5. METHOD: CONFIG FILES" -ForegroundColor Yellow
$configPaths = @(
    "$env:APPDATA\RustDesk\config\RustDesk.toml",
    "$env:APPDATA\RustDesk\config\RustDesk2.toml",
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml",
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml",
    "$env:ProgramData\RustDesk\config\RustDesk.toml",
    "$env:ProgramData\RustDesk\config\RustDesk2.toml",
    "C:\ProgramData\RustDesk\config\RustDesk.toml",
    "C:\ProgramData\RustDesk\config\RustDesk2.toml"
)

foreach ($configPath in $configPaths) {
    Write-Host "   Checking: $configPath"
    if (Test-Path $configPath) {
        Write-Host "   - EXISTS" -ForegroundColor Green
        $content = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
        Write-Host "   - Content preview:" -ForegroundColor Cyan
        $lines = $content -split "`n" | Select-Object -First 10
        foreach ($line in $lines) {
            Write-Host "     $line"
        }

        # Look for id field
        if ($content -match 'enc_id\s*=\s*[''"]([^''"]+)[''"]') {
            Write-Host "   - Found enc_id (encrypted): $($matches[1])" -ForegroundColor Yellow
        }
        if ($content -match '(?<!enc_)id\s*=\s*[''"]?(\d{9,})[''"]?') {
            Write-Host "   - FOUND PLAIN ID: $($matches[1])" -ForegroundColor Green
        }
        if ($content -match '^id\s*=\s*[''"]?(\d{9,})[''"]?' ) {
            Write-Host "   - FOUND ID AT START: $($matches[1])" -ForegroundColor Green
        }
    } else {
        Write-Host "   - NOT FOUND" -ForegroundColor Gray
    }
}
Write-Host ""

# Method 3: Registry
Write-Host "6. METHOD: REGISTRY" -ForegroundColor Yellow
$regPaths = @(
    "HKCU:\SOFTWARE\RustDesk",
    "HKLM:\SOFTWARE\RustDesk",
    "HKCU:\SOFTWARE\RustDesk\RustDesk",
    "HKLM:\SOFTWARE\RustDesk\RustDesk"
)

foreach ($regPath in $regPaths) {
    Write-Host "   Checking: $regPath"
    if (Test-Path $regPath) {
        Write-Host "   - EXISTS" -ForegroundColor Green
        $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        $props.PSObject.Properties | ForEach-Object {
            if ($_.Name -notlike "PS*") {
                Write-Host "     $($_.Name) = $($_.Value)"
            }
        }
    } else {
        Write-Host "   - NOT FOUND" -ForegroundColor Gray
    }
}
Write-Host ""

# Method 4: Try starting service and waiting
Write-Host "7. METHOD: START SERVICE AND RETRY --get-id" -ForegroundColor Yellow
$service = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne "Running") {
    Write-Host "   Starting RustDesk service..."
    Start-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
}

# Wait for --server process
Write-Host "   Waiting for --server process..."
$waited = 0
while ($waited -lt 15) {
    $serverProc = Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*--server*" }
    if ($serverProc) {
        Write-Host "   --server process found!" -ForegroundColor Green
        break
    }
    Start-Sleep -Seconds 1
    $waited++
}

Write-Host "   Trying --get-id again..."
try {
    $output = & $rustdeskPath --get-id 2>&1 | Out-String
    $output = $output.Trim()
    Write-Host "   Raw output: '$output'"
    if ($output -match '(\d{9,})') {
        Write-Host "   FOUND ID: $($matches[1])" -ForegroundColor Green
    } else {
        Write-Host "   No ID found" -ForegroundColor Red
    }
} catch {
    Write-Host "   Error: $_" -ForegroundColor Red
}
Write-Host ""

# Method 5: Start GUI and retry
Write-Host "8. METHOD: START GUI AND RETRY --get-id" -ForegroundColor Yellow
Write-Host "   Starting RustDesk GUI..."
Start-Process -FilePath $rustdeskPath
Start-Sleep -Seconds 8

Write-Host "   Trying --get-id..."
try {
    $output = & $rustdeskPath --get-id 2>&1 | Out-String
    $output = $output.Trim()
    Write-Host "   Raw output: '$output'"
    if ($output -match '(\d{9,})') {
        Write-Host "   FOUND ID: $($matches[1])" -ForegroundColor Green
    } else {
        Write-Host "   No ID found" -ForegroundColor Red
    }
} catch {
    Write-Host "   Error: $_" -ForegroundColor Red
}
Write-Host ""

# Method 6: Check all TOML files for any numeric ID
Write-Host "9. METHOD: SCAN ALL TOML FILES" -ForegroundColor Yellow
$tomlLocations = @(
    "$env:APPDATA\RustDesk",
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk",
    "$env:ProgramData\RustDesk",
    "C:\ProgramData\RustDesk"
)

foreach ($loc in $tomlLocations) {
    if (Test-Path $loc) {
        $files = Get-ChildItem -Path $loc -Recurse -Filter "*.toml" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            Write-Host "   File: $($file.FullName)" -ForegroundColor Cyan
            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            Write-Host "   Full content:"
            Write-Host $content
            Write-Host "   ---"
        }
    }
}
Write-Host ""

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  DIAGNOSTIC COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Copy the output above and share it." -ForegroundColor Yellow
Write-Host ""
