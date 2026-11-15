# 微信通知通道（Windows / 微信 PC 客户端）
# 通过 UI 自动化往指定会话发一条文字消息，不需要公众号、不逆向协议。
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File notify-wechat.ps1 -Text "内容" [-Chat 文件传输助手]
#
# 建议在 dsh-plugin-away 里这样配置:
#   notify:
#     mode: command
#     command: 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
#     args: ['-NoProfile','-ExecutionPolicy','Bypass','-File','<本文件路径>','-Text','{{message}}']
param(
  [Parameter(Mandatory = $true)][string]$Text,
  [string]$Chat = '文件传输助手',
  [string]$ProcessNamePattern = 'Weixin',
  [int]$ChunkSize = 1400
)

$ErrorActionPreference = 'Continue'
$Mark = '【DSH】'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

$sig = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class Wx {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static List<IntPtr> Candidates(uint[] pids) {
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
  public static void Front(IntPtr h) { ShowWindow(h, 9); SetForegroundWindow(h); }
}
'@
if (-not ('Wx' -as [type])) { Add-Type -TypeDefinition $sig -Language CSharp }

function Get-MainWindow {
  $pids = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match $ProcessNamePattern } |
    ForEach-Object { [uint32]$_.Id })
  if ($pids.Count -eq 0) { return $null }
  foreach ($h in [Wx]::Candidates($pids)) {
    try { $el = $AE::FromHandle($h) } catch { continue }
    if ($el -and $el.Current.ClassName -eq 'mmui::MainWindow') { return $el }
  }
  return $null
}

function Open-Chat($win, [string]$name) {
  $list = $win.FindFirst($TS::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'mmui::XTableView')))
  if (-not $list) { return $false }
  foreach ($cell in $list.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($cell.Current.Name -like "$name*") {
      try { $cell.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { }
      Start-Sleep -Milliseconds 700
      return $true
    }
  }
  return $false
}

$win = Get-MainWindow
if (-not $win) {
  [Console]::Error.WriteLine('[notify-wechat] 微信主窗口未找到：请确认微信已登录且没有退出')
  exit 2
}
[void](Open-Chat $win $Chat)

$chunks = @()
if ($Text.Length -le $ChunkSize) { $chunks = @($Text) }
else {
  $i = 0
  while ($i -lt $Text.Length) {
    $len = [Math]::Min($ChunkSize, $Text.Length - $i)
    $chunks += $Text.Substring($i, $len)
    $i += $len
  }
}

$sent = 0
for ($j = 0; $j -lt $chunks.Count; $j++) {
  $prefix = if ($chunks.Count -eq 1) { "$Mark " } else { "$Mark($($j+1)/$($chunks.Count)) " }
  $payload = $prefix + $chunks[$j]
  $ok = $false
  for ($try = 1; $try -le 3 -and -not $ok; $try++) {
    try {
      [Wx]::Front([IntPtr]$win.Current.NativeWindowHandle)
      Start-Sleep -Milliseconds 500
      $edit = $win.FindFirst($TS::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'mmui::ChatInputField')))
      if (-not $edit) { Start-Sleep -Milliseconds 800; continue }
      $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($payload)
      Start-Sleep -Milliseconds 350
      [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
      Start-Sleep -Milliseconds 700
      $ok = $true
    } catch {
      [Console]::Error.WriteLine("[notify-wechat] 第 $try 次尝试失败: $($_.Exception.Message)")
      Start-Sleep -Milliseconds 800
    }
  }
  if ($ok) { $sent++ }
}

if ($sent -lt $chunks.Count) {
  [Console]::Error.WriteLine("[notify-wechat] 只发出了 $sent/$($chunks.Count) 段")
  exit 1
}
exit 0
