<#
.SYNOPSIS  金网通 · 打印机一键发现与共享 V2
.DESCRIPTION
  自动发现本机连接的打印机（USB/LPT/网络），
  一键配置共享并打印测试页。
  PS 2.0+ 兼容。需管理员权限运行。
#>
param(
  [switch]$ListOnly,       # 仅列出打印机，不配置共享
  [switch]$ShareAll,       # 一键共享所有打印机
  [string]$PrinterName,    # 指定要共享的打印机
  [switch]$TestPage        # 共享后打印测试页
)

function Safe-WMI($C,$ns="root\cimv2"){
  try{if($PSVersionTable.PSVersion.Major-ge5){Get-CimInstance -ClassName $C -Namespace $ns -ErrorAction Stop}else{Get-WmiObject -Class $C -Namespace $ns -ErrorAction Stop}}catch{$null}
}

# 管理员检查
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
if(!$isAdmin){Write-Host "ERR:需要管理员权限";exit 1}

$printers = @(Get-WmiObject -Class Win32_Printer -Filter "Local=True")
$configs  = @(Get-WmiObject -Class Win32_PrinterConfiguration)
$ports    = @(Get-WmiObject -Class Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue)

$output = @()
foreach($p in $printers){
  $cfg = $configs | Where-Object {$_.Name -eq $p.Name} | Select -First 1
  $portInfo = $null
  # 判断端口类型
  if($p.PortName -match "^USB|^LPT|^COM|^DOT4"){
    $portInfo = @{type="local";port=$p.PortName}
  }elseif($p.PortName -match "^IP_"){
    $ipp = $ports | Where-Object {$_.Name -eq $p.PortName} | Select -First 1
    $portInfo = @{type="network";port=$p.PortName;host=$ipp.HostAddress;protocol=$ipp.Protocol}
  }else{
    $portInfo = @{type="other";port=$p.PortName}
  }

  $output += @{
    name       = $p.Name
    driver     = $p.DriverName
    status     = $p.PrinterStatus
    isDefault  = $p.Default
    isShared   = $p.Shared
    shareName  = $p.ShareName
    isNetwork  = $p.Network
    location   = $p.Location
    comment    = $p.Comment
    portInfo   = $portInfo
    horizontal = if($cfg){$cfg.HorizontalResolution}else{$null}
    vertical   = if($cfg){$cfg.VerticalResolution}else{$null}
    color      = if($cfg){$cfg.Color -eq 1}else{$null}
    duplex     = if($cfg){$cfg.Duplex -eq 1}else{$null}
    paperSize  = if($cfg){$cfg.PaperSize}else{$null}
  }
}

if($ListOnly){
  $output | ForEach-Object {
    Write-Host "=== $($_.name) ==="
    Write-Host "  驱动: $($_.driver)"
    Write-Host "  端口: $($_.portInfo.type) - $($_.portInfo.port)"
    if($_.portInfo.type -eq "network"){Write-Host "  主机: $($_.portInfo.host)"}
    Write-Host "  状态: $($_.status) | 默认: $($_.isDefault) | 已共享: $($_.isShared)"
    Write-Host ""
  }
  exit 0
}

# 共享打印机
$targets = @()
if($PrinterName){$targets = @($output | Where-Object {$_.name -eq $PrinterName})}
elseif($ShareAll){$targets = @($output | Where-Object {!$_.isShared -or $_.shareName -eq ""})}
else{$targets = @($output | Where-Object {!$_.isShared})}

if($targets.Count -eq 0){Write-Host "所有打印机已共享或无可共享的打印机";exit 0}

foreach($t in $targets){
  $sn = $t.name -replace '[\\/:*?"<>| ]','_'  
  Write-Host "共享: $($t.name) -> $sn"
  try{
    $pObj = Get-WmiObject -Class Win32_Printer -Filter "Name='$($t.name)'"
    $r = $pObj.SetShareName($sn).ReturnValue
    if($r -eq 0){Write-Host "  OK"}else{Write-Host "  ERR: code=$r"}
  }catch{Write-Host "  ERR: $_"}
}

# 打印测试页
if($TestPage){
  foreach($t in $targets){
    try{
      $pObj = Get-WmiObject -Class Win32_Printer -Filter "Name='$($t.name)'"
      $r = $pObj.PrintTestPage().ReturnValue
      Write-Host "测试页: $($t.name) -> $(if($r -eq 0){'已发送'}else{'ERR code='+$r})"
    }catch{Write-Host "测试页 ERR: $_"}
  }
}

# 返回 JSON 供控制台使用
$result = @{success=$true;shared=$targets.Count;printers=$output}
$result | ConvertTo-Json -Depth 4 -Compress