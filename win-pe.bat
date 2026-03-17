@echo off
setlocal

:: Config
set "API_SERVER=https://rustdesk-api.nerdyneighbor.net"
set "RELAY_SERVER=rustdesk-relay.nerdyneighbor.net"
set "PUBLIC_KEY=D11ZYHgpIWTNhltCBMe0f2MQzk+RQp4sI01KbqZj0l4="

:: Paths
set "RUSTDESK_EXE=X:\Program Files\RustDesk\rustdesk.exe"
set "CONFIG_DIR=%APPDATA%\RustDesk\config"
set "CONFIG_FILE=%CONFIG_DIR%\RustDesk2.toml"

echo Stopping RustDesk...
taskkill /f /im rustdesk.exe >nul 2>&1

timeout /t 2 /nobreak >nul

echo Creating config directory...
if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"

echo Writing config...
(
echo rendezvous_server = '%RELAY_SERVER%'
echo nat_type = 1
echo serial = 0
echo.
echo [options]
echo direct-server = 'Y'
echo relay-server = '%RELAY_SERVER%'
echo key = '%PUBLIC_KEY%'
echo custom-rendezvous-server = '%RELAY_SERVER%'
echo api-server = '%API_SERVER%'
) > "%CONFIG_FILE%"

echo Starting RustDesk...
start "" "%RUSTDESK_EXE%"

echo.
echo Done.
echo Config applied to:
echo %CONFIG_FILE%
echo.

endlocal
exit /b 0
