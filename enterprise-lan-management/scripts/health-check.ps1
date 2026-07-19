<#
.SYNOPSIS  金网通 · 一键全面体检+自动修复 V2
.DESCRIPTION
  整合权限/网络/共享/打印机/磁盘/安全 6大检测维度，
  各维度发现问题后提供交互式修复或全自动修复。
.PARAMETER AutoFix    自动修复所有问题（不询问）
.PARAMETER Export     导出体检报告到JSON文件
#>
param([switch]$AutoFix, [string]$Export)

. .\lib-init.ps1
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
if (-not $isAdmin -and $AutoFix) { Write-Host "ERR: -AutoFix 需要管理员权限"; exit 1 }

$allChecks = @()
$canFix = @()

function Add-Item($cat,$name,$ok,$detail,$fix,$fixDesc) {
  $allChecks += @{category=$cat;name=$name;ok=$ok;detail=$detail;fixDesc=$fixDesc}
  if (-not $ok -and $fix) { $canFix += @{category=$cat;name=$name;fix=$fix;fixDesc=$fixDesc} }
}

Write-Host "===== 金网通 一键体检 V2 =====" -ForegroundColor Cyan
Write-Host "时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "主机: $env:COMPUTERNAME"
Write-Host ""

# ─── 1. 权限检测 ───
Write-Host "[1/6] 权限检查..." -ForegroundColor Yellow
Add-Item "权限" "管理员权限" $isAdmin "$(if($isAdmin){'是'}else{'否'})"
$ep = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
$epOk = $ep -in @("RemoteSigned","Unrestricted","Bypass")
Add-Item "权限" "PS执行策略" $epOk "当前: $ep" { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force } "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force"

# ─── 2. 网络检测 ───
Write-Host "[2/6] 网络检查..." -ForegroundColor Yellow
$prof = Get-NetConnectionProfile -ErrorAction SilentlyContinue; $netOk = ($prof -and $prof.NetworkCategory -eq 'Private')
Add-Item "网络" "网络类别" $netOk "$(if($prof){$prof.NetworkCategory}else{'未知'})" { Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private } "将网络改为「专用网络」"

$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
$gwOk = $false; if($gw){try{$gwOk=(Test-Connection $gw -Count 1 -Quiet)}catch{}}
Add-Item "网络" "网关" $gwOk "网关=$gw"

try{$null=Resolve-DnsName 'baidu.com' -ErrorAction Stop; $dnsOk=$true}catch{$dnsOk=$false}
Add-Item "网络" "DNS" $dnsOk "baidu.com解析" { ipconfig /flushdns } "ipconfig /flushdns"

# ─── 3. 共享检测 ───
Write-Host "[3/6] 共享服务..." -ForegroundColor Yellow
$smb = Get-Service LanmanServer -ErrorAction SilentlyContinue; $smbOk = ($smb.Status -eq 'Running')
Add-Item "共享" "SMB服务" $smbOk "LanmanServer $($smb.Status)" { Set-Service LanmanServer -StartupType Automatic -Status Running; netsh advfirewall firewall set rule group='文件和打印机共享' new enable=Yes } "启用SMB+开防火墙"

$disc = Get-Service FDResPub -ErrorAction SilentlyContinue; $discOk = ($disc.Status -eq 'Running')
Add-Item "共享" "网络发现" $discOk "FDResPub $($disc.Status)" { Set-Service FDResPub -StartupType Automatic -Status Running } "启用网络发现服务"

$rdpOk = (Get-NetTCPConnection -LocalPort 3389 -ErrorAction SilentlyContinue | Where-Object {$_.State -eq 'Listen'}) -ne $null
Add-Item "共享" "远程桌面" $rdpOk "端口3389"

# ─── 4. 打印机 ───
Write-Host "[4/6] 打印机..." -ForegroundColor Yellow
$printers = @(Get-WmiObject Win32_Printer | Where-Object {$_.Local -and $_.Name -notmatch 'PDF|XPS|OneNote|Fax|Snagit'})
$printerShared = @($printers | Where-Object {$_.Shared})
Add-Item "打印机" "物理打印机" ($printers.Count -gt 0) "发现$($printers.Count)台" 
Add-Item "打印机" "已共享" ($printerShared.Count -gt 0) "$($printerShared.Count)/$($printers.Count)台" 

$spooler = Get-Service Spooler -ErrorAction SilentlyContinue
Add-Item "打印机" "打印服务" ($spooler.Status -eq 'Running') "Spooler $($spooler.Status)" { Set-Service Spooler -StartupType Automatic -Status Running } "启用打印服务"

# ─── 5. 磁盘 ───
Write-Host "[5/6] 磁盘检查..." -ForegroundColor Yellow
$cDrive = Get-PSDrive C -ErrorAction SilentlyContinue
if ($cDrive) {
  $freeGB = [math]::Round($cDrive.Free/1GB,1); $totalGB = [math]::Round($cDrive.Used/1GB + $freeGB,1)
  $diskOk = ($freeGB -gt 10)
  Add-Item "磁盘" "C盘空间" $diskOk "$freeGB GB / $totalGB GB" 
  if (-not $diskOk) {
    Add-Item "磁盘" "磁盘清理" $false "建议运行 diskclean.ps1 -ScanOnly" { .\diskclean.ps1 -ScanOnly } "扫描可清理垃圾"
  }
}

$diskErrors = Get-WmiObject Win32_LogicalDisk | Where-Object {$_.DriveType -eq 3} | ForEach-Object {
  $err = Get-WmiObject -Query "SELECT * FROM MSFT_StorageReliabilityCounter WHERE DeviceId='$($_.DeviceID)'" -Namespace root/Microsoft/Windows/Storage -ErrorAction SilentlyContinue
  if ($err -and $err.ReadErrorsTotal -gt 0) { $_ }
}
Add-Item "磁盘" "磁盘错误" ($diskErrors.Count -eq 0) "$($diskErrors.Count)个盘有读取错误"

# ─── 6. 安全 ───
Write-Host "[6/6] 安全检查..." -ForegroundColor Yellow
$fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object {$_.Enabled -eq 'True'}
Add-Item "安全" "防火墙" ($fw.Count -gt 0) "$($fw.Count)个配置启用"

$av = Get-WmiObject -Namespace root\SecurityCenter2 -Class AntiVirusProduct -ErrorAction SilentlyContinue
Add-Item "安全" "杀毒软件" ($av.Count -gt 0) "发现$($av.Count)个产品"

$uac = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue
$uacOk = ($uac.EnableLUA -eq 1)
Add-Item "安全" "UAC" $uacOk "用户账户控制$(if($uacOk){'已启用'}else{'已禁用'})"

$tpmOk = $false; try{$t=Get-WmiObject Win32_Tpm -Namespace root\cimv2\Security\MicrosoftTpm -ErrorAction Stop;if($t.IsActivated_InitialValue){$tpmOk=$true}}catch{}
Add-Item "安全" "TPM芯片" $tpmOk "$(if($tpmOk){'已激活'}else{'未检测到'})"

# ─── 汇总 ───
Write-Host ""
Write-Host "===== 体检报告 =====" -ForegroundColor Cyan
Write-Host ""
$catCurrent = ""
foreach ($c in $allChecks) {
  if ($c.category -ne $catCurrent) { Write-Host "`n--- $($c.category) ---" -ForegroundColor Magenta; $catCurrent = $c.category }
  $icon = if($c.ok){"[OK]"}else{"[!!]"}
  Write-Host "$icon $($c.name): $($c.detail)" -ForegroundColor $(if($c.ok){"Green"}else{"Red"})
}

$okCount = ($allChecks | Where-Object {$_.ok}).Count
$failCount = $allChecks.Count - $okCount
Write-Host "`n总计: $okCount 通过 / $failCount 问题 / $($allChecks.Count) 项" -ForegroundColor $(if($failCount -eq 0){"Green"}else{"Red"})

# ─── 修复 ───
if ($failCount -gt 0 -and ($AutoFix -or $isAdmin)) {
  Write-Host ""
  if ($AutoFix) {
    Write-Host "自动修复中..." -ForegroundColor Yellow
  } else {
    Write-Host "发现 $failCount 个问题。修复？" -ForegroundColor Yellow
    Write-Host ""
  }
  foreach ($f in $canFix) {
    $doFix = $AutoFix
    if (-not $AutoFix) {
      Write-Host "[$($f.category)] $($f.name)" -ForegroundColor White
      Write-Host "  $($f.fixDesc)" -ForegroundColor Gray
      $resp = Read-Host "  修复? (y/n/q)"
      if ($resp -eq 'q') { break }
      $doFix = ($resp -eq 'y')
    }
    if ($doFix) {
      Write-Host "  执行..." -ForegroundColor Cyan
      try { & $f.fix; Write-Host "    OK" -ForegroundColor Green }
      catch { Write-Host "    ERR: $_" -ForegroundColor Red }
    }
  }
} elseif ($failCount -gt 0) {
  Write-Host "`n加 -AutoFix 可自动修复，或运行 check-permissions.ps1 -Fix" -ForegroundColor Yellow
}

if ($Export) {
  @{time=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss');hostname=$env:COMPUTERNAME;checks=$allChecks;passCount=$okCount;failCount=$failCount} | ConvertTo-Json -Depth 4 | Out-File $Export -Encoding UTF8
  Write-Host "`n报告已导出: $Export"
}