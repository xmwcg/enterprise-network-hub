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
# ========== 价格对比（中关村在线搜索 + 京东搜索） ==========
function Search-Price {
  param([string]$Keyword, [string]$Category)
  $results = @()
  $errors = @()

  # 方案1：中关村在线搜索（静态HTML，可正则提取）
  try {
    $zolUrl = "https://search.zol.com.cn/s/?keyword=$([uri]::EscapeDataString($Keyword))"
    $web = Invoke-WebRequest -Uri $zolUrl -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
    # 提取商品标题和价格
    $titles = [regex]::Matches($web.Content, 'class="pro-title"[^>]*title="([^"]*)"')
    $prices = [regex]::Matches($web.Content, 'class="price-row"[^>]*>\s*<span[^>]*>([^<]*)</span>')
    $count = [math]::Min(5, [math]::Min($titles.Count, $prices.Count))
    for ($i=0;$i -lt $count;$i++) {
      $name = $titles[$i].Groups[1].Value
      $priceStr = $prices[$i].Groups[1].Value -replace '[^0-9.]',''
      $price = if ($priceStr) { [double]$priceStr } else { 0 }
      $results += @{name=$name;price=$price;source="中关村在线";keyword=$Keyword}
    }
  } catch { $errors += "中关村在线: $_" }

  # 方案2：如果中关村抓不到，尝试太平洋电脑网
  if ($results.Count -eq 0) {
    try {
      $pconUrl = "https://ks.pconline.com.cn/product.shtml?q=$([uri]::EscapeDataString($Keyword))"
      $web2 = Invoke-WebRequest -Uri $pconUrl -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
      $names2 = [regex]::Matches($web2.Content, 'class="item-title"[^>]*>([^<]*)<')
      $prices2 = [regex]::Matches($web2.Content, 'class="price"[^>]*>(?:<em>)?(?:¥)?(\d+[\.\d]*)')
      $count2 = [math]::Min(5, [math]::Min($names2.Count, $prices2.Count))
      for ($i=0;$i -lt $count2;$i++) {
        $results += @{name=$names2[$i].Groups[1].Value;price=[double]($prices2[$i].Groups[1].Value -replace '[^0-9.]','');source="太平洋电脑网";keyword=$Keyword}
      }
    } catch { $errors += "太平洋电脑网: $_" }
  }

  # 方案3：京东搜索（动态渲染，仅能拿到部分静态信息）
  if ($results.Count -eq 0) {
    try {
      $jdUrl = "https://search.jd.com/Search?keyword=$([uri]::EscapeDataString($Keyword))&enc=utf-8"
      $web3 = Invoke-WebRequest -Uri $jdUrl -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
      # 京东商品名在 title 属性中
      $jdNames = [regex]::Matches($web3.Content, 'data-title="([^"]*)"')
      $jdPrices = [regex]::Matches($web3.Content, 'data-price="([^"]*)"')
      $count3 = [math]::Min(5, [math]::Min($jdNames.Count, $jdPrices.Count))
      for ($i=0;$i -lt $count3;$i++) {
        $results += @{name=$jdNames[$i].Groups[1].Value;price=[double]$jdPrices[$i].Groups[1].Value;source="京东";keyword=$Keyword}
      }
    } catch { $errors += "京东: $_" }
  }

  # 方案4：完全离线参考价
  if ($results.Count -eq 0) {
    $refPrices = @{
      "i7"=@{name="Intel Core i7 参考价";price=2500;source="参考(中关村均价)"}
      "i5"=@{name="Intel Core i5 参考价";price=1400;source="参考(中关村均价)"}
      "i9"=@{name="Intel Core i9 参考价";price=4000;source="参考(中关村均价)"}
      "rtx"=@{name="NVIDIA RTX 4060 参考价";price=2300;source="参考(中关村均价)"}
      "rx"=@{name="AMD RX 7600 参考价";price=2000;source="参考(中关村均价)"}
      "ddr4"=@{name="DDR4 16GB 参考价";price=250;source="参考"}
      "ddr5"=@{name="DDR5 16GB 参考价";price=400;source="参考"}
      "ssd"=@{name="SSD 1TB NVMe 参考价";price=450;source="参考"}
      "hdd"=@{name="HDD 2TB 参考价";price=420;source="参考"}
    }
    $matched = $false
    foreach ($k in $refPrices.Keys) {
      if ($Keyword -match $k) { $results += $refPrices[$k]; $matched = $true; break }
    }
    if (-not $matched) {
      $results += @{name="$Keyword (需联网获取实时价格)";price=0;source="建议联网后重试";note="中关村/京东/太平洋 均不可达";errors=$errors}
    }
  }

  return @{keyword=$Keyword;category=$Category;results=$results;errors=$errors;updatedAt=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}
}
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