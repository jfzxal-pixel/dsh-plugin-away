# 启动微信桥接的守护进程（它会在需要时自己拉起桥接）。
# 登录时由启动文件夹调用；也可手动执行。
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Ps = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'
$Watch = Join-Path $Root 'watchdog.ps1'
$Lock = Join-Path $Root 'watchdog.lock'

$running = $false
if (Test-Path $Lock) {
  $old = (Get-Content -LiteralPath $Lock -Raw -ErrorAction SilentlyContinue)
  if ($old -and (Get-Process -Id ([int]$old.Trim()) -ErrorAction SilentlyContinue)) { $running = $true }
}
if (-not $running) {
  Start-Process -FilePath $Ps -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$Watch`"") -WindowStyle Hidden
}