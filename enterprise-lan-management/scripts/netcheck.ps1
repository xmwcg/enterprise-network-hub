<#
.SYNOPSIS  金网通 · 网络体检+自动修复 V2
.DESCRIPTION
  检测网络状况，发现问题时提供自动修复选项（需用户确认），
  也可加 -AutoFix 完全自动修复。
.PARAMETER ScanOnly  仅扫描不修复（默认）
.PARAMETER Fix       扫描后交互式确认修复
.PARAMETER AutoFix   自动修复所有问题（不询问）
.PARAMETER Json      JSON 输出
#>
param([switch]$Fix, [switch]$AutoFix, [switch]$Json, [string]$FileServerHost)

. .\lib-init.ps1
. .\lib-audit.ps1

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

$checks = @()
function Add-Check($n,$ok,$detail,$fix,$fixDesc) {
  $checks += @{name=$n;ok=$ok;detail=$detail;fix=$fix;fixDesc=$fixDesc}
}

# 1. 网络类别
$prof = Get-NetConnectionProfile -ErrorAction SilentlyContinue
$netOk = ($prof -and $prof.NetworkCategory -eq 'Private')
Add-Check "网络类别" $netOk "$(if($prof){$prof.NetworkCategory}else{'未知'})" {
  Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
} "将网络改为「专用网络」（允许发现和文件共享）"

# 2. IP
$ip = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notmatch '^127\.|^169\.254\.'} | Select-Object -First 1
if (-not $ip) { Add-Check "IP地址" $false "无有效IPv4" { ipconfig /renew } "尝试 DHCP 续租" }
else {
  $conflict = $false
  $ownMac = (Get-NetAdapter | Where-Object {$_.Status -eq 'Up'}).MacAddress -replace '-',':' -replace '(.{2})','$1-' -replace '-$',''
  $nb = Get-NetNeighbor -IPAddress $ip.IPAddress -ErrorAction SilentlyContinue | Where-Object {$_.State -ne 'Unreachable'}
  foreach($n in $nb){if($n.LinkLayerAddress -ne $ownMac){$conflict=$true}}
  Add-Check "IP地址" (-not $conflict) "$($ip.IPAddress)$(if($conflict){' 冲突!'})" { ipconfig /release; ipconfig /renew } "释放并重新获取IP"
}

# 3. 网关
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
$gwOk = $false; if($gw){$gwOk = (Test-Connection $gw -Count 1 -Quiet)}
Add-Check "网关可达" $gwOk "网关=$gw $(if($gwOk){'可达'}else{'不通'})" { netsh interface ip reset; ipconfig /renew } "重置网络堆栈+重新续租"

# 4. DNS
$dnsOk = $false; try{$null=Resolve-DnsName 'baidu.com' -ErrorAction Stop; $dnsOk=$true}catch{}
Add-Check "DNS解析" $dnsOk "baidu.com解析测试" { ipconfig /flushdns; netsh winsock reset } "刷新DNS缓存+重置Winsock"

# 5. SMB 文件共享
$smbOk = (Get-NetTCPConnection -LocalPort 445 -ErrorAction SilentlyContinue | Where-Object {$_.State -eq 'Listen'}) -ne $null
Add-Check "SMB文件共享" $smbOk "端口445监听" {
  Get-Service LanmanServer | Set-Service -StartupType Automatic -Status Running
  netsh advfirewall firewall set rule group="文件和打印机共享" new enable=Yes
} "启用SMB服务+开放防火墙445端口"

# 6. RDP 远程桌面
$rdpOk = (Get-NetTCPConnection -LocalPort 3389 -ErrorAction SilentlyContinue | Where-Object {$_.State -eq 'Listen'}) -ne $null
Add-Check "远程桌面" $rdpOk "端口3389监听" {
  Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
  Enable-NetFirewallRule -DisplayGroup "远程桌面"
} "启用远程桌面+开放防火墙3389"

# 7. 网络发现
$ndOk = $false; try{$r=Get-NetFirewallRule -DisplayGroup "网络发现" -ErrorAction Stop | Where-Object {$_.Enabled -eq 'True'};$ndOk=($r -ne $null)}catch{}
Add-Check "网络发现" $ndOk "防火墙规则" { netsh advfirewall firewall set rule group="网络发现" new enable=Yes } "启用网络发现防火墙规则"

# 8. WinRM
$wr = Get-Service WinRM -ErrorAction SilentlyContinue
$wrOk = ($wr.Status -eq 'Running')
Add-Check "WinRM远程管理" $wrOk "$(if($wr){$wr.Status}else{'未安装'})" { Enable-PSRemoting -Force } "启用PowerShell远程管理"

# 输出
$warnCount = ($checks | Where-Object {-not $_.ok}).Count
if ($Json) {
  @{time=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss');hostname=$env:COMPUTERNAME;checks=$checks;warnings=$warnCount} | ConvertTo-Json -Depth 4 -Compress
} else {
  Write-Host "`n===== 金网通 网络体检报告 =====" -ForegroundColor Cyan
  Write-Host ""
  foreach ($c in $checks) {
    $icon = if($c.ok){"[PASS]"}else{"[FAIL]"}
    $col = if($c.ok){"Green"}else{"Red"}
    Write-Host "$icon $($c.name): $($c.detail)" -ForegroundColor $col
  }
  Write-Host "`n问题数: $warnCount" -ForegroundColor $(if($warnCount -eq 0){"Green"}else{"Red"})

  if ($warnCount -gt 0 -and (($Fix) -or ($AutoFix))) {
    Write-Host ""
    foreach ($c in $checks) {
      if (-not $c.ok -and $c.fix) {
        $doFix = $AutoFix
        if (-not $AutoFix) {
          Write-Host "修复「$($c.name)」？" -ForegroundColor Yellow
          Write-Host "  说明: $($c.fixDesc)" -ForegroundColor Gray
          $resp = Read-Host "  输入 y 修复 / n 跳过 / q 退出 (y/n/q)"
          if ($resp -eq 'q') { break }
          $doFix = ($resp -eq 'y')
        }
        if ($doFix) {
          Write-Host "  执行中..." -ForegroundColor Cyan
          try { & $c.fix; Write-Host "    OK" -ForegroundColor Green }
          catch { Write-Host "    ERR: $_" -ForegroundColor Red }
        } else { Write-Host "  已跳过" -ForegroundColor Gray }
      }
    }
  } elseif ($warnCount -gt 0) {
    Write-Host "`n提示: 加 -Fix 参数可交互式修复，加 -AutoFix 自动修复" -ForegroundColor Yellow
  }
}