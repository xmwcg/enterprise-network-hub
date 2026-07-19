<#
.SYNOPSIS  金网通 · 资产管理模块 V2（JSON版，零外部依赖）
#>
param(
  [string]$ImportJson,
  [string]$ExportFormat,
  [string]$ExportPath,
  [switch]$ListAssets,
  [string]$DbPath = "$PSScriptRoot\console-data\asset-db.json"
)

$dbDir = Split-Path $DbPath -Parent
if (-not (Test-Path $dbDir)) { New-Item -ItemType Directory -Path $dbDir -Force | Out-Null }

function Get-Assets {
  if (Test-Path $DbPath) {
    try { return Get-Content $DbPath -Raw | ConvertFrom-Json }
    catch { return @() }
  }
  return @()
}

function Save-Assets($data) {
  [IO.File]::WriteAllText($DbPath, ($data | ConvertTo-Json -Depth 8), [Text.Encoding]::UTF8)
}

function Import-Asset($jsonPath) {
  $data = Get-Content $jsonPath -Raw | ConvertFrom-Json
  $assets = @(Get-Assets)
  $sys = $data.system
  $ts = $data.scanTime
  $hostname = $sys.hostname

  # 系统
  $assets += @{id=[guid]::NewGuid().ToString("N").Substring(0,8);hostname=$hostname;scanTime=$ts;category="system";itemName="OperatingSystem";manufacturer=$sys.manufacturer;model=$sys.model;spec="$($sys.osCaption) $($sys.osArch)";createdAt=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}

  # CPU
  foreach ($c in $data.cpu.detail) {
    $assets += @{id=[guid]::NewGuid().ToString("N").Substring(0,8);hostname=$hostname;scanTime=$ts;category="cpu";itemName=$c.name;manufacturer=$c.manufacturer;model=$c.name;spec="$($c.cores)C/$($c.threads)T $($c.maxMHz)MHz";createdAt=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}
  }

  # 内存
  foreach ($m in $data.memory.modules) {
    $assets += @{id=[guid]::NewGuid().ToString("N").Substring(0,8);hostname=$hostname;scanTime=$ts;category="memory";itemName="$($m.capGB)GB $($m.speed)MHz";manufacturer=$m.manufacturer;model=$m.part;spec="Slot:$($m.slot)";createdAt=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}
  }

  # 硬盘
  foreach ($d in $data.disk.physical) {
    $assets += @{id=[guid]::NewGuid().ToString("N").Substring(0,8);hostname=$hostname;scanTime=$ts;category="disk";itemName="$($d.sizeGB)GB";manufacturer=$d.manufacturer;model=$d.model;spec="$($d.interface)";createdAt=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}
  }

  # GPU
  foreach ($g in $data.gpu) {
    if ($g.vramMB -gt 0) {
      $assets += @{id=[guid]::NewGuid().ToString("N").Substring(0,8);hostname=$hostname;scanTime=$ts;category="gpu";itemName=$g.name;manufacturer="";model=$g.name;spec="$($g.vramMB)MB";createdAt=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}
    }
  }

  # 网卡
  foreach ($n in $data.network) {
    $assets += @{id=[guid]::NewGuid().ToString("N").Substring(0,8);hostname=$hostname;scanTime=$ts;category="network";itemName=$n.name;manufacturer="";model=$n.name;spec="MAC:$($n.mac)";createdAt=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}
  }

  # 主板
  $assets += @{id=[guid]::NewGuid().ToString("N").Substring(0,8);hostname=$hostname;scanTime=$ts;category="motherboard";itemName="主板";manufacturer=$data.motherboard.manufacturer;model=$data.motherboard.product;spec="";createdAt=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}

  Save-Assets $assets
  Write-Host "OK: $($assets.Count) 条资产已入库 -> $DbPath"
}

if ($ImportJson) { Import-Asset $ImportJson }

if ($ListAssets) {
  $assets = @(Get-Assets)
  if ($assets.Count -eq 0) { Write-Host "(空)"; return }
  Write-Host "ID`t主机名`t类别`t项目`t厂商`t型号`t规格"
  foreach ($a in $assets) {
    Write-Host "$($a.id)`t$($a.hostname)`t$($a.category)`t$($a.itemName)`t$($a.manufacturer)`t$($a.model)`t$($a.spec)"
  }
  Write-Host "`n总计: $($assets.Count) 条资产"
}

if ($ExportFormat -eq "csv" -and $ExportPath) {
  $assets = @(Get-Assets)
  $csv = "id,hostname,category,itemName,manufacturer,model,spec,createdAt`r`n"
  foreach ($a in $assets) {
    $csv += "$($a.id),$($a.hostname),$($a.category),$($a.itemName),$($a.manufacturer),$($a.model),$($a.spec),$($a.createdAt)`r`n"
  }
  [IO.File]::WriteAllText($ExportPath, $csv, [Text.Encoding]::UTF8)
  Write-Host "OK: $ExportPath ($($assets.Count) 条)"
}