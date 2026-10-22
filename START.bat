@echo off
REM Double-click to run Public WiFi Reconnect
start "" powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0wifi-reconnect.ps1"
