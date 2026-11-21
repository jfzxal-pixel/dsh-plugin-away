# WeChat <-> DeepSeek Harness bridge
# 手机微信「文件传输助手」发消息 -> 本机 dsh headless 执行 -> 结果回到微信
param(
  [string]$ChatName = '文件传输助手',
  [int]$PollMs = 2000,
  [int]$TimeoutMin = 20,
  [bool]$RequireAwayMode = $false
)

$ErrorActionPreference = 'Continue'
$ReplyMark = '【DSH】'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile = Join-Path $Root 'state.json'
$LogFile = Join-Path $Root 'bridge.log'
# 机器相关的路径全部走 bridge.config.ps1 / 环境变量，不在代码里写死
$ConfigFile = Join-Path $Root 'bridge.config.json'
if (Test-Path -LiteralPath $ConfigFile) {
  try {
    $cfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.DshCmd) { $DshCmd = $cfg.DshCmd }
    if ($cfg.PatchFile) { $PatchFile = $cfg.PatchFile }
    if ($cfg.Workspace) { $Workspace = $cfg.Workspace }
    if ($cfg.NodeExe) { $env:DSH_DESKTOP_NODE_EXECUTABLE = $cfg.NodeExe }
  } catch {
    Log "cannot read bridge.config.json: $($_.Exception.Message)"
  }
}
if (-not $DshCmd) { $DshCmd = if ($env:DSH_CMD) { $env:DSH_CMD } else { 'dsh' } }
if (-not $PatchFile) { $PatchFile = $env:DSH_HEADLESS_PATCH }
if (-not $Workspace) { $Workspace = if ($env:DSH_WORKSPACE) { $env:DSH_WORKSPACE } else { (Get-Location).Path } }
if ($NodeExe) { $env:DSH_DESKTOP_NODE_EXECUTABLE = $NodeExe }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

$win32 = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WxW {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  // 微信 4.x 的 Win32 窗口类名被混淆，只能按「进程 + 面积最大的窗口」定位
  public static List<IntPtr> All(uint[] pids) {
    var res = new List<IntPtr>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      foreach (var p in pids) {
        if (p == pid) {
          RECT r; GetWindowRect(h, out r);
          if ((r.R - r.L) > 200 && (r.B - r.T) > 200) res.Add(h);
        }
      }
      return true;
    }, IntPtr.Zero);
    return res;
  }
  public static void ClickAt(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(60);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
  }
  public static void BringToFront(IntPtr h) {
    ShowWindow(h, 9);      // SW_RESTORE
    SetForegroundWindow(h);
  }
}
'@
if (-not ('WxW' -as [type])) { Add-Type -TypeDefinition $win32 -Language CSharp }

function Log([string]$msg) {
  $line = "{0} {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
  Write-Host $line
}

function Get-State {
  if (Test-Path -LiteralPath $StateFile) {
    try {
      $o = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $names = @($o.PSObject.Properties.Name)
      if ($names -notcontains 'sig') { $o | Add-Member -NotePropertyName sig -NotePropertyValue '' -Force }
      if ($names -notcontains 'tail') { $o | Add-Member -NotePropertyName tail -NotePropertyValue @() -Force }
      if ($names -notcontains 'sessionId') { $o | Add-Member -NotePropertyName sessionId -NotePropertyValue $null -Force }
      return $o
    } catch { }
  }
  return [pscustomobject]@{ sessionId = $null; tail = @(); sig = '' }
}
function Save-State($s) {
  $s | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Get-WeixinPids {
  $p = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'Weixin' })
  return @($p | ForEach-Object { [uint32]$_.Id })
}

function Get-WxWindow {
  $pids = Get-WeixinPids
  if ($pids.Count -eq 0) { return $null }

  # 优先：用户单独弹出的会话窗口（微信的「独立窗口」）。它固定就是目标会话，
  # 用它收发完全不会碰到主窗口里正在聊的对话。
  foreach ($h in [WxW]::All($pids)) {
    try { $el = $AE::FromHandle($h) } catch { continue }
    if ($el -and $el.Current.ClassName -eq 'mmui::ChatSingleWindow') {
      if ($el.Current.Name -eq $ChatName) { return $el }
    }
  }

  # 退回主窗口（里面需要切换会话）
  foreach ($h in [WxW]::All($pids)) {
    try { $el = $AE::FromHandle($h) } catch { continue }
    if ($el -and $el.Current.ClassName -eq 'mmui::MainWindow') { return $el }
  }
  return $null
}

function Test-IsPopupWindow($win) {
  return ($win -and $win.Current.ClassName -eq 'mmui::ChatSingleWindow')
}

function Get-ByClass($root, [string]$class) {
  $c = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, $class)
  return $root.FindFirst($TS::Descendants, $c)
}

function Get-MessageItems($win) {
  $list = Get-ByClass $win 'mmui::RecyclerListView'
  if (-not $list) { return @() }
  $coll = $list.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)
  $out = @()
  foreach ($k in $coll) { $out += $k }
  return $out
}

function Test-AwayMode {
  # 离开模式的状态文件由 dsh-plugin-away 维护；读不到就当作关闭
  $home_ = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
  $file = Join-Path $home_ 'away-mode.json'
  if (-not (Test-Path -LiteralPath $file)) { return $false }
  try { return ((Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).enabled -eq $true) } catch { return $false }
}

function Get-OpenChatName($win) {
  if (Test-IsPopupWindow $win) { return $win.Current.Name }
  $title = Get-ByClass $win 'mmui::ChatTitleBarChatSingleView'
  if (-not $title) { return '' }
  $txt = $title.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text)))
  if ($txt) { return $txt.Current.Name }
  return ''
}

function Switch-ToChat($win, [string]$name) {
  if (Test-IsPopupWindow $win) { return ($win.Current.Name -eq $name) }
  if ((Get-OpenChatName $win) -eq $name) { return $true }
  $sessList = Get-ByClass $win 'mmui::XTableView'
  if (-not $sessList) { return $false }

  $cell = $null
  foreach ($c in $sessList.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($c.Current.Name -like "$name*") { $cell = $c; break }
  }
  if (-not $cell) { return $false }

  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      # 1) 选中（列表项语义上更正确）
      $sel = $null
      if ($cell.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sel)) {
        $sel.Select()
      } else {
        # 2) 退回 Invoke
        $inv = $null
        if ($cell.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$inv)) {
          $inv.Invoke()
        } else {
          # 3) 最后手段：真实鼠标点击（微信 4.x 对这两个 pattern 都不响应）
          $r = $cell.Current.BoundingRectangle
          if ($r.Width -gt 0 -and $r.Height -gt 0) {
            [WxW]::ClickAt([int]($r.Left + $r.Width / 2), [int]($r.Top + $r.Height / 2))
          }
        }
      }
    } catch { }

    Start-Sleep -Milliseconds (400 + $attempt * 250)
    if ((Get-OpenChatName $win) -eq $name) { return $true }

    # 选不中就用鼠标点（有些行 SelectionItem 无效）
    if ($attempt -eq 2) {
      try {
        $r = $cell.Current.BoundingRectangle
        if ($r.Width -gt 0 -and $r.Height -gt 0) {
          [WxW]::ClickAt([int]($r.Left + $r.Width / 2), [int]($r.Top + $r.Height / 2))
          Start-Sleep -Milliseconds 600
          if ((Get-OpenChatName $win) -eq $name) { return $true }
        }
      } catch { }
    }
  }
  return $false
}

function Get-SessionSignature($win, [string]$name) {
  if (Test-IsPopupWindow $win) {
    $items = Get-MessageItems $win
    return "popup:" + $items.Count
  }
  # 左侧会话列表里那一行的文本（含最新消息预览），用来判断有没有新消息，
  # 这样就不用每隔 2 秒把用户的聊天窗口抢过来。
  $list = Get-ByClass $win 'mmui::XTableView'
  if (-not $list) { return '' }
  foreach ($cell in $list.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($cell.Current.Name -like "$name*") { return $cell.Current.Name }
  }
  return ''
}

function Submit-Input($win, $edit) {
  # 三种提交方式逐级降级，每步都回读输入框确认是否真的发出去
  $vp = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)

  try { $edit.SetFocus() } catch { }
  Start-Sleep -Milliseconds 200
  try { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') } catch { }
  Start-Sleep -Milliseconds 450
  if ($vp.Current.Value -eq '') { return $true }

  $btn = $null
  try {
    $cond = New-Object System.Windows.Automation.AndCondition(
      (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, '发送')),
      (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
    $btn = $win.FindFirst($TS::Descendants, $cond)
  } catch { }

  if ($btn) {
    try { $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { }
    Start-Sleep -Milliseconds 450
    if ($vp.Current.Value -eq '') { return $true }

    try {
      $r = $btn.Current.BoundingRectangle
      if ($r.Width -gt 0 -and $r.Height -gt 0) {
        [WxW]::ClickAt([int]($r.Left + $r.Width / 2), [int]($r.Top + $r.Height / 2))
      }
    } catch { }
    Start-Sleep -Milliseconds 450
    if ($vp.Current.Value -eq '') { return $true }
  }
  return $false
}

function Send-WxText($win, [string]$text, [bool]$RestorePrevious = $true) {
  try {
    $h = [IntPtr]$win.Current.NativeWindowHandle
    if ($h -ne [IntPtr]::Zero) { [WxW]::BringToFront($h) }
    Start-Sleep -Milliseconds 300

    $previous = Get-OpenChatName $win
    if (-not (Switch-ToChat $win $ChatName)) {
      Log "SEND ABORTED: cannot open [$ChatName] (currently [$previous])"
      return $false
    }
    # 切换后、输入前再确认一次，防止期间被打断
    if ((Get-OpenChatName $win) -ne $ChatName) {
      Log "SEND ABORTED: chat changed right before typing (currently [$(Get-OpenChatName $win)])"
      return $false
    }

    $edit = Get-ByClass $win 'mmui::ChatInputField'
    if (-not $edit) { return $false }
    $vp = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $vp.SetValue($text)
    Start-Sleep -Milliseconds 250
    if (-not (Submit-Input $win $edit)) {
      Log 'SEND FAILED: input still holds text, clearing'
      try { $vp.SetValue('') } catch { }
      return $false
    }
    Start-Sleep -Milliseconds 300

    # 发完切回用户原来的会话，不打断他与别人的聊天
    if ($RestorePrevious -and $previous -and $previous -ne $ChatName) {
      if (-not (Switch-ToChat $win $previous)) { Log "restore to [$previous] failed" }
      Start-Sleep -Milliseconds 250
    }
    return $true
  } catch {
    Log "Send failed: $($_.Exception.Message)"
    return $false
  }
}

function Send-Reply($win, [string]$text) {
  $limit = 1400
  $chunks = @()
  if ($text.Length -le $limit) { $chunks = @($text) }
  else {
    $i = 0
    while ($i -lt $text.Length) {
      $len = [Math]::Min($limit, $text.Length - $i)
      $chunks += $text.Substring($i, $len)
      $i += $len
    }
  }
  $n = $chunks.Count
  $allOk = $true
  for ($j = 0; $j -lt $n; $j++) {
    $prefix = if ($n -eq 1) { $ReplyMark } else { "$ReplyMark($($j+1)/$n) " }
    $ok = Send-WxText $win ($prefix + $chunks[$j])
    if (-not $ok) { $allOk = $false }
    Start-Sleep -Milliseconds 700
  }
  return $allOk
}

function Invoke-Dsh([string]$task, [string]$sessionId) {
  $runsDir = Join-Path $Root 'runs'
  if (-not (Test-Path -LiteralPath $runsDir)) { New-Item -ItemType Directory -Path $runsDir | Out-Null }
  $outFile = Join-Path $Root 'run.out'
  $errFile = Join-Path $Root 'run.err'
  $taskFile = Join-Path $Root 'task.txt'
  # 清掉上一轮的输出，避免子进程没写文件时把旧回复当成本轮结果发出去
  Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
  # 任务文本写文件后经 stdin 送入，避免任何引号转义问题
  [System.IO.File]::WriteAllText($taskFile, ("【微信指令】" + $task), (New-Object System.Text.UTF8Encoding($false)))
  $cmdArgs = "headless"
  if ($PatchFile) { $cmdArgs += " --patch `"$PatchFile`"" }
  $cmdArgs += " --json"
  if ($sessionId) { $cmdArgs += " --session-id $sessionId" }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'cmd.exe'
  $psi.Arguments = "/c `"`"$DshCmd`" $cmdArgs - < `"$taskFile`" > `"$outFile`" 2> `"$errFile`"`""
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $false
  $psi.RedirectStandardError = $false
  $psi.RedirectStandardOutput = $false
  $psi.WorkingDirectory = $Workspace
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  # 等待期间持续刷新心跳：否则 watchdog 会以为桥接卡死，把正在跑任务的桥接杀掉，
  # 这一轮的回复就永远发不出去（历史上丢消息就是这么来的）。
  $deadline = (Get-Date).AddMinutes($TimeoutMin)
  while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
    try { [System.IO.File]::WriteAllText($heartbeat, (Get-Date).ToString('o')) } catch { }
    Start-Sleep -Seconds 5
  }
  if (-not $p.HasExited) {
    try { $p.Kill($true) } catch { }
    return [pscustomobject]@{ ok = $false; text = "任务超过 $TimeoutMin 分钟，已中止。"; sessionId = $sessionId }
  }
  $raw = ''
  if (Test-Path -LiteralPath $outFile) {
    $raw = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8
    try {
      $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
      Copy-Item -LiteralPath $outFile -Destination (Join-Path $runsDir "$stamp.json") -Force
    } catch { }
  }
  if (-not $raw) {
    $e = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 } else { '' }
    return [pscustomobject]@{ ok = $false; text = "执行失败：" + $e.Trim(); sessionId = $sessionId }
  }
  $sid = $sessionId
  $final = $null
  $texts = @()
  foreach ($line in ($raw -split "`r?`n")) {
    if (-not $line.Trim()) { continue }
    try { $ev = $line | ConvertFrom-Json } catch { continue }
    switch ($ev.type) {
      'session' { if ($ev.sessionId) { $sid = $ev.sessionId } }
      'text' { if ($ev.text) { $texts += $ev.text } }
      'final' { $final = $ev.text }
    }
  }
  if (-not $final) { $final = ($texts -join '') }
  if (-not $final) { $final = '(没有返回内容)' }
  return [pscustomobject]@{ ok = $true; text = $final; sessionId = $sid }
}

# ---------- main ----------
$lock = Join-Path $Root 'bridge.lock'
if (Test-Path -LiteralPath $lock) {
  $old = Get-Content -LiteralPath $lock -Raw -ErrorAction SilentlyContinue
  if ($old -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) {
    Log "another bridge instance running (pid $old), exit"
    exit 1
  }
}
Set-Content -LiteralPath $lock -Value $PID -Encoding UTF8

Log "=== bridge start (chat=$ChatName, poll=${PollMs}ms) ==="
$state = Get-State
$queue = New-Object System.Collections.Queue
$busy = $false
$initDone = $false
$heartbeat = Join-Path $Root 'bridge.heartbeat'
$lastBeat = Get-Date
try { [System.IO.File]::WriteAllText($heartbeat, (Get-Date).ToString('o')) } catch { }
$script:lastWxOpen = (Get-Date).AddHours(-1)
$pendingFile = Join-Path $Root 'pending-reply.txt'

while ($true) {
  if (((Get-Date) - $lastBeat).TotalSeconds -ge 20) {
  try { [System.IO.File]::WriteAllText($heartbeat, (Get-Date).ToString('o')) } catch { }
    $lastBeat = Get-Date
  }
  # 离开模式没开：不切换、不置前、不发消息，完全不动微信窗口
  if (-not (Test-AwayMode)) {
    if ($script:lastAway -ne $false) { Log 'away mode OFF: wechat windows untouched'; $script:lastAway = $false }
    $initDone = $false
    $script:lastMode = $null
    Start-Sleep -Milliseconds $PollMs
    continue
  }
  if ($script:lastAway -ne $true) { Log 'away mode ON: watching wechat'; $script:lastAway = $true }

  try {
    $win = Get-WxWindow
    if (-not $win) {
      # 微信被关成托盘/退出了就拉起来，别干等
      if ($WeixinExe -and (Test-Path -LiteralPath $WeixinExe) -and ((Get-Date) - $script:lastWxOpen).TotalSeconds -ge 120) {
        $script:lastWxOpen = Get-Date
        try { Start-Process -FilePath $WeixinExe -ErrorAction Stop; Log 'wechat not running, launched it' } catch { Log "launch wechat failed: $($_.Exception.Message)" }
        Start-Sleep -Seconds 5
        $win = Get-WxWindow
      }
      if (-not $win) {
        Log 'wechat window not found; waiting'
        Start-Sleep -Seconds 5
        continue
      }
    }
    $mode = if (Test-IsPopupWindow $win) { 'popup(独立窗口)' } else { 'main(主窗口·需切换)' }
    if ($script:lastMode -ne $mode) { Log "window mode: $mode"; $script:lastMode = $mode }

    # 主窗口才需要看会话列表；独立窗口直接读
    $sig = Get-SessionSignature $win $ChatName
    $needsRead = (Test-IsPopupWindow $win) -or (-not $initDone) -or ($sig -ne $state.sig) -or ($sig -eq '')

    if ($needsRead) {
      $prevChat = Get-OpenChatName $win
      if (-not (Switch-ToChat $win $ChatName)) {
        $now = Get-Date
        if (-not $script:lastSwitchWarn -or ($now - $script:lastSwitchWarn).TotalSeconds -ge 30) {
          Log "switch to [$ChatName] failed, current=[$(Get-OpenChatName $win)], sig-len=$($sig.Length)"
          $script:lastSwitchWarn = $now
        }
        Start-Sleep -Seconds 2
        continue
      }
      Start-Sleep -Milliseconds 350

      $items = Get-MessageItems $win
      $texts = @()
      foreach ($it in $items) {
        if ($it.Current.ClassName -eq 'mmui::ChatTextItemView' -and $it.Current.Name) {
          $texts += $it.Current.Name
        }
      }

      if (-not $initDone) {
        if ($texts.Count -gt 0) {
          $state.tail = @($texts | Select-Object -Last 60)
          $state.sig = $sig
          Save-State $state
          $initDone = $true
          Log "baseline set, history items=$($texts.Count)"
        }
      }
      elseif ($texts.Count -gt 0) {
        $prevTail = @()
        if ($state.tail) { $prevTail = @($state.tail) }

        $overlap = 0
        $maxK = [Math]::Min($prevTail.Count, $texts.Count)
        for ($cand = $maxK; $cand -ge 1; $cand--) {
          $match = $true
          for ($j = 0; $j -lt $cand; $j++) {
            if ($prevTail[$prevTail.Count - $cand + $j] -ne $texts[$j]) { $match = $false; break }
          }
          if ($match) { $overlap = $cand; break }
        }

        if ($prevTail.Count -eq 0) {
          Log "baseline was empty, adopting current list ($($texts.Count) items) without executing"
        }
        elseif ($overlap -eq 0) {
          Log "no overlap (prev=$($prevTail.Count) now=$($texts.Count)), cursor reset"
        }
        elseif ($overlap -lt $texts.Count) {
          $new = @($texts[$overlap..($texts.Count - 1)])
          foreach ($t in $new) {
            if ($t -like "$ReplyMark*") { continue }
            if ($t.Trim()) { $queue.Enqueue($t) }
          }
          if ($new.Count -gt 0) { Log "detected $($new.Count) new message(s), overlap=$overlap" }
        }

        $state.tail = @($texts | Select-Object -Last 60)
        $state.sig = $sig
        Save-State $state
      }

      # 切回用户原来的聊天
      if ($prevChat -and $prevChat -ne $ChatName) { [void](Switch-ToChat $win $prevChat) }
    }

    if ($RequireAwayMode -and $queue.Count -gt 0) {
      $awayFile = Join-Path $env:USERPROFILE '.dsh\away-mode.json'
      $awayOn = $false
      if (Test-Path -LiteralPath $awayFile) {
        try { $awayOn = ((Get-Content -LiteralPath $awayFile -Raw -Encoding UTF8 | ConvertFrom-Json).enabled -eq $true) } catch { }
      }
      if (-not $awayOn) {
        while ($queue.Count -gt 0) { $dropped = $queue.Dequeue(); Log "SKIP (away off): $($dropped.Substring(0,[Math]::Min(40,$dropped.Length)))" }
      }
    }

    if (-not $busy -and $queue.Count -gt 0) {
      $task = $queue.Dequeue()
      $busy = $true
      Log "RUN: $($task.Substring(0, [Math]::Min(80, $task.Length)))"
      Send-WxText $win "$ReplyMark 收到，开始处理…" | Out-Null
      $r = Invoke-Dsh $task $state.sessionId
      if ($r.sessionId) { $state.sessionId = $r.sessionId; Save-State $state }
      $body = $r.text
      if ($body.Length -gt 6000) { $body = $body.Substring(0, 6000) + "`n…（内容过长已截断）" }
      if (Send-Reply $win $body) { Log "DONE ($($body.Length) chars)" }
      else { Log "DONE but reply NOT sent ($($body.Length) chars)" }
      $busy = $false
    }
  } catch {
    Log "loop error: $($_.Exception.Message)"
  }
  Start-Sleep -Milliseconds $PollMs
}
