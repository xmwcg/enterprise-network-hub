<#
.SYNOPSIS  金网通 · 资产管理模块 V2
.DESCRIPTION
  接收 scan-hardware.ps1 输出的 JSON，写入 SQLite 数据库，
  支持导出 Excel/CSV，联网价格对比（京东/天猫搜索）。
#>
param(
  [string]$ImportJson,      # scan-hardware.ps1 输出的 JSON 文件路径
  [string]$ExportFormat,    # csv / excel
  [string]$ExportPath,
  [switch]$ListAssets,      # 列出所有资产
  [switch]$PriceCheck,      # 联网价格对比（需要浏览器）
  [string]$DbPath = ".\assets.db"
)

Add-Type -AssemblyName System.Data
Add-Type -Path "$PSScriptRoot\System.Data.SQLite.dll" -ErrorAction SilentlyContinue

function Get-DbConn { New-Object System.Data.SQLite.SQLiteConnection("Data Source=$DbPath;Version=3;") }

function Init-DB {
  $conn = Get-DbConn; $conn.Open()
  $sql = @"
CREATE TABLE IF NOT EXISTS assets (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  hostname TEXT NOT NULL,
  scanTime TEXT,
  category TEXT NOT NULL,
  subCategory TEXT,
  itemName TEXT NOT NULL,
  manufacturer TEXT,
  model TEXT,
  serialNumber TEXT,
  spec TEXT,
  status TEXT,
  notes TEXT,
  rawJson TEXT,
  createdAt TEXT DEFAULT (datetime('now','localtime')),
  updatedAt TEXT DEFAULT (datetime('now','localtime'))
);
CREATE INDEX IF NOT EXISTS idx_assets_host ON assets(hostname);
CREATE INDEX IF NOT EXISTS idx_assets_cat ON assets(category);
CREATE TABLE IF NOT EXISTS asset_prices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  assetId INTEGER,
  source TEXT,
  productName TEXT,
  price REAL,
  url TEXT,
  checkedAt TEXT DEFAULT (datetime('now','localtime')),
  FOREIGN KEY(assetId) REFERENCES assets(id)
);
"@
  $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.ExecuteNonQuery() | Out-Null
  $conn.Close()
}

function Import-Asset($jsonPath) {
  Init-DB
  $data = Get-Content $jsonPath -Raw | ConvertFrom-Json
  $conn = Get-DbConn; $conn.Open()
  $tx = $conn.BeginTransaction()

  # 系统
  $sys = $data.system
  ExecSQL $conn $tx "INSERT INTO assets(hostname,scanTime,category,itemName,manufacturer,model,spec,rawJson) VALUES(@h,@t,@c,@n,@m,@d,@s,@r)" @{
    h=$sys.hostname; t=$data.scanTime; c="system"; n="OperatingSystem"
    m=$sys.manufacturer; d=$sys.model; s="$($sys.osCaption) $($sys.osArch)"; r=$jsonPath
  }
  ExecSQL $conn $tx "INSERT INTO assets(hostname,scanTime,category,itemName,manufacturer,model,serialNumber,rawJson) VALUES(@h,@t,@c,@n,@m,@d,@s,@r)" @{
    h=$sys.hostname; t=$data.scanTime; c="system"; n="ComputerSystem"
    m=$sys.manufacturer; d=$sys.model; s=$sys.systemType; r=$jsonPath
  }

  # CPU
  foreach($c in $data.cpu.detail){
    ExecSQL $conn $tx "INSERT INTO assets(hostname,scanTime,category,itemName,manufacturer,model,spec,rawJson) VALUES(@h,@t,@c,@n,@m,@d,@s,@r)" @{
      h=$sys.hostname; t=$data.scanTime; c="cpu"; n=$c.name; m=$c.manufacturer
      d=$c.name; s="$($c.cores)C/$($c.threads)T $($c.maxMHz)MHz"; r=$jsonPath
    }
  }

  # 主板
  ExecSQL $conn $tx "INSERT INTO assets(hostname,scanTime,category,itemName,manufacturer,model,serialNumber,rawJson) VALUES(@h,@t,@c,@n,@m,@d,@s,@r)" @{
    h=$sys.hostname; t=$data.scanTime; c="motherboard"; n="主板"
    m=$data.motherboard.manufacturer; d=$data.motherboard.product; s=$data.motherboard.serial; r=$jsonPath
  }

  # 内存
  foreach($m in $data.memory.modules){
    ExecSQL $conn $tx "INSERT INTO assets(hostname,scanTime,category,itemName,manufacturer,model,spec,rawJson) VALUES(@h,@t,@c,@n,@m,@d,@s,@r)" @{
      h=$sys.hostname; t=$data.scanTime; c="memory"; n="$($m.capGB)GB $($m.speed)MHz"
      m=$m.manufacturer; d=$m.part; s="Slot: $($m.slot)"; r=$jsonPath
    }
  }

  # 硬盘
  foreach($d in $data.disk.physical){
    ExecSQL $conn $tx "INSERT INTO assets(hostname,scanTime,category,itemName,manufacturer,model,spec,serialNumber,rawJson) VALUES(@h,@t,@c,@n,@m,@d,@s,@sn,@r)" @{
      h=$sys.hostname; t=$data.scanTime; c="disk"; n="$($d.sizeGB)GB $($d.interface)"
      m=$d.manufacturer; d=$d.model; s="$($d.media)"; sn=$d.serialNumber; r=$jsonPath
    }
  }

  # GPU
  foreach($g in $data.gpu){
    ExecSQL $conn $tx "INSERT INTO assets(hostname,scanTime,category,itemName,manufacturer,model,spec,rawJson) VALUES(@h,@t,@c,@n,@m,@d,@s,@r)" @{
      h=$sys.hostname; t=$data.scanTime; c="gpu"; n=$g.name; m=$g.manufacturer
      d=$g.name; s="$($g.vramMB)MB VRAM"; r=$jsonPath
    }
  }

  # 网卡
  foreach($n in $data.network){
    ExecSQL $conn $tx "INSERT INTO assets(hostname,scanTime,category,itemName,manufacturer,model,spec,rawJson) VALUES(@h,@t,@c,@n,@m,@d,@s,@r)" @{
      h=$sys.hostname; t=$data.scanTime; c="network"; n=$n.name; m=$n.manufacturer
      d=$n.name; s="MAC:$($n.mac) $($n.speedMbps)Mbps"; r=$jsonPath
    }
  }

  $tx.Commit(); $conn.Close()
  Write-Host "OK: 资产已入库 -> $DbPath"
}

function ExecSQL($conn,$tx,$sql,$params){
  $cmd = $conn.CreateCommand(); $cmd.Transaction = $tx; $cmd.CommandText = $sql
  foreach($k in $params.Keys){$p=$cmd.Parameters.Add("@$k",[System.Data.DbType]::String);$p.Value=$params[$k]}
  $cmd.ExecuteNonQuery()|Out-Null
}

function Export-CSV($path){
  $conn = Get-DbConn; $conn.Open()
  $cmd = $conn.CreateCommand(); $cmd.CommandText = "SELECT * FROM assets ORDER BY hostname, category"
  $reader = $cmd.ExecuteReader()
  $dt = New-Object System.Data.DataTable; $dt.Load($reader)
  $csv = @()
  $cols = @("hostname","scanTime","category","subCategory","itemName","manufacturer","model","serialNumber","spec","status")
  $csv += ($cols -join ",")
  foreach($row in $dt.Rows){
    $line = ($cols | ForEach-Object { '"'+$row.$_.ToString().Replace('"','""')+'"' }) -join ","
    $csv += $line
  }
  $conn.Close()
  [IO.File]::WriteAllText($path, ($csv -join "`r`n"), [Text.Encoding]::UTF8)
  Write-Host "OK: $path"
}

# 主入口
if($ImportJson){Import-Asset $ImportJson}
if($ListAssets){
  Init-DB
  $conn = Get-DbConn; $conn.Open()
  $cmd = $conn.CreateCommand(); $cmd.CommandText = "SELECT hostname, category, itemName, manufacturer, model, spec FROM assets ORDER BY hostname, category"
  $r = $cmd.ExecuteReader()
  Write-Host "主机名`t类别`t项目`t厂商`t型号`t规格"
  while($r.Read()){Write-Host "$($r['hostname'])`t$($r['category'])`t$($r['itemName'])`t$($r['manufacturer'])`t$($r['model'])`t$($r['spec'])"}
  $conn.Close()
}
if($ExportFormat -eq "csv" -and $ExportPath){Export-CSV $ExportPath}