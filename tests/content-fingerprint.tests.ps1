$ErrorActionPreference = 'Stop'

$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'dsh-web-launcher.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'launcher did not parse' }
$functionAst = $ast.Find({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-DshInstallFingerprint'
}, $true)
if ($functionAst -is [array]) { $functionAst = $functionAst[0] }
if ($null -eq $functionAst) { throw 'fingerprint function not found' }
Invoke-Expression $functionAst.Extent.Text

$testDir = Join-Path ([IO.Path]::GetTempPath()) ('dsh-autostart-fingerprint-' + [Guid]::NewGuid().ToString('N'))
$oldDshHome = $env:DSH_HOME
try {
  $packageRoot = Join-Path $testDir 'dsh-package'
  $binDir = Join-Path $packageRoot 'lib'
  $profile = Join-Path $testDir 'home\profiles\web'
  New-Item -ItemType Directory -Path $binDir,$profile | Out-Null
  $bin = Join-Path $binDir 'bin.js'
  Set-Content -LiteralPath (Join-Path $packageRoot 'package.json') -Value '{"name":"@deepseek-ai/dsh"}' -Encoding ascii
  Set-Content -LiteralPath $bin -Value 'console.log("fixture")' -Encoding ascii
  Set-Content -LiteralPath (Join-Path $profile 'package.json') -Value '{"dependencies":{}}' -Encoding ascii
  $cordis = Join-Path $profile 'cordis.yml'
  Set-Content -LiteralPath $cordis -Value 'plugins: {}' -Encoding ascii
  $env:DSH_HOME = Join-Path $testDir 'home'

  $before = Get-DshInstallFingerprint $bin
  [IO.File]::SetLastWriteTimeUtc($cordis, [DateTime]::UtcNow.AddMinutes(1))
  $timestampOnly = Get-DshInstallFingerprint $bin
  if ($timestampOnly -ne $before) { throw 'timestamp-only touch changed the content fingerprint' }

  $beforeLength = (Get-Item -LiteralPath $cordis).Length
  Set-Content -LiteralPath $cordis -Value 'plugins: []' -Encoding ascii
  if ((Get-Item -LiteralPath $cordis).Length -ne $beforeLength) { throw 'test fixture content replacement was not same-length' }
  $contentChanged = Get-DshInstallFingerprint $bin
  if ($contentChanged -eq $before) { throw 'same-length content update did not change the fingerprint' }

  Write-Output 'CONTENT_FINGERPRINT_OK'
} finally {
  if ($null -eq $oldDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue }
  else { $env:DSH_HOME = $oldDshHome }
  Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
}
