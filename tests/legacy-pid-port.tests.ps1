$ErrorActionPreference = 'Stop'

$sourceLauncher = Join-Path (Split-Path $PSScriptRoot -Parent) 'dsh-web-launcher.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures\@deepseek-ai\dsh\lib\bin.js'
$node = (Get-Command node.exe -ErrorAction Stop).Source
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('dsh-autostart-legacy-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
Copy-Item -LiteralPath $sourceLauncher -Destination $testDir
$launcher = Join-Path $testDir 'dsh-web-launcher.ps1'
$runDir = Join-Path $testDir 'run'
$legacyPidFile = Join-Path $runDir 'dsh-web.pid'

function Get-FreePort {
  $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
  $listener.Start()
  try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}

function Start-FakeDsh([int]$Port) {
  $arguments = '"' + $fixture + '" web --port ' + $Port
  $process = Start-Process -FilePath $node -ArgumentList $arguments -PassThru -WindowStyle Hidden
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    Start-Sleep -Milliseconds 100
    $owner = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty OwningProcess
  } while ($owner -ne $process.Id -and [DateTime]::UtcNow -lt $deadline)
  if ($owner -ne $process.Id) { throw "fake dsh did not listen on $Port" }
  return $process
}

$wrong = $null
$correct = $null
try {
  $configuredPort = Get-FreePort
  $wrongPort = Get-FreePort
  while ($wrongPort -eq $configuredPort) { $wrongPort = Get-FreePort }

  $wrong = Start-FakeDsh $wrongPort
  New-Item -ItemType Directory -Force -Path $runDir | Out-Null
  $wrong.Id | Set-Content -LiteralPath $legacyPidFile -Encoding ascii
  $status = & $launcher -Status -Port $configuredPort | ConvertFrom-Json
  if ($status.dshRunning) { throw 'wrong-port legacy PID was reported as managed' }
  & $launcher -Stop -Port $configuredPort | Out-Null
  if (-not (Get-Process -Id $wrong.Id -ErrorAction SilentlyContinue)) {
    throw 'wrong-port legacy PID was killed by Stop'
  }

  Remove-Item -LiteralPath (Join-Path $runDir 'pause.sentinel') -Force -ErrorAction SilentlyContinue
  $correct = Start-FakeDsh $configuredPort
  $correct.Id | Set-Content -LiteralPath $legacyPidFile -Encoding ascii
  $status = & $launcher -Status -Port $configuredPort | ConvertFrom-Json
  if (-not $status.dshRunning -or [int]$status.dshPid -ne $correct.Id) {
    throw 'correct-port legacy PID was not accepted'
  }
  & $launcher -Stop -Port $configuredPort | Out-Null
  Start-Sleep -Milliseconds 300
  if (Get-Process -Id $correct.Id -ErrorAction SilentlyContinue) {
    throw 'correct-port legacy PID was not stopped'
  }

  Write-Output 'LEGACY_PID_PORT_OWNERSHIP_OK'
} finally {
  foreach ($process in @($wrong,$correct)) {
    if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
  }
}
