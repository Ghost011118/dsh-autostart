$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $repo 'install-control-shortcut.ps1'
$testPrograms = Join-Path ([IO.Path]::GetTempPath()) ('dsh-autostart-shortcut-' + [Guid]::NewGuid().ToString('N'))

try {
  & $installer -InstallDir $repo -ProgramsDir $testPrograms | Out-Null
  $links = @(Get-ChildItem -LiteralPath $testPrograms -Filter 'DSH *.lnk')
  if ($links.Count -ne 1) { throw "expected one shortcut, found $($links.Count)" }

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($links[0].FullName)
  $expectedTarget = Join-Path $PSHOME 'powershell.exe'
  $expectedControl = Join-Path $repo 'dsh-control.ps1'
  if (-not [string]::Equals($shortcut.TargetPath, $expectedTarget, [StringComparison]::OrdinalIgnoreCase)) {
    throw "unexpected shortcut target: $($shortcut.TargetPath)"
  }
  if ($shortcut.Arguments -notlike ('*"' + $expectedControl + '"*')) {
    throw "shortcut does not reference the control script: $($shortcut.Arguments)"
  }
  if (-not [string]::Equals($shortcut.WorkingDirectory.TrimEnd('\'), $repo.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "unexpected working directory: $($shortcut.WorkingDirectory)"
  }

  # Installing twice must update the same entry rather than leaving duplicates.
  & $installer -InstallDir $repo -ProgramsDir $testPrograms | Out-Null
  if (@(Get-ChildItem -LiteralPath $testPrograms -Filter 'DSH *.lnk').Count -ne 1) {
    throw 'reinstall created duplicate shortcuts'
  }

  & $installer -ProgramsDir $testPrograms -Uninstall | Out-Null
  if (Test-Path -LiteralPath $links[0].FullName) { throw 'uninstall did not remove the shortcut' }

  Write-Output 'CONTROL_SHORTCUT_OK'
} finally {
  Remove-Item -LiteralPath $testPrograms -Recurse -Force -ErrorAction SilentlyContinue
}
