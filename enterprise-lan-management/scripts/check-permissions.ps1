<#
.SYNOPSIS  金网通 · 权限检测与一键修复工具 V2
.DESCRIPTION
  检测当前用户权限、执行策略、防火墙、网络发现等是否满足金网通运行条件，
  对不满足的项提供一键修复命令。
#>
param(
  [switch]$Fix,       # 自动修复
  [switch]$Json       # JSON 输出
)

$results = @()
function Add-Check($name, $ok, $detail, $fixCmd) {
  $results += @{name=$name;ok=$ok;detail=$detail;fixCmd=$fixCmd}
}

# 1. 管理员权限
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
Add-Check "管理员权限" $isAdmin "当前$(if($isAdmin){'是'}else{'不是'})管理员" "右键 PowerShell → 以管理员身份运行"

# 2. 执行策略
$ep = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
$epOk = $ep -in @("RemoteSigned","Unrestricted","Bypass")
Add-Check "PowerShell执行策略" $epOk "当前: $ep" "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force"

# 3. PS 版本
$psVer = $PSVersionTable.PSVersion.Major
Add-Check "PowerShell版本(>=2.0)" ($psVer -ge 2) "当前: PS $($PSVersionTable.PSVersion)" ""

# 4. 网络发现
try {
  $fwRule = Get-NetFirewallRule -DisplayName "网络发现*" -ErrorAction Stop | Where-Object { $_.Enabled -eq 'True' }
  $ndOk = ($fwRule -ne $null)
} catch { $ndOk = $false }
Add-Check "网络发现" $ndOk "防火墙网络发现规则状态" "netsh advfirewall firewall set rule group=`"网络发现`" new enable=Yes"

# 5. 文件共享防火墙
try {
  $smbRule = Get-NetFirewallRule -DisplayName "文件和打印机共享*" -ErrorAction Stop | Where-Object { $_.Enabled -eq 'True' }
  $smbOk = ($smbRule -ne $null)
} catch { $smbOk = $false }
Add-Check "文件共享防火墙" $smbOk "SMB端口445允许" "netsh advfirewall firewall set rule group=`"文件和打印机共享`" new enable=Yes"

# 6. WinRM（远程管理）
$winrmOk = (Get-Service WinRM -ErrorAction SilentlyContinue).Status -eq "Running"
Add-Check "WinRM远程管理" $winrmOk "WinRM服务状态" "Enable-PSRemoting -Force"

# 7. .NET Framework
$netVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue).Version
$netOk = $netVer -ne $null
Add-Check ".NET Framework 4.x" $netOk "版本: $netVer" ""

# 8. WMI 可用
try { $null = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop; $wmiOk = $true } catch { $wmiOk = $false }
Add-Check "WMI服务" $wmiOk "Windows Management Instrumentation" "sc config winmgmt start= auto; sc start winmgmt"

# 输出
if ($Json) {
  $results | ConvertTo-Json -Compress
} else {
  Write-Host "`n===== 金网通 环境检测报告 =====" -ForegroundColor Cyan
  Write-Host ""
  $allOk = $true
  foreach ($r in $results) {
    $icon = if ($r.ok) { "[OK]" } else { "[!!]" }
    $color = if ($r.ok) { "Green" } else { "Red" }
    Write-Host "$icon " -NoNewline -ForegroundColor $color
    Write-Host "$($r.name): $($r.detail)" -ForegroundColor $color
    if (-not $r.ok) { $allOk = $false }
  }
  Write-Host ""

  if ($allOk) {
    Write-Host "结果: 全部通过，可正常运行金网通" -ForegroundColor Green
  } else {
    Write-Host "结果: 存在不满足项" -ForegroundColor Red
    Write-Host ""

    if ($Fix) {
      Write-Host "正在自动修复..." -ForegroundColor Yellow
      foreach ($r in $results) {
        if (-not $r.ok -and $r.fixCmd) {
          Write-Host "  执行: $($r.name) -> $($r.fixCmd)" -ForegroundColor Cyan
          try { Invoke-Expression $r.fixCmd; Write-Host "    OK" -ForegroundColor Green } catch { Write-Host "    ERR: $_" -ForegroundColor Red }
        }
      }
    } else {
      Write-Host "自动修复命令（请以管理员运行，或加 -Fix 参数自动执行）：" -ForegroundColor Yellow
      foreach ($r in $results) {
        if (-not $r.ok -and $r.fixCmd) {
          Write-Host "  $($r.name):" -ForegroundColor White
          Write-Host "    $($r.fixCmd)" -ForegroundColor Gray
        }
      }
    }
  }
}