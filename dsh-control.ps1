# On-demand control panel. It has no tray process and consumes no memory after
# the window is closed.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$launcher = Join-Path $PSScriptRoot 'dsh-web-launcher.ps1'
if (-not (Test-Path -LiteralPath $launcher)) {
  [Windows.Forms.MessageBox]::Show('dsh-web-launcher.ps1 was not found.','DSH Control') | Out-Null
  exit 1
}

function Invoke-Launcher([string]$Action) {
  try { return (& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $launcher $Action 2>&1 | Out-String).Trim() }
  catch { return $_.Exception.Message }
}

$form = New-Object Windows.Forms.Form
$form.Text = 'DSH Autostart Control'
$form.Size = New-Object Drawing.Size(470,285)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(18,18)
$status.Size = New-Object Drawing.Size(425,58)
$status.Font = New-Object Drawing.Font('Segoe UI',10)
$form.Controls.Add($status)

$note = New-Object Windows.Forms.Label
$note.Location = New-Object Drawing.Point(18,210)
$note.Size = New-Object Drawing.Size(425,28)
$note.Text = 'This panel runs only while open; the supervisor remains lightweight.'
$form.Controls.Add($note)

function Refresh-Status {
  try {
    $data = (Invoke-Launcher '-Status') | ConvertFrom-Json
    $mode = if ($data.paused) {'PAUSED'} else {'ENABLED'}
    $dsh = if ($data.dshRunning) {"RUNNING (PID $($data.dshPid))"} else {'NOT RUNNING'}
    $guard = if ($data.supervisorRunning) {'RUNNING'} else {'NOT RUNNING'}
    $status.Text = "Auto-restart: $mode`r`nDSH: $dsh    Supervisor: $guard"
  } catch { $status.Text = "Status unavailable: $($_.Exception.Message)" }
}

function Add-Button($text,$x,$y,$action) {
  $button = New-Object Windows.Forms.Button
  $button.Text = $text
  $button.Location = New-Object Drawing.Point($x,$y)
  $button.Size = New-Object Drawing.Size(132,38)
  $button.Add_Click({
    $result = Invoke-Launcher $action
    Start-Sleep -Milliseconds 350
    Refresh-Status
    if ($result -and $result -match 'error|failed|cannot|No valid') {
      [Windows.Forms.MessageBox]::Show($result,'DSH Control') | Out-Null
    }
  }.GetNewClosure())
  $form.Controls.Add($button)
}

Add-Button 'Resume / Start' 18 88 '-Start'
Add-Button 'Pause auto-restart' 160 88 '-Pause'
Add-Button 'Restart DSH' 302 88 '-Restart'
Add-Button 'Stop DSH + pause' 18 140 '-Stop'

$openWeb = New-Object Windows.Forms.Button
$openWeb.Text = 'Open DSH Web'
$openWeb.Location = New-Object Drawing.Point(160,140)
$openWeb.Size = New-Object Drawing.Size(132,38)
$openWeb.Add_Click({ Start-Process 'http://127.0.0.1:3080' })
$form.Controls.Add($openWeb)

$openLogs = New-Object Windows.Forms.Button
$openLogs.Text = 'Open Logs'
$openLogs.Location = New-Object Drawing.Point(302,140)
$openLogs.Size = New-Object Drawing.Size(132,38)
$openLogs.Add_Click({
  $path = Join-Path $PSScriptRoot 'logs'
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  Start-Process explorer.exe -ArgumentList ('"' + $path + '"')
})
$form.Controls.Add($openLogs)

Refresh-Status
[void]$form.ShowDialog()
