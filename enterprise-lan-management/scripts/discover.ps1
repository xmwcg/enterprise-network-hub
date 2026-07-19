<#
.SYNOPSIS  金网通 · 局域网设备发现+自动修复 V2
.DESCRIPTION
  扫描局域网设备，检测可达性和共享状态，
  发现问题提供自动修复（启用SMB、开启防火墙端口等）。
.PARAMETER AutoFix 自动修复
.PARAMETER Json    JSON输出
#>
param([switch]$AutoFix, [switch]$Json, [string]$Subnet)

. .\lib-init.ps1
. .\lib-discovery.ps1

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

# 获取本网段
if (-not $Subnet) {
  $myIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notmatch '^127\.|^169\.254\.' -and $_.PrefixOrigin -ne 'WellKnown'} | Select-Object -First 1)
  if ($myIp) { $parts = $myIp.IPAddress -split '\.'; $Subnet = "$($parts[0]).$($parts[1]).$($parts[2]).0/24" }
  else { $Subnet = "192.168.1.0/24" }
}

Write-Host "`n===== 金网通 局域网设备发现 =====" -ForegroundColor Cyan
Write-Host "扫描网段: $Subnet"
Write-Host ""

$devices = @()
$prefix = ($Subnet -split '/')[0] -replace '\.\d+$',''
$start = 1; $end = 254

Write-Host "扫描中..." -ForegroundColor Yellow
$jobs = @()
for ($i=$start; $i -le $end; $i++) {
  $ip = "$prefix.$i"
  $jobs += Test-Connection $ip -Count 1 -AsJob -ErrorAction SilentlyContinue -TimeoutSeconds 1
  if ($jobs.Count -ge 50) {
    $jobs | Wait-Job -Timeout 3 | Out-Null
    foreach ($j in $jobs) {
      $result = $j | Receive-Job
      if ($result -and $result.StatusCode -eq 0) {
        $onlineIp = $result.Address
        try { $hostname = (Resolve-DnsName $onlineIp -ErrorAction SilentlyContinue).NameHost; if(-not $hostname){$hostname=$onlineIp} } catch { $hostname = $onlineIp }
        # 检测 SMB 共享
        $smbOk = $false
        try { $null = Get-WmiObject -Class Win32_Share -ComputerName $onlineIp -ErrorAction Stop; $smbOk = $true } catch {}
        $devices += @{ip=$onlineIp;hostname=$hostname;smb=$smbOk;rdp=$false;online=$true}
      }
    }
    $jobs | Remove-Job -Force
    $jobs = @()
  }
}
Write-Host "完成。发现 $($devices.Count) 台设备`n"

# 显示结果
$issues = @()
foreach ($d in $devices) {
  $smbIcon = if($d.smb){"[OK]"}else{"[!!]"}
  $smbMsg = if($d.smb){"SMB可用"}else{"SMB不可达"}
  Write-Host "$smbIcon $($d.hostname) ($($d.ip)): $smbMsg"
  if (-not $d.smb -and $d.ip -ne $myIp.IPAddress) {
    $issues += $d
  }
}

if ($issues.Count -gt 0) {
  Write-Host "`n发现 $($issues.Count) 台设备 SMB 不可达" -ForegroundColor Red
  Write-Host ""
  foreach ($i in $issues) {
    Write-Host "问题设备: $($i.hostname) ($($i.ip))" -ForegroundColor Yellow
    Write-Host "  可能原因: SMB服务未启用 / 防火墙阻止 / 不在同一工作组" -ForegroundColor Gray
    Write-Host "  修复建议:" -ForegroundColor White
    Write-Host "    1. 在目标电脑上运行: .\fileshare.ps1 -All" -ForegroundColor Gray
    Write-Host "    2. 或手动启用: services.msc -> Function Discovery Resource Publication (自动)" -ForegroundColor Gray
    Write-Host "    3. 检查防火墙: netsh advfirewall firewall set rule group='文件和打印机共享' new enable=Yes" -ForegroundColor Gray

    if ($AutoFix -and $isAdmin) {
      Write-Host "  尝试远程修复..." -ForegroundColor Cyan
      try {
        $null = Invoke-Command -ComputerName $i.ip -ScriptBlock { Get-Service LanmanServer | Set-Service -StartupType Automatic -Status Running } -ErrorAction Stop
        Write-Host "    OK" -ForegroundColor Green
      } catch {
        Write-Host "    ERR: 远程修复失败（可能需要目标电脑的管理员凭据）" -ForegroundColor Red
      }
    }
  }
}

# 本机 SMB 服务自检
Write-Host "`n=== 本机共享服务状态 ===" -ForegroundColor Cyan
$svcs = @(
  @{name="LanmanServer (SMB共享)";svc="LanmanServer"},
  @{name="FDResPub (网络发现)";svc="FDResPub"},
  @{name="SSDPSRV (SSDP发现)";svc="SSDPSRV"},
  @{name="upnphost (UPnP)";svc="upnphost"}
)
$localIssues = @()
foreach ($s in $svcs) {
  $stat = (Get-Service $s.svc -ErrorAction SilentlyContinue).Status
  $ok = ($stat -eq 'Running')
  Write-Host "$(if($ok){'[OK]'}else{'[!!]'}) $($s.name): $stat" -ForegroundColor $(if($ok){'Green'}else{'Red'})
  if (-not $ok) { $localIssues += $s }
}

if ($localIssues.Count -gt 0) {
  Write-Host ""
  if ($AutoFix -and $isAdmin) {
    Write-Host "正在自动修复本机服务..." -ForegroundColor Cyan
    foreach ($s in $localIssues) {
      try { Set-Service $s.svc -StartupType Automatic -Status Running -ErrorAction Stop; Write-Host "  $($s.name): OK" -ForegroundColor Green }
      catch { Write-Host "  $($s.name): ERR $_" -ForegroundColor Red }
    }
  } else {
    Write-Host "修复命令（以管理员运行）:" -ForegroundColor Yellow
    foreach ($s in $localIssues) {
      Write-Host "  Set-Service $($s.svc) -StartupType Automatic -Status Running" -ForegroundColor Gray
    }
    Write-Host "`n加 -AutoFix 可自动修复" -ForegroundColor Gray
  }
}

if ($Json) {
  @{time=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss');subnet=$Subnet;devices=$devices;localIssues=($localIssues|%{$_.name})} | ConvertTo-Json -Depth 4 -Compress
}