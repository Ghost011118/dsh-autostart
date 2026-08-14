<#
  dsh-web-launcher.ps1
  =====================
  Windows autostart + hidden-window + crash auto-restart guard for `dsh web`
  (DeepSeek Harness Web GUI).

  This script stays alive in the background as a supervisor for dsh web:
    * launches `dsh web` with a hidden window (no console black box)
    * redirects stdout/stderr into logs\ (falls back to no-redirect if blocked)
    * monitors the child and auto-restarts it when it exits unexpectedly
    * uses a pid file + stop sentinel so a manual stop is not overridden

  Usage
  -----
    powershell -NoProfile -ExecutionPolicy Bypass -File dsh-web-launcher.ps1
        # start guarding dsh web (background; normally called by start-dsh-web.vbs)

    powershell -NoProfile -ExecutionPolicy Bypass -File dsh-web-launcher.ps1 -Stop
        # manual stop: write sentinel, kill the guarded dsh web, exit supervision

    powershell -NoProfile -ExecutionPolicy Bypass -File dsh-web-launcher.ps1 -Start
        # clear the stop sentinel and resume supervision

  Optional parameters
  -------------------
    -Port           default 3080, forwarded to dsh web as --port
    -BindHost       optional, forwarded to dsh web as --host
    -RestartDelay   seconds to wait after a crash before restarting (default 5)
    -LogDir         log directory (default: logs\ beside this script)

  NOTE: this file is intentionally ASCII-only so it survives any codepage /
  BOM situation on a system with a non-UTF-8 (e.g. GBK) locale.
#>
param(
  [int]$Port = 3080,
  [string]$BindHost = '',
  [int]$RestartDelay = 2,
  [string]$LogDir = (Join-Path $PSScriptRoot 'logs'),
  [string]$ChildCmd = '',
  [string]$ChildArgs = '',
  [switch]$Stop,
  [switch]$Start
)

$ErrorActionPreference = 'Stop'
$runDir   = Join-Path $PSScriptRoot 'run'
$pidFile  = Join-Path $runDir 'dsh-web.pid'
$stopFile = Join-Path $runDir 'stop.sentinel'
$stampName = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile  = Join-Path $LogDir "launcher-$stampName.log"
# Locate the dsh bin.js. Prefer resolving the `dsh` shim (cmd/ps1) on PATH,
# then fall back to a global install or the npx cache it was run through.
function Resolve-DshBin {
  # 1) any dsh shim on the PATH (cmd/ps1) -> node_modules/@deepseek-ai/dsh
  $cmd = Get-Command dsh -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) {
    $dir = Split-Path $cmd.Source -Parent
    $nm = Split-Path $dir -Parent
    $bin = Join-Path $nm '@deepseek-ai\dsh\lib\bin.js'
    if (Test-Path $bin) { return $bin }
  }
  # 2) a global @deepseek-ai/dsh install
  $globalBin = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'
  if (Test-Path $globalBin) { return $globalBin }
  # 3) the npx cache that `npx @deepseek-ai/dsh` left behind (any hashed dir)
  if ($env:LOCALAPPDATA) {
    $cacheRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
    if (Test-Path $cacheRoot) {
      foreach ($dir in Get-ChildItem $cacheRoot -Directory -ErrorAction SilentlyContinue) {
        $cand = Join-Path $dir.FullName 'node_modules\@deepseek-ai\dsh\lib\bin.js'
        if (Test-Path $cand) { return $cand }
      }
    }
  }
  return $null
}
$dshBin = Resolve-DshBin
if (-not $dshBin) { throw "dsh bin.js not found" }

New-Item -ItemType Directory -Force -Path $runDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir   | Out-Null

function Write-Log($msg) {
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  try { Add-Content -Path $logFile -Value "[$stamp] $msg" } catch { }
}

function Get-ManagedPid {
  if (Test-Path $pidFile) {
    $raw = (Get-Content $pidFile -Raw).Trim()
    if ($raw -match '^\d+$') { return [int]$raw }
  }
  return $null
}

function Stop-ManagedInstance {
  $id = Get-ManagedPid
  if (-not $id) { return }
  $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
  if ($proc) {
    try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 800
    Write-Log "stopped dsh web (pid $id)"
  } else {
    Write-Log "managed pid $id not running (already exited)"
  }
  Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# Find the PID currently bound to a TCP port, so the supervisor can "adopt"
# an already-running dsh web (a real login instance) instead of starting a
# second one that would collide on the port. Tries Get-NetTCPConnection
# first, then falls back to netstat (works on older/restricted systems).
function Find-PortOwner([int]$port) {
  try {
    $conn = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    if ($conn -and $conn.OwningProcess) { return [int]($conn.OwningProcess | Select-Object -First 1) }
  } catch { }
  try {
    $raw = netstat -ano -p TCP 2>$null
    foreach ($line in $raw) {
      if ($line -match "\s+$port\s.*LISTENING\s+(\d+)\s*$") {
        return [int]$Matches[1]
      }
    }
  } catch { }
  return $null
}

# ---- manual stop ----
if ($Stop) {
  Set-Content -Path $stopFile -Value ((Get-Date).ToString('o')) -Encoding ascii
  Stop-ManagedInstance
  Write-Log 'stop requested; sentinel written.'
  exit 0
}

# ---- manual resume (clear sentinel) ----
if ($Start) {
  Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
  Write-Log 'start requested; cleared stop sentinel.'
}

Write-Log "launcher starting. guarding dsh web on port $Port (crash-restart delay ${RestartDelay}s)."

function Start-DataNode {
  # Ensure the harness home resolves to ~/.dsh regardless of how the guard was
  # launched, so the credentials document is always found. DSH_HOME unset uses
  # process home by default, but pinning it removes any ambiguity when the guard
  # is spawned from a different login/session context.
  if ([string]::IsNullOrEmpty($env:DSH_HOME)) {
    $env:DSH_HOME = Join-Path $env:USERPROFILE '.dsh'
  }
  # Best-effort credential fallback: if the credentials document holds
  # DEEPSEEK_API_KEY but the inherited environment does not, export it for the
  # freshly spawned dsh. This makes the key available through the launching
  # environment even before/without the credentials seam settling, which in turn
  # avoids intermittent "no API key" failures on this route.
  if (-not $env:DEEPSEEK_API_KEY) {
    $credDoc = Join-Path $env:DSH_HOME '.credentials.yaml'
    if (Test-Path $credDoc) {
      try {
        $text = Get-Content $credDoc -Raw
        if ($text -match '^\s*DEEPSEEK_API_KEY\s*:\s*(\S+)' -and $Matches[1] -ne '') {
          $env:DEEPSEEK_API_KEY = $Matches[1]
          Write-Log "exported DEEPSEEK_API_KEY from $credDoc into the dsh child environment"
        }
      } catch {
        Write-Log "could not read $credDoc for DEEPSEEK_API_KEY fallback: $($_.Exception.Message)"
      }
    }
  }

  # Advanced hook (also used by tests): point the supervisor at any command.
  if ($ChildCmd) {
    $argList = @()
    if ($ChildArgs) { $argList = @($ChildArgs) }
    $outFile = Join-Path $LogDir 'child-stdout.log'
    $errFile = Join-Path $LogDir 'child-stderr.log'
    $psParams = @{
      FilePath          = $ChildCmd
      ArgumentList      = $argList
      WorkingDirectory  = $env:USERPROFILE
      WindowStyle       = 'Hidden'
      PassThru          = $true
    }
    $proc = $null
    try {
      $psParams.RedirectStandardOutput = $outFile
      $psParams.RedirectStandardError  = $errFile
      $proc = Start-Process @psParams
    } catch {
      $psParams.Remove('RedirectStandardOutput')
      $psParams.Remove('RedirectStandardError')
      try { $proc = Start-Process @psParams } catch {
        Write-Log "failed to start child: $($_.Exception.Message)"
        return $null
      }
    }
    if (-not $proc) { return $null }
    $proc.Id | Out-File -FilePath $pidFile -Encoding ascii
    Write-Log "started custom child (pid $($proc.Id)): $ChildCmd $ChildArgs"
    return $proc
  }

  $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  if (-not $node) { $node = 'C:\Program Files\nodejs\node.exe' }
  if (-not (Test-Path $node)) { throw "node executable not found: $node" }

  # dsh web alias, then its own flags (--port / --host)
  $webArgs = @('web')
  if ($Port -gt 0)       { $webArgs += @('--port', [string]$Port) }
  if ($BindHost)         { $webArgs += @('--host', $BindHost) }

  # one quoted arg per array element; Start-Process joins with spaces so node parses them
  $argList = @('"' + $dshBin + '"') + ($webArgs | ForEach-Object { '"' + $_ + '"' })

  # hidden window; log-redirect is best-effort (fall back to no-redirect if blocked)
  $outFile = Join-Path $LogDir 'dsh-web-stdout.log'
  $errFile = Join-Path $LogDir 'dsh-web-stderr.log'
  $psParams = @{
    FilePath          = $node
    ArgumentList      = $argList
    WorkingDirectory  = $env:USERPROFILE
    WindowStyle       = 'Hidden'
    PassThru          = $true
  }
  $proc = $null
  try {
    $psParams.RedirectStandardOutput = $outFile
    $psParams.RedirectStandardError  = $errFile
    $proc = Start-Process @psParams
  }
  catch {
    Write-Log "redirect blocked, retrying without redirect: $($_.Exception.Message)"
    $psParams.Remove('RedirectStandardOutput')
    $psParams.Remove('RedirectStandardError')
    try {
      $proc = Start-Process @psParams
    }
    catch {
      Write-Log "failed to start dsh web: $($_.Exception.Message)"
      return $null
    }
  }

  if (-not $proc) {
    Write-Log 'Start-Process returned no handle; treating as startup failure'
    return $null
  }
  $proc.Id | Out-File -FilePath $pidFile -Encoding ascii
  Write-Log "started dsh web (node pid $($proc.Id)) : dsh $webArgs"
  return $proc
}

function Wait-ChildExit($proc) {
  # poll every 2s so an exception in Wait-Process (e.g. pid reuse) never stops us
  while ($proc) {
    $proc.Refresh()
    if ($proc.HasExited) {
      if ($proc.ExitCode -ne 0) {
        Write-Log "child exited with non-zero code $($proc.ExitCode)"
      }
      return
    }
    if (Test-Path $stopFile) {
      Write-Log 'stop sentinel present; stopping child.'
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
      return
    }
    Start-Sleep -Seconds 2
  }
}

# ---- supervision main loop ----
while ($true) {
  if (Test-Path $stopFile) {
    Write-Log 'stop sentinel present; exiting supervision.'
    break
  }

  # already running? adopt and supervise to avoid double-launch.
  # Priority: the tracked pid, else whatever owns the port right now
  # (lets us take over a dsh web that was started some other way).
  $existing = $null
  $p = Get-ManagedPid
  if ($p) { $existing = Get-Process -Id $p -ErrorAction SilentlyContinue }
  if (-not $existing) {
    $owner = Find-PortOwner $Port
    if ($owner) {
      $existing = Get-Process -Id $owner -ErrorAction SilentlyContinue
      if ($existing) {
        Write-Log "adopting existing port owner pid $owner on port $Port."
        $existing.Id | Out-File -FilePath $pidFile -Encoding ascii
      }
    }
  }

  if ($existing) {
    Write-Log "dsh web already running (pid $($existing.Id)); supervising."
  } else {
    $existing = Start-DataNode
    if (-not $existing) {
      Write-Log "failed to start dsh web; retrying in ${RestartDelay}s..."
      Start-Sleep -Seconds $RestartDelay
      continue
    }
  }

  Wait-ChildExit $existing
  Write-Log "dsh web (pid $($existing.Id)) left the supervised state."

  if (Test-Path $stopFile) {
    Write-Log 'stop sentinel present after exit; exiting.'
    break
  }
  Write-Log "restarting in ${RestartDelay}s..."
  Start-Sleep -Seconds $RestartDelay
}
