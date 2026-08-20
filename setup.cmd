@echo off
REM ============================================================
REM  setup.cmd - ONE-CLICK: dsh web autostart (hidden window +
REM  crash auto-restart) + take over a running instance.
REM ============================================================
REM  Double-click this file on YOUR machine. It:
REM    1) installs start-dsh-web.vbs into the Startup folder so dsh web
REM       starts hidden at every logon
REM    2) runs the supervisor NOW (hidden), ADOPTING your currently-
REM       running dsh web if any, so a crash is auto-restarted
REM    3) verifies http://127.0.0.1:3080 is reachable
REM
REM  Flags:
REM     setup.cmd -uninstall   remove autostart (does NOT stop dsh web)
REM     setup.cmd -stop        stop dsh web + disable auto-restart
REM     setup.cmd -pause       disable auto-restart; leave dsh web running
REM     setup.cmd -start       resume supervision
REM     setup.cmd -restart     request a supervised restart
REM     setup.cmd -control     open the on-demand GUI
REM
REM  NOTE: this file is ASCII-only so output is never garbled on any
REM  codepage. The companion .txt files have the Chinese docs.
REM ============================================================
setlocal EnableExtensions

set "SRC=%~dp0"
set "VBS=start-dsh-web.vbs"
set "PS1=dsh-web-launcher.ps1"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "ADMIN_STARTUP=%ProgramData%\Microsoft\Windows\Start Menu\Programs\StartUp"

echo.
echo ================================================
echo   dsh web autostart + hidden window + crash restart
echo   one-click setup
echo ================================================

if /I "%~1"=="-uninstall" goto :uninstall
if /I "%~1"=="-stop"      goto :stop
if /I "%~1"=="-pause"     goto :pause
if /I "%~1"=="-start"     goto :start
if /I "%~1"=="-restart"   goto :restart
if /I "%~1"=="-status"    goto :status
if /I "%~1"=="-control"   goto :control

REM ---------- 1) install autostart ----------
echo.
echo [1/3] installing autostart (logon startup) ...
REM The Startup entry is RENDERED (not copied) so it carries the absolute
REM launcher path and points back at this install dir; a plain copy would leave
REM the vbs looking for dsh-web-launcher.ps1 inside the Startup folder, where it
REM never is (root cause of autostart silently doing nothing).
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%render-autostart-vbs.ps1" -InstallDir "%SRC%"
if errorlevel 1 (
  echo   WARN- could not render autostart into Startup. Autostart skipped,
  echo         but the supervisor can still start below.
) else (
  echo   OK  - autostart installed (see line above)
)

REM ---------- 2) start / adopt supervisor now ----------
echo.
echo [2/3] starting the supervisor now (hidden) ...
echo   - if dsh web is already running it will be ADOPTED + supervised
echo   - if it crashes later it will be restarted in ~2s
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Start
echo   OK  - supervisor started in background. Logs: logs\launcher-*.log

REM ---------- 3) verify ----------
echo.
echo [3/3] verifying dsh web is reachable ...
timeout /t 3 /nobreak >nul
powershell -NoProfile -Command "$r=try{(Invoke-WebRequest -Uri 'http://127.0.0.1:3080' -UseBasicParsing -TimeoutSec 5).StatusCode}catch{0}; if($r -eq 200){'OK   http://127.0.0.1:3080 is UP'}else{'INFO http://127.0.0.1:3080 not ready yet (code '+$r+'); wait a few seconds or check logs'}"
echo.
echo ================================================
echo   Now under supervision:
echo     - autostarts hidden at every logon
echo     - crashes are auto-restarted
echo   Commands:  setup.cmd -stop  /  setup.cmd -uninstall
echo ================================================
pause
goto :eof

:stop
echo Stopping dsh web and disabling auto-restart ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Stop
echo Done.
goto :eof

:pause
echo Pausing automatic restart; current dsh web will keep running ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Pause
goto :eof

:start
echo Resuming supervision (clearing stop sentinel) ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Start
echo Done.
goto :eof

:restart
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Restart
goto :eof

:status
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%%PS1%" -Status
goto :eof

:control
start "" powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SRC%dsh-control.ps1"
goto :eof

:uninstall
echo Removing autostart (NOT stopping dsh web) ...
for %%S in ("%STARTUP%" "%ADMIN_STARTUP%") do (
  if exist "%%~S\%VBS%" (
    del /q "%%~S\%VBS%" 2>nul
    echo   removed "%%~S\%VBS%"
  )
)
echo Done.
pause
goto :eof
