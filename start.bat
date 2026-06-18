@echo off
start "" powershell -ExecutionPolicy Bypass -File "%~dp0server.ps1"
timeout /t 1 /nobreak >nul
start "" "http://localhost:8080/Main.html"
