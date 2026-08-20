@echo off
REM ============================================================
REM  install.cmd - install/uninstall dsh web autostart (hidden window
REM  + crash auto-restart). ASCII-only on purpose for codepage safety.
REM ============================================================
REM   install            (default) install to current user Startup folder
REM   install -stop      one-off: stop the guarded dsh web, disable auto-restart
REM   install -pause     disable auto-restart; leave dsh web running
REM   install -start     resume one hidden supervisor and return
REM   install -restart   request a supervised restart
REM   install -uninstall remove the Startup entry (does NOT stop the service)
REM ============================================================
setlocal EnableExtensions

set "SRC=%~dp0"
set "VBS=start-dsh-web.vbs"
set "PS1=dsh-web-launcher.ps1"

REM startup folders: current user, then machine-wide
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "ADMIN_STARTUP=%ProgramData%\Microsoft\Windows\Start Menu\Programs\StartUp"

REM ---------- manual stop / resume ----------
if /I "%~1"=="-stop" (
  echo [stop] writing stop sentinel and terminating guarded dsh web ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Stop
  echo [stop] done. Re-running install clears the sentinel.
  goto :eof
)
if /I "%~1"=="-pause" (
  echo [pause] disabling automatic restart; current dsh web stays running ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Pause
  goto :eof
)
if /I "%~1"=="-start" (
  echo [start] clearing stop sentinel, resuming supervision ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Start
  goto :eof
)
if /I "%~1"=="-restart" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Restart
  goto :eof
)
if /I "%~1"=="-status" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Status
  goto :eof
)

REM ---------- uninstall ----------
if /I "%~1"=="-uninstall" (
  for %%S in ("%STARTUP%" "%ADMIN_STARTUP%") do (
    if exist "%%~S\%VBS%" (
      del /q "%%~S\%VBS%"
      echo [uninstall] removed "%%~S\%VBS%"
    )
  )
  echo [uninstall] done. Note: the running dsh web was NOT stopped.
  goto :eof
)

REM ---------- install (default) ----------
echo [install] rendering autostart entry into the Startup folder ...
REM Render (not copy) the Startup vbs so it carries the ABSOLUTE launcher path
REM and points back at this install dir; a plain copy leaves the vbs looking for
REM dsh-web-launcher.ps1 inside Startup, where it never is (autostart silently
REM did nothing).
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%render-autostart-vbs.ps1" -InstallDir "%SRC%"
if errorlevel 1 (
  echo [install] ERROR: could not render Startup entry; run as Administrator.
  goto :eof
)

echo [install] Ready. Start now by running start-dsh-web.vbs in this folder,
echo [install] or without rebooting: powershell -File "%SRC%%PS1%" -Start
goto :eof
