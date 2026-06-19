@echo off
for /f %%a in ('powershell -NoProfile -Command "(Get-Content '%~dp0config.json' -Raw | ConvertFrom-Json).server.port"') do set PORT=%%a
if "%PORT%"=="" set PORT=8080
start "" powershell -ExecutionPolicy Bypass -File "%~dp0server.ps1"
timeout /t 2 /nobreak >nul
start "" "http://localhost:%PORT%/Main.html"
