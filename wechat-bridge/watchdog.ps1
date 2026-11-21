# 微信桥接守护进程
# 每 30 秒检查一次桥接是否活着：进程没了 / 心跳停了超过 3 分钟，就自动拉起。
# 由 start-all.ps1 启动，登录自启；也可以手动跑。
$ErrorActionPreference = 'Continue'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bridge = Join-Path $Root 'bridge.ps1'
$BridgeLock = Join-Path $Root 'bridge.lock'
$Heartbeat = Join-Path $Root 'bridge.heartbeat'
$WatchLock = Join-Path $Root 'watchdog.lock'
$LogFile = Join-Path $Root 'watchdog.log'
$Ps = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'
$StaleSeconds = 180

function Log([string]$message) {
  $line = "{0} {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $message
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

# 单实例
if (Test-Path -LiteralPath $WatchLock) {
  $existing = Get-Content -LiteralPath $WatchLock -Raw -ErrorAction SilentlyContinue
  if ($existing -and (Get-Process -Id ([int]$existing.Trim()) -ErrorAction SilentlyContinue)) {
    Log "watchdog already running (pid $($existing.Trim())), exit"
    exit 0
  }
}
Set-Content -LiteralPath $WatchLock -Value $PID -Encoding UTF8
Log "=== watchdog start (pid $PID) ==="

function Get-BridgePid {
  if (-not (Test-Path -LiteralPath $BridgeLock)) { return $null }
  $raw = Get-Content -LiteralPath $BridgeLock -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return $null }
  $value = 0
  if (-not [int]::TryParse($raw.Trim(), [ref]$value)) { return $null }
  return $value
}

function Test-Heartbeat {
  if (-not (Test-Path -LiteralPath $Heartbeat)) { return $false }
  $age = ((Get-Date) - (Get-Item -LiteralPath $Heartbeat).LastWriteTime).TotalSeconds
  return ($age -le $StaleSeconds)
}

while ($true) {
  try {
    $reason = $null
    $bridgePid = Get-BridgePid

    if (-not $bridgePid) {
      $reason = 'no bridge.lock'
    }
    elseif (-not (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue)) {
      $reason = "bridge pid $bridgePid is gone"
    }
    elseif (-not (Test-Heartbeat)) {
      # 刚启动的进程还没写心跳属正常：进程启动时间晚于心跳时间就跳过
      $procStart = (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue).StartTime
      $beatTime = if (Test-Path -LiteralPath $Heartbeat) { (Get-Item -LiteralPath $Heartbeat).LastWriteTime } else { [datetime]::MinValue }
      if (-not $procStart -or $procStart -le $beatTime) {
        $reason = "heartbeat stale (>${StaleSeconds}s)"
        Stop-Process -Id $bridgePid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
      }
    }

    if ($reason) {
      Log "restarting bridge: $reason"
      Remove-Item -LiteralPath $BridgeLock -Force -ErrorAction SilentlyContinue
      Start-Process -FilePath $Ps `
        -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$Bridge`"") `
        -WindowStyle Hidden
      Start-Sleep -Seconds 6
      $newPid = Get-BridgePid
      Log "bridge restarted, pid=$newPid"
    }
  } catch {
    Log "watchdog error: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds 30
}
