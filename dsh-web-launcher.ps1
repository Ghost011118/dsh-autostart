<#
  dsh-web-launcher.ps1
  =====================
  Windows autostart + hidden-window + crash auto-restart guard for `dsh web`
  (DeepSeek Harness Web GUI).

  This script stays alive in the background as a supervisor for dsh web:
    * launches `dsh web` with a hidden window (no console black box)
    * redirects stdout/stderr into logs\ (falls back to no-redirect if blocked)
    * monitors the child and auto-restarts it when it exits unexpectedly
    * uses verified process state + a pause sentinel for safe user control

  Usage
  -----
    powershell -NoProfile -ExecutionPolicy Bypass -File dsh-web-launcher.ps1
        # start guarding dsh web (background; normally called by start-dsh-web.vbs)

    powershell -NoProfile -ExecutionPolicy Bypass -File dsh-web-launcher.ps1 -Stop
        # manual stop: write sentinel, kill the guarded dsh web, exit supervision

    powershell -NoProfile -ExecutionPolicy Bypass -File dsh-web-launcher.ps1 -Start
        # clear the pause sentinel, spawn one hidden supervisor, and return

  Optional parameters
  -------------------
    -Port           default 3080, forwarded to dsh web as --port
    -BindHost       optional, forwarded to dsh web as --host
    -RestartDelay   seconds to wait after a crash before restarting (default 2)
    -UpdateCheckInterval seconds between bounded update checks (default 5)
    -LogDir         log directory (default: logs\ beside this script)

  NOTE: this file is intentionally ASCII-only so it survives any codepage /
  BOM situation on a system with a non-UTF-8 (e.g. GBK) locale.
#>
param(
  [int]$Port = 3080,
  [string]$BindHost = '',
  [int]$RestartDelay = 2,
  [ValidateRange(2, 300)][int]$UpdateCheckInterval = 5,
  [string]$LogDir = (Join-Path $PSScriptRoot 'logs'),
  [string]$ChildCmd = '',
  [string]$ChildArgs = '',
  [switch]$Stop,
  [switch]$Pause,
  [switch]$Start,
  [switch]$Restart,
  [switch]$Status
)

$ErrorActionPreference = 'Stop'
$runDir   = Join-Path $PSScriptRoot 'run'
$pidFile  = Join-Path $runDir 'dsh-web.pid'
$stateFile = Join-Path $runDir 'dsh-web.json'
$stopFile = Join-Path $runDir 'pause.sentinel'
$legacyStopFile = Join-Path $runDir 'stop.sentinel'
$supervisorFile = Join-Path $runDir 'supervisor.json'
$stampName = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile  = Join-Path $LogDir "launcher-$stampName-$PID.log"
# Locate the dsh bin.js. Prefer resolving the `dsh` shim (cmd/ps1) on PATH,
# then fall back to a global install or the npx cache it was run through.
function Resolve-DshBin {
  # 1) any dsh shim on the PATH (cmd/ps1) -> node_modules/@deepseek-ai/dsh
  $cmd = Get-Command dsh -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) {
    $dir = Split-Path $cmd.Source -Parent
    $bin = Join-Path $dir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    if (Test-Path $bin) { return $bin }
  }
  # 2) a global @deepseek-ai/dsh install
  $globalBin = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'
  if (Test-Path $globalBin) { return $globalBin }
  # 3) the npx cache that `npx @deepseek-ai/dsh` left behind (any hashed dir)
  if ($env:LOCALAPPDATA) {
    $cacheRoot = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
    if (Test-Path $cacheRoot) {
      foreach ($dir in Get-ChildItem $cacheRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending) {
        $cand = Join-Path $dir.FullName 'node_modules\@deepseek-ai\dsh\lib\bin.js'
        if (Test-Path $cand) { return $cand }
      }
    }
  }
  return $null
}
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir   | Out-Null

function Write-Log($msg) {
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  try { Add-Content -Path $logFile -Value "[$stamp] $msg" } catch { }
}

function Read-JsonFile($path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
}

function Write-ProcessRecord($path, $proc, $kind) {
  try { $started = $proc.StartTime.ToUniversalTime().ToString('o') } catch { $started = $null }
  $record = [ordered]@{ pid = [int]$proc.Id; startTimeUtc = $started; kind = $kind }
  $tmp = "$path.$PID.tmp"
  $record | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-ProcessCommandLine([int]$processId) {
  try {
    $item = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
    if ($item) { return [string]$item.CommandLine }
  } catch { }
  return ''
}

function Test-IsDshWebProcess([int]$processId) {
  $line = Get-ProcessCommandLine $processId
  return ($line -and
    $line -match '(?i)@deepseek-ai[\\/]dsh[\\/](?:lib[\\/])?bin\.js' -and
    $line -match '(?i)(?:^|[\s"])(?:web)(?:[\s"]|$)')
}

function Get-ManagedPid {
  $record = Read-JsonFile $stateFile
  if ($record -and $record.pid) {
    $proc = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    try {
      if ($record.startTimeUtc -is [DateTime]) {
        $expected = ([DateTime]$record.startTimeUtc).ToUniversalTime()
      } else {
        $expected = [DateTimeOffset]::Parse([string]$record.startTimeUtc,
          [Globalization.CultureInfo]::InvariantCulture,
          [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
      }
      if ([Math]::Abs(($proc.StartTime.ToUniversalTime() - $expected).TotalSeconds) -gt 1) { return $null }
    } catch { return $null }
    if ([string]$record.kind -ne 'custom' -and -not (Test-IsDshWebProcess $proc.Id)) { return $null }
    return [int]$proc.Id
  }
  if (Test-Path $pidFile) {
    try {
      $raw = (Get-Content $pidFile -Raw).Trim()
      if ($raw -match '^\d+$') {
        $legacyId = [int]$raw
        # A legacy PID file has no creation timestamp. Only retain backwards
        # compatibility when the same PID both proves it is dsh web and owns
        # this supervisor instance's configured listening port.
        $portOwner = Find-PortOwner $Port
        if ($portOwner -eq $legacyId -and (Test-IsDshWebProcess $legacyId)) { return $legacyId }
      }
    } catch { }
  }
  return $null
}

function Stop-ManagedInstance {
  $id = Get-ManagedPid
  if (-not $id) {
    Remove-Item $pidFile,$stateFile -Force -ErrorAction SilentlyContinue
    return
  }
  $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
  if ($proc) {
    try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 800
    Write-Log "stopped dsh web (pid $id)"
  } else {
    Write-Log "managed pid $id not running (already exited)"
  }
  Remove-Item $pidFile,$stateFile -Force -ErrorAction SilentlyContinue
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
      if ($line -match "(?i)^\s*TCP\s+\S+:$port\s+\S+\s+LISTENING\s+(\d+)\s*$") {
        return [int]$Matches[1]
      }
    }
  } catch { }
  return $null
}

function Test-Paused { return ((Test-Path $stopFile) -or (Test-Path $legacyStopFile)) }
function Set-Paused($reason) {
  Set-Content -LiteralPath $stopFile -Value "$reason $([DateTime]::UtcNow.ToString('o'))" -Encoding ascii
  Remove-Item $legacyStopFile -Force -ErrorAction SilentlyContinue
}
function Clear-Paused { Remove-Item $stopFile,$legacyStopFile -Force -ErrorAction SilentlyContinue }

function Start-SupervisorProcess {
  $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $args = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
    '-File',('"' + $PSCommandPath + '"'),'-Port',[string]$Port,
    '-RestartDelay',[string]$RestartDelay,'-UpdateCheckInterval',[string]$UpdateCheckInterval,
    '-LogDir',('"' + $LogDir + '"'))
  if ($BindHost) { $args += @('-BindHost',('"' + $BindHost + '"')) }
  if ($ChildCmd) { $args += @('-ChildCmd',('"' + $ChildCmd + '"')) }
  if ($ChildArgs) { $args += @('-ChildArgs',('"' + $ChildArgs + '"')) }
  Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -PassThru
}

function Get-SupervisorProcess {
  $record = Read-JsonFile $supervisorFile
  if (-not $record -or -not $record.pid -or -not $record.startTimeUtc) { return $null }
  $proc = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
  if (-not $proc) { return $null }
  try {
    if ($record.startTimeUtc -is [DateTime]) {
      $expected = ([DateTime]$record.startTimeUtc).ToUniversalTime()
    } else {
      $expected = [DateTimeOffset]::Parse([string]$record.startTimeUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
    }
    if ([Math]::Abs(($proc.StartTime.ToUniversalTime() - $expected).TotalSeconds) -gt 1) { return $null }
  } catch { return $null }
  return $proc
}

# Controls deliberately run before DSH discovery so they remain available while
# npm is replacing package files. Every control command returns quickly.
if ($Status) {
  $managed = Get-ManagedPid
  $supervisorRunning = [bool](Get-SupervisorProcess)
  [ordered]@{ paused=[bool](Test-Paused); supervisorRunning=$supervisorRunning;
    dshRunning=[bool]$managed; dshPid=$managed; port=$Port; installDir=$PSScriptRoot;
    logDir=$LogDir } | ConvertTo-Json -Compress
  exit 0
}
if ($Pause) {
  Set-Paused 'user-pause'
  Write-Log 'pause requested; current DSH left running.'
  Write-Output 'Paused automatic restart. Current DSH was left running.'
  exit 0
}
if ($Stop) {
  Set-Paused 'user-stop'
  Stop-ManagedInstance
  Write-Log 'stop requested; DSH stopped and restart paused.'
  Write-Output 'Stopped DSH and paused automatic restart.'
  exit 0
}
if ($Restart) {
  if (Test-Paused) { Write-Error 'Automatic restart is paused. Resume first.'; exit 2 }
  $id = Get-ManagedPid
  if (-not $id) { Write-Error 'No valid tracked DSH process is running.'; exit 3 }
  $supervisor = Get-SupervisorProcess
  if (-not $supervisor) {
    try { Start-SupervisorProcess | Out-Null } catch {
      Write-Error "Could not start the supervisor; DSH was left running: $($_.Exception.Message)"
      exit 4
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
      Start-Sleep -Milliseconds 100
      $supervisor = Get-SupervisorProcess
    } while (-not $supervisor -and [DateTime]::UtcNow -lt $deadline)
    if (-not $supervisor) {
      Write-Error 'Could not confirm a running supervisor; DSH was left running.'
      exit 4
    }
  }
  Stop-Process -Id $id -Force -ErrorAction Stop
  Write-Output 'Restart requested.'
  exit 0
}
if ($Start) {
  Clear-Paused
  Start-SupervisorProcess | Out-Null
  Write-Output 'Supervision resumed.'
  exit 0
}
if (Test-Paused) { Write-Log 'pause sentinel present; exiting.'; exit 0 }

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
        if ($text -match '(?m)^\s*DEEPSEEK_API_KEY\s*:\s*["'']?([^#\r\n"'']+)["'']?\s*(?:#.*)?$') {
          $env:DEEPSEEK_API_KEY = $Matches[1].Trim()
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
    Write-ProcessRecord $stateFile $proc 'custom'
    $proc.Id | Set-Content -LiteralPath $pidFile -Encoding ascii
    Write-Log "started custom child (pid $($proc.Id)): $ChildCmd $ChildArgs"
    return $proc
  }

  # Resolve on every launch. npm/npx updates can replace or relocate the entry.
  $script:dshBin = Resolve-DshBin
  if (-not $script:dshBin) {
    Write-Log 'dsh bin.js not found (possibly updating); will retry.'
    return $null
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
  Write-ProcessRecord $stateFile $proc 'dsh'
  $proc.Id | Set-Content -LiteralPath $pidFile -Encoding ascii
  Write-Log "started dsh web (node pid $($proc.Id)) : dsh $webArgs"
  return $proc
}

function Get-DshInstallFingerprint($binPath) {
  if (-not $binPath -or -not (Test-Path -LiteralPath $binPath)) { return $null }
  $packageRoot = Split-Path (Split-Path $binPath -Parent) -Parent
  $watchFiles = @((Join-Path $packageRoot 'package.json'),$binPath)
  $dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
  $profileRoot = Join-Path $dshHome 'profiles\web'
  $profilePackage = Join-Path $profileRoot 'package.json'
  foreach ($name in @('cordis.yml','cordis.patch.yml','package.json','pnpm-lock.yaml')) {
    $file = Join-Path $profileRoot $name
    if (Test-Path -LiteralPath $file) { $watchFiles += $file }
  }
  # Watch only direct profile dependencies. This catches plugin upgrades and
  # local edits to each declared main entry without recursively walking the
  # potentially huge node_modules tree.
  if (Test-Path -LiteralPath $profilePackage) {
    try {
      $manifest = Get-Content -LiteralPath $profilePackage -Raw | ConvertFrom-Json
      $names = @()
      foreach ($group in @('dependencies','devDependencies','optionalDependencies')) {
        if ($manifest.$group) { $names += @($manifest.$group.psobject.Properties.Name) }
      }
      foreach ($name in @($names | Sort-Object -Unique)) {
        $dependencyRoot = Join-Path (Join-Path $profileRoot 'node_modules') $name
        $dependencyPackage = Join-Path $dependencyRoot 'package.json'
        if (Test-Path -LiteralPath $dependencyPackage) {
          $watchFiles += $dependencyPackage
          try {
            $dependencyManifest = Get-Content -LiteralPath $dependencyPackage -Raw | ConvertFrom-Json
            $main = if ($dependencyManifest.main) { [string]$dependencyManifest.main } else { 'index.js' }
            $entry = Join-Path $dependencyRoot $main
            if (Test-Path -LiteralPath $entry -PathType Leaf) { $watchFiles += $entry }
          } catch { }
        }
      }
    } catch { Write-Log "profile package.json could not be parsed for update monitoring: $($_.Exception.Message)" }
  }

  $parts = @()
  foreach ($file in @($watchFiles | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
      $item = Get-Item -LiteralPath $file
      $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
      # DSH itself can touch cordis.yml's timestamp during startup without
      # changing its contents. Timestamps therefore cause a perpetual
      # restart loop; content identity is the authoritative update signal.
      $parts += "$($item.FullName)|$($item.Length)|$hash"
    } catch { return $null }
  }
  return ($parts -join ';')
}

function Wait-ChildExit($proc,$initialFingerprint) {
  $nextCheck = [DateTime]::UtcNow.AddSeconds($UpdateCheckInterval)
  $pendingFingerprint = $null
  while ($proc) {
    if (Test-Paused) { return 'paused' }
    try { $proc.Refresh(); if ($proc.HasExited) { return 'exited' } } catch { return 'exited' }
    if (-not $ChildCmd -and $initialFingerprint -and [DateTime]::UtcNow -ge $nextCheck) {
      $nextCheck = [DateTime]::UtcNow.AddSeconds($UpdateCheckInterval)
      $currentFingerprint = Get-DshInstallFingerprint (Resolve-DshBin)
      if ($currentFingerprint -and $currentFingerprint -ne $initialFingerprint) {
        if ($pendingFingerprint -eq $currentFingerprint) { return 'updated' }
        $pendingFingerprint = $currentFingerprint
        Write-Log 'possible DSH package update detected; waiting for one stable recheck.'
      } else { $pendingFingerprint = $null }
    }
    Start-Sleep -Seconds 1
  }
  return 'exited'
}

function Get-SupervisorMutexName {
  $path = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\').ToLowerInvariant()
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path)) | ForEach-Object {$_.ToString('x2')}) -join '' }
  finally { $sha.Dispose() }
  return "Local\dsh-autostart-$($hash.Substring(0,24))"
}

$mutex = New-Object Threading.Mutex($false,(Get-SupervisorMutexName))
$hasMutex = $false
try {
  try { $hasMutex = $mutex.WaitOne(0,$false) } catch [Threading.AbandonedMutexException] { $hasMutex = $true }
  if (-not $hasMutex) { Write-Log 'another supervisor is already running; exiting duplicate.'; exit 0 }
  Write-ProcessRecord $supervisorFile (Get-Process -Id $PID) 'supervisor'

  while (-not (Test-Paused)) {
    $existing = $null
    $p = Get-ManagedPid
    if ($p) { $existing = Get-Process -Id $p -ErrorAction SilentlyContinue }
    $portCollision = $false
    if (-not $existing -and -not $ChildCmd) {
      $owner = Find-PortOwner $Port
      if ($owner -and (Test-IsDshWebProcess $owner)) {
        $existing = Get-Process -Id $owner -ErrorAction SilentlyContinue
        if ($existing) {
          Write-ProcessRecord $stateFile $existing 'adopted-dsh'
          $existing.Id | Set-Content -LiteralPath $pidFile -Encoding ascii
          Write-Log "adopting verified dsh web pid $owner on port $Port."
        }
      } elseif ($owner) {
        $portCollision = $true
        Write-Log "port $Port belongs to unrelated pid $owner; refusing to adopt or kill it."
      }
    }

    if (-not $existing -and -not $portCollision) { $existing = Start-DataNode }
    if (-not $existing) {
      Start-Sleep -Seconds $RestartDelay
      continue
    }

    $fingerprint = if ($ChildCmd) { $null } else { Get-DshInstallFingerprint (Resolve-DshBin) }
    $reason = Wait-ChildExit $existing $fingerprint
    if ($reason -eq 'paused') {
      Write-Log 'automatic restart paused; current DSH left running.'
      break
    }
    if ($reason -eq 'updated') {
      Write-Log 'stable DSH package update confirmed; restarting tracked DSH.'
      $tracked = Get-ManagedPid
      if ($tracked -eq $existing.Id) {
        try { Stop-Process -Id $tracked -Force -ErrorAction Stop } catch { Write-Log "update restart stop failed: $($_.Exception.Message)" }
      }
    } else { Write-Log "tracked process $($existing.Id) exited." }
    Remove-Item $pidFile,$stateFile -Force -ErrorAction SilentlyContinue
    if (-not (Test-Paused)) { Start-Sleep -Seconds $RestartDelay }
  }
} finally {
  try {
    $record = Read-JsonFile $supervisorFile
    if ($record -and [int]$record.pid -eq $PID) { Remove-Item $supervisorFile -Force -ErrorAction SilentlyContinue }
  } catch { }
  if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
  $mutex.Dispose()
}
