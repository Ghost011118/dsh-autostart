param(
  [string]$InstallDir = $PSScriptRoot,
  [string]$ProgramsDir,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# Tolerate a trailing separator (cmd's %~dp0 always has one) and the stray
# double-quote that a quoted `...\` argument used to inject; either would make
# GetFullPath throw ArgumentException ("illegal characters in path").
$InstallDir = ($InstallDir.Trim().Trim('"')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if (-not $InstallDir) {
  throw 'The install directory could not be resolved.'
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
if (-not $ProgramsDir) {
  $ProgramsDir = [Environment]::GetFolderPath('Programs')
}
if (-not $ProgramsDir) {
  throw 'The current-user Start Menu Programs folder could not be located.'
}

# Keep this script ASCII-compatible with Windows PowerShell 5.1 while still
# giving Chinese Windows users a natural Start Menu search term.
$chineseName = [string]::Concat(
  [char]0x81EA, [char]0x52A8, [char]0x542F, [char]0x52A8,
  [char]0x63A7, [char]0x5236
)
$shortcutPath = Join-Path $ProgramsDir ('DSH ' + $chineseName + '.lnk')

if ($Uninstall) {
  if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
  }
  Write-Output "Control shortcut removed: $shortcutPath"
  exit 0
}

$controlScript = Join-Path $InstallDir 'dsh-control.ps1'
if (-not (Test-Path -LiteralPath $controlScript -PathType Leaf)) {
  throw "Control script was not found: $controlScript"
}

New-Item -ItemType Directory -Force -Path $ProgramsDir | Out-Null
$powershell = Join-Path $PSHOME 'powershell.exe'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershell
$shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $controlScript + '"'
$shortcut.WorkingDirectory = $InstallDir
$shortcut.Description = 'Open the on-demand DSH autostart control panel'
$shortcut.WindowStyle = 7
$shortcut.Save()

Write-Output "Control shortcut installed: $shortcutPath"
