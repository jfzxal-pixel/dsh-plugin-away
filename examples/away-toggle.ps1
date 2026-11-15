# 离开模式 — 桌面小浮窗
# 和 DSH 里的 /away 命令操作同一个状态文件，两边实时同步。
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File away-toggle.ps1
#
# 状态文件: $DSH_HOME/away-mode.json（默认 ~/.dsh/away-mode.json）
# 也可以用 -StateFile 指定，或设环境变量 DSH_AWAY_STATE。
param(
  [string]$StateFile = $(if ($env:DSH_AWAY_STATE) { $env:DSH_AWAY_STATE }
    elseif ($env:DSH_HOME) { Join-Path $env:DSH_HOME 'away-mode.json' }
    else { Join-Path (Join-Path $HOME '.dsh') 'away-mode.json' })
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Read-State {
  try {
    $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 -ErrorAction Stop
    return ($raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}
function Write-State([bool]$enabled) {
  $dir = Split-Path -Parent $StateFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $json = @{ enabled = $enabled; updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } |
    ConvertTo-Json
  [System.IO.File]::WriteAllText($StateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

$form = New-Object System.Windows.Forms.Form
$form.Text = '离开模式'
$form.Size = New-Object System.Drawing.Size(360, 170)
$form.FormBorderStyle = 'FixedToolWindow'
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.DesktopLocation = New-Object System.Drawing.Point(
  ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Right - 380),
  ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Bottom - 210))
$form.BackColor = [System.Drawing.Color]::FromArgb(32, 34, 38)
$form.ForeColor = [System.Drawing.Color]::White

$check = New-Object System.Windows.Forms.CheckBox
$check.Text = '  离开状态：任务跑完通知我'
$check.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$check.AutoSize = $true
$check.Location = New-Object System.Drawing.Point(20, 26)
$check.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($check)

$status = New-Object System.Windows.Forms.Label
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(22, 66)
$status.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$status.ForeColor = [System.Drawing.Color]::FromArgb(160, 165, 175)
$form.Controls.Add($status)

$hint = New-Object System.Windows.Forms.Label
$hint.AutoSize = $false
$hint.Size = New-Object System.Drawing.Size(320, 32)
$hint.Location = New-Object System.Drawing.Point(22, 94)
$hint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$hint.ForeColor = [System.Drawing.Color]::FromArgb(120, 125, 135)
$hint.Text = '与输入框里的 /away 是同一个开关。关闭窗口不影响。'
$form.Controls.Add($hint)

$script:suppress = $false
function Sync-FromFile {
  $state = Read-State
  $enabled = ($state -ne $null -and $state.enabled -eq $true)
  $script:suppress = $true
  $check.Checked = $enabled
  $script:suppress = $false
  if ($enabled) {
    $when = if ($state.updatedAt) { ([datetime]$state.updatedAt).ToLocalTime().ToString('MM-dd HH:mm') } else { '未知' }
    $status.Text = "🌙 已开启（$when 更新）"
    $status.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 150)
  } else {
    $status.Text = '☀️ 已关闭'
    $status.ForeColor = [System.Drawing.Color]::FromArgb(160, 165, 175)
  }
}

$check.add_CheckedChanged({
  if ($script:suppress) { return }
  Write-State $check.Checked
  Sync-FromFile
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.add_Tick({ Sync-FromFile })
$timer.Start()

$form.add_Shown({
  Sync-FromFile
  $form.Activate()
})

[void]$form.ShowDialog()
