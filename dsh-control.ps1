# On-demand control panel. It has no tray process and consumes no memory after
# the window is closed.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class DshNativeLanguage {
  [DllImport("kernel32.dll")]
  public static extern ushort GetUserDefaultUILanguage();
}
'@

$uiLanguage = try {
  [Globalization.CultureInfo]::GetCultureInfo([int][DshNativeLanguage]::GetUserDefaultUILanguage()).TwoLetterISOLanguageName
} catch {
  [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
}
$script:language = if ($uiLanguage -eq 'zh') { 'zh' } else { 'en' }
$zh = @'
{
  "title":"DSH \u81ea\u52a8\u542f\u52a8\u63a7\u5236",
  "language":"English",
  "enabled":"\u5df2\u542f\u7528",
  "paused":"\u5df2\u6682\u505c",
  "running":"\u8fd0\u884c\u4e2d",
  "notRunning":"\u672a\u8fd0\u884c",
  "autoRestart":"\u81ea\u52a8\u91cd\u542f",
  "dsh":"DSH",
  "supervisor":"\u5b88\u62a4\u8fdb\u7a0b",
  "statusUnavailable":"\u65e0\u6cd5\u83b7\u53d6\u72b6\u6001",
  "resume":"\u6062\u590d / \u542f\u52a8",
  "pause":"\u6682\u505c\u81ea\u52a8\u91cd\u542f",
  "restart":"\u91cd\u542f DSH",
  "stop":"\u505c\u6b62 DSH \u5e76\u6682\u505c",
  "web":"\u6253\u5f00 DSH \u7f51\u9875",
  "logs":"\u6253\u5f00\u65e5\u5fd7",
  "note":"\u6b64\u9762\u677f\u4ec5\u5728\u6253\u5f00\u65f6\u8fd0\u884c\uff1b\u5173\u95ed\u540e\u4e0d\u4fdd\u7559\u754c\u9762\u8fdb\u7a0b\u3002"
}
'@ | ConvertFrom-Json
$text = @{
  en = @{
    title = 'DSH Autostart Control'; language = ('"\u4e2d\u6587"' | ConvertFrom-Json)
    enabled = 'ENABLED'; paused = 'PAUSED'; running = 'RUNNING'; notRunning = 'NOT RUNNING'
    autoRestart = 'Auto-restart'; dsh = 'DSH'; supervisor = 'Supervisor'
    statusUnavailable = 'Status unavailable'; resume = 'Resume / Start'; pause = 'Pause auto-restart'
    restart = 'Restart DSH'; stop = 'Stop DSH + pause'; web = 'Open DSH Web'; logs = 'Open Logs'
    note = 'This panel runs only while open; closing it leaves no UI process.'
  }
  zh = $zh
}

function Get-Text([string]$Key) {
  $bundle = $text[$script:language]
  if ($bundle -is [Collections.IDictionary]) { return $bundle[$Key] }
  return $bundle.PSObject.Properties[$Key].Value
}

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
$form.Size = New-Object Drawing.Size(470,285)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(18,18)
$status.Size = New-Object Drawing.Size(330,58)
$status.Font = New-Object Drawing.Font('Segoe UI',10)
$form.Controls.Add($status)

$note = New-Object Windows.Forms.Label
$note.Location = New-Object Drawing.Point(18,210)
$note.Size = New-Object Drawing.Size(425,28)
$form.Controls.Add($note)

$languageButton = New-Object Windows.Forms.Button
$languageButton.Location = New-Object Drawing.Point(360,14)
$languageButton.Size = New-Object Drawing.Size(74,28)
$form.Controls.Add($languageButton)

$script:actionButtons = @{}

function Refresh-Status {
  try {
    $data = (Invoke-Launcher '-Status') | ConvertFrom-Json
    $mode = if ($data.paused) { Get-Text 'paused' } else { Get-Text 'enabled' }
    $dshState = if ($data.dshRunning) { "$(Get-Text 'running') (PID $($data.dshPid))" } else { Get-Text 'notRunning' }
    $guard = if ($data.supervisorRunning) { Get-Text 'running' } else { Get-Text 'notRunning' }
    $status.Text = "$(Get-Text 'autoRestart'): $mode`r`n$(Get-Text 'dsh'): $dshState`r`n$(Get-Text 'supervisor'): $guard"
  } catch { $status.Text = "$(Get-Text 'statusUnavailable'): $($_.Exception.Message)" }
}

function Add-Button($key,$x,$y,$action) {
  $button = New-Object Windows.Forms.Button
  $button.Location = New-Object Drawing.Point($x,$y)
  $button.Size = New-Object Drawing.Size(132,38)
  $button.Add_Click({
    $result = Invoke-Launcher $action
    Start-Sleep -Milliseconds 350
    Refresh-Status
    if ($result -and $result -match 'error|failed|cannot|No valid') {
      [Windows.Forms.MessageBox]::Show($result,(Get-Text 'title')) | Out-Null
    }
  }.GetNewClosure())
  $form.Controls.Add($button)
  $script:actionButtons[$key] = $button
}

Add-Button 'resume' 18 88 '-Start'
Add-Button 'pause' 160 88 '-Pause'
Add-Button 'restart' 302 88 '-Restart'
Add-Button 'stop' 18 140 '-Stop'

$openWeb = New-Object Windows.Forms.Button
$openWeb.Location = New-Object Drawing.Point(160,140)
$openWeb.Size = New-Object Drawing.Size(132,38)
$openWeb.Add_Click({ Start-Process 'http://127.0.0.1:3080' })
$form.Controls.Add($openWeb)

$openLogs = New-Object Windows.Forms.Button
$openLogs.Location = New-Object Drawing.Point(302,140)
$openLogs.Size = New-Object Drawing.Size(132,38)
$openLogs.Add_Click({
  $path = Join-Path $PSScriptRoot 'logs'
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  Start-Process explorer.exe -ArgumentList ('"' + $path + '"')
})
$form.Controls.Add($openLogs)

function Apply-Language {
  $form.Text = Get-Text 'title'
  $languageButton.Text = Get-Text 'language'
  foreach ($key in $script:actionButtons.Keys) { $script:actionButtons[$key].Text = Get-Text $key }
  $openWeb.Text = Get-Text 'web'
  $openLogs.Text = Get-Text 'logs'
  $note.Text = Get-Text 'note'
}

$languageButton.Add_Click({
  $script:language = if ($script:language -eq 'zh') { 'en' } else { 'zh' }
  Apply-Language
  Refresh-Status
})

Apply-Language
Refresh-Status
[void]$form.ShowDialog()
