<#
.SYNOPSIS  金网通 · 集中管理控制台 API 扩展 V2
.DESCRIPTION
  为 console.ps1 添加资产管理和价格对比 API 路由。
  在 console.ps1 的 route block 中追加使用。
#>

# ========== 资产管理数据格式 ==========
function New-AssetDB {
  param([string]$DataDir)
  $dbFile = Join-Path $DataDir "asset-db.json"
  if (-not (Test-Path $dbFile)) {
    [IO.File]::WriteAllText($dbFile, "[]", [Text.Encoding]::UTF8)
  }
  return $dbFile
}

function Get-Assets {
  param([string]$DataDir)
  $dbFile = New-AssetDB $DataDir
  try { return Get-Content $dbFile -Raw | ConvertFrom-Json }
  catch { return @() }
}

function Add-Asset {
  param([string]$DataDir, $Asset)
  $dbFile = New-AssetDB $DataDir
  $assets = @(Get-Assets $DataDir)
  $asset | Add-Member -NotePropertyName id -NotePropertyValue ([guid]::NewGuid().ToString("N").Substring(0,8)) -Force
  $asset | Add-Member -NotePropertyName createdAt -NotePropertyValue (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
  $assets += $asset
  [IO.File]::WriteAllText($dbFile, ($assets | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
  return $asset
}

function Update-Asset {
  param([string]$DataDir, [string]$AssetId, $Updates)
  $dbFile = New-AssetDB $DataDir
  $assets = @(Get-Assets $DataDir)
  for ($i=0;$i -lt $assets.Count;$i++) {
    if ($assets[$i].id -eq $AssetId) {
      foreach ($k in $Updates.PSObject.Properties.Name) {
        $assets[$i].$k = $Updates.$k
      }
      $assets[$i].updatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
      [IO.File]::WriteAllText($dbFile, ($assets | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
      return $assets[$i]
    }
  }
  return $null
}

function Remove-Asset {
  param([string]$DataDir, [string]$AssetId)
  $dbFile = New-AssetDB $DataDir
  $assets = @(Get-Assets $DataDir)
  $assets = @($assets | Where-Object { $_.id -ne $AssetId })
  [IO.File]::WriteAllText($dbFile, ($assets | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
  return $true
}

# ========== 价格对比（联网搜索京东） ==========
function Search-Price {
  param([string]$Keyword, [string]$Category)
  # 使用京东搜索接口获取参考价格
  $results = @()
  try {
    $searchUrl = "https://search.jd.com/Search?keyword=$([uri]::EscapeDataString($Keyword))&enc=utf-8"
    # 由于 PowerShell 无法直接解析 JS 渲染页面，这里使用 HTTP GET + 简单正则
    $web = Invoke-WebRequest -Uri $searchUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    # 提取商品价格（京东页面中的价格）
    $prices = [regex]::Matches($web.Content, '"op":"(\d+\.\d+)"')
    $names  = [regex]::Matches($web.Content, '<em>(.*?)</em>')
    $count = [math]::Min(5, [math]::Min($prices.Count, $names.Count))
    for ($i=0;$i -lt $count;$i++) {
      $results += @{
        name  = $names[$i].Groups[1].Value -replace '<[^>]+>',''
        price = [double]$prices[$i].Groups[1].Value
        source = "京东"
        keyword = $Keyword
      }
    }
  } catch {
    $results += @{
      name = "$Keyword (联网搜索暂不可用)"
      price = 0
      source = "离线"
      note = "请在联网环境重试"
    }
  }
  return @{keyword=$Keyword;category=$Category;results=$results;updatedAt=(Get-Date -Format "yyyy-MM-dd HH:mm:ss")}
}

# ========== 仪表盘统计 ==========
function Get-DashboardSummary {
  param([string]$DataDir)
  $devices = Get-DeviceList $DataDir
  $assets = Get-Assets $DataDir
  $tasks = Get-TaskList $DataDir

  # 分类统计
  $cpuCount = ($assets | Where-Object { $_.category -eq "cpu" }).Count
  $memList  = @($assets | Where-Object { $_.category -eq "memory" })
  $diskList = @($assets | Where-Object { $_.category -eq "disk" })
  $gpuCount = ($assets | Where-Object { $_.category -eq "gpu" }).Count

  $totalMemGB = ($memList | ForEach-Object {
    if ($_.spec -match '(\d+\.?\d*)GB') { [double]$Matches[1] } else { 0 }
  } | Measure-Object -Sum).Sum

  $totalDiskGB = ($diskList | ForEach-Object {
    if ($_.spec -match '(\d+\.?\d*)GB') { [double]$Matches[1] } else { 0 }
  } | Measure-Object -Sum).Sum

  return @{
    deviceCount   = $devices.Count
    assetCount    = $assets.Count
    cpuCount      = $cpuCount
    totalMemGB    = [math]::Round($totalMemGB, 1)
    totalDiskGB   = [math]::Round($totalDiskGB, 1)
    gpuCount      = $gpuCount
    taskCount     = $tasks.Count
    pendingTasks  = ($tasks | Where-Object { $_.status -eq "pending" }).Count
    completedTasks= ($tasks | Where-Object { $_.status -eq "done" }).Count
    failedTasks   = ($tasks | Where-Object { $_.status -eq "failed" }).Count
    updatedAt     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  }
}