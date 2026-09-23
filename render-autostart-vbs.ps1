# render-autostart-vbs.ps1
# ==================
# Render the Startup-folder autostart entry for dsh web.
#
# setup.cmd / install.cmd copy start-dsh-web.vbs (the portable/mannual shim)
# into the Startup folder, but that vbs resolves `dsh-web-launcher.ps1` as its
# own sibling -- which is only true when the vbs lives beside the launcher
# (i.e. in this install dir). Once copied into Windows Startup, the launcher is
# NOT there, so the copied vbs could never find it and autostart silently did
# nothing. This script fixes the root cause: it writes a vbs whose launcher
# path is the ABSOLUTE install dir, so autostart always works no matter where
# the vbs ends up.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File render-autostart-vbs.ps1
#
# Write target (order): user Startup, else machine Startup, else exit 1.
# The rendered document is one single-logical-line VBS so it is trivial to
# write from cmd-level tooling and survives any codepage.

param(
  # Install dir; defaults to this script's own folder (the tool package root).
  [string]$InstallDir = '',
  # Test/portable override. Normal installs leave this empty.
  [string]$TargetDir = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  $InstallDir = Split-Path $MyInvocation.MyCommand.Path -Parent
}
# Tolerate a trailing separator (cmd's %~dp0 always has one) and the stray
# double-quote that a quoted `...\` argument used to inject; either would make
# Join-Path produce a path that Test-Path rejects as "illegal characters".
$InstallDir = $InstallDir.Trim().Trim('"').TrimEnd('\', '/')
if (-not $InstallDir) {
  $InstallDir = Split-Path $MyInvocation.MyCommand.Path -Parent
}
$launcher = Join-Path $InstallDir 'dsh-web-launcher.ps1'
if (-not (Test-Path $launcher)) {
  Write-Error "render-autostart-vbs: dsh-web-launcher.ps1 not found in '$InstallDir'"
  exit 1
}

$startupUser = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
$startupAdmin = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonStartup)
$vbsName = 'start-dsh-web.vbs'

# Assemble the VBS source. Keep it a single logical line (statements joined by
# ':') so it is trivial to write and survives any codepage. Inside a VBS string
# literal a literal double-quote is written as "". The launcher path needs no
# quotes when it has no spaces, but we wrap it in "" to be safe; we therefore
# need to escape those wraps for the VBS string that carries the whole command.
#
# Target file content:
#   Option Explicit:Dim w:Set w=CreateObject("WScript.Shell"):w.Run "powershell
#     -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File
#     ""D:\dsh-autostart\dsh-web-launcher.ps1""",0,False
$launcherEscaped = $launcher.Replace('"', '""')
$cmdInner = "powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherEscaped`""
# $cmdInner is now a PS string with a literal double-quote around the launcher.
$vbs = 'Option Explicit:Dim w:Set w=CreateObject("WScript.Shell"):w.Run "' +
       $cmdInner.Replace('"', '""') + '",0,False'

$targets = if ($TargetDir) { @($TargetDir) } else { @($startupUser,$startupAdmin) }
$errors = @()
foreach ($target in $targets) {
  if (-not $target -or -not (Test-Path -LiteralPath $target)) { continue }
  $file = Join-Path $target $vbsName
  try {
    [System.IO.File]::WriteAllText($file, $vbs, (New-Object System.Text.UTF8Encoding($false)))
    # Read the bytes back: WriteAllText can silently not take effect for a
    # virtualized/redirected Startup folder, and a 0-byte or stale entry is
    # exactly the "autostart silently does nothing" failure this script exists
    # to prevent. Report it instead of claiming success.
    $written = [System.IO.File]::ReadAllText($file)
    if ($written -notlike "*$launcherEscaped*") {
      $errors += "${file}: verification failed (launcher path missing from the rendered file)"
      continue
    }
    Write-Output "OK  rendered autostart -> $file"
    Write-Output "    launcher: $launcher"
    exit 0
  } catch { $errors += "${file}: $($_.Exception.Message)" }
}
Write-Error "render-autostart-vbs: could not write and verify the Startup entry. $($errors -join '; ')"
exit 1
