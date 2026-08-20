@echo off
REM On-demand GUI. Closing the window leaves no GUI/tray process resident.
start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0dsh-control.ps1"
