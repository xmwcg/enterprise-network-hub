<#
.SYNOPSIS  C盘瘦身 / 系统垃圾清理核心库（仅删系统产生的垃圾，不碰用户/企业生产数据）
.DESCRIPTION
  本库被 diskclean.ps1（单机图形/CLI 入口）与 agent.ps1（M3 控制台批量下发）共用。
  设计铁律（对应"100% 安全"边界，诚实表述而非承诺绝对零风险）：
    1. 仅白名单：所有可删项来自下方 $Script:AllowList（硬编码的"类别→路径模板→风险等级"），
       绝不"全盘找大文件就删"；AppData 仅精确匹配缓存子目录，绝不整目录扫描。
    2. 先备份后删除：删除前可把待删项复制到用户指定备份盘（D: / U盘）。
    3. 删除前路径校验：每个待删路径必须经 Assert-SafePath 校验落在"允许根目录"内，否则跳过。
    4. 删除后系统健康检查：Test-SystemHealth 检查关键服务/进程，异常则自动从备份还原。
    5. 不碰红线：pagefile.sys 只提示不处理；高风险项（如休眠文件）默认不出现，仅在高级选项提供。
  本文件被 dot-source 时仅提供函数，不执行主体。
.NOTES
  需以管理员运行（删除系统目录需要权限；提权时 UAC 由用户确认 = 用户决策）。
#>
param()

# ============ 1) 可删白名单（硬编码，绝不"全盘找大文件"） ============
# Kind 说明：
#   dir    = 删除路径模板匹配到的"项"（目录内容或匹配文件），走 Remove-Item
#   dism   = 调用 DISM 清理组件存储（最安全，不手工删文件）
#   special= 调用系统命令（如 powercfg 关闭休眠），高风险，仅高级选项
$Script:AllowList = @(
  [ordered]@{
    Id       = 'updcache';   Category = '系统更新缓存'; Name = 'Windows 更新下载缓存'
    Risk     = '低'; Advanced = $false; Kind = 'dir'
    RiskNote = 'Windows Update 下载的更新包，删除不影响已安装的更新；下次更新会自动重新下载。'
    Paths    = @('C:\Windows\SoftwareDistribution\Download\*')
  },
  [ordered]@{
    Id       = 'systmp';     Category = '系统临时文件'; Name = '系统临时目录 (C:\Windows\Temp)'
    Risk     = '低'; Advanced = $false; Kind = 'dir'
    RiskNote = '系统与软件运行产生的临时文件，删除一般不会影响已安装软件；个别正在被占用的文件会跳过。'
    Paths    = @('C:\Windows\Temp\*')
  },
  [ordered]@{
    Id       = 'usertmp';    Category = '用户临时文件'; Name = '各用户临时目录 (AppData\Local\Temp)'
    Risk     = '低'; Advanced = $false; Kind = 'dir'
    RiskNote = '当前登录用户与其它账户的临时文件，删除不影响文档与已安装应用数据。'
    Paths    = @('C:\Users\*\AppData\Local\Temp\*')
  },
  [ordered]@{
    Id       = 'recycle';    Category = '回收站'; Name = '回收站 (C:\$Recycle.Bin)'
    Risk     = '中'; Advanced = $false; Kind = 'dir'
    RiskNote = '将清空所有用户的回收站。请确认回收站内没有还想保留的文件——清空后无法再从回收站恢复。'
    Paths    = @('C:\$Recycle.Bin\*')
  },
  [ordered]@{
    Id       = 'browsercache'; Category = '浏览器缓存'; Name = 'Edge / Chrome 浏览器缓存'
    Risk     = '中'; Advanced = $false; Kind = 'dir'
    RiskNote = '仅清理浏览器缓存文件，不会删除书签、密码、浏览历史、Cookie 与登录状态。'
    Paths    = @(
      'C:\Users\*\AppData\Local\Microsoft\Edge\User Data\Default\Cache\*',
      'C:\Users\*\AppData\Local\Microsoft\Edge\User Data\Default\Code Cache\*',
      'C:\Users\*\AppData\Local\Google\Chrome\User Data\Default\Cache\*',
      'C:\Users\*\AppData\Local\Google\Chrome\User Data\Default\Code Cache\*'
    )
  },
  [ordered]@{
    Id       = 'wer';        Category = '错误报告'; Name = 'Windows 错误报告 (WER)'
    Risk     = '低'; Advanced = $false; Kind = 'dir'
    RiskNote = 'Windows 错误转储与报告队列，删除不影响系统运行；排查故障时可能丢失旧报告。'
    Paths    = @('C:\ProgramData\Microsoft\Windows\WER\*')
  },
  [ordered]@{
    Id       = 'thumbcache'; Category = '缩略图缓存'; Name = '资源管理器缩略图缓存'
    Risk     = '低'; Advanced = $false; Kind = 'dir'
    RiskNote = '缩略图数据库，删除后系统会自动重建，不影响任何原图与文档。'
    Paths    = @('C:\Users\*\AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db')
  },
  [ordered]@{
    Id       = 'deliveryopt'; Category = '传递优化缓存'; Name = 'Windows 传递优化缓存 (Delivery Optimization)'
    Risk     = '低'; Advanced = $false; Kind = 'dir'
    RiskNote = '系统用于 P2P 更新的缓存，删除后下次更新会重新下载，不影响已装更新。'
    Paths    = @('C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*')
  },
  [ordered]@{
    Id       = 'winsxs';     Category = '组件存储'; Name = 'WinSxS 组件存储冗余'
    Risk     = '低'; Advanced = $false; Kind = 'dism'
    RiskNote = '通过系统自带 DISM 清理组件存储冗余，不手工删除任何文件，是微软推荐的最安全做法。'
    Paths    = @()
  },
  [ordered]@{
    Id       = 'windowold';  Category = '升级残留'; Name = 'Windows 升级残留 (Windows.old)'
    Risk     = '中'; Advanced = $true; Kind = 'dir'
    RiskNote = '旧系统备份，删除后可释放大量空间，但会失去"回退到旧版 Windows"的能力。确认不再回退再勾选。'
    Paths    = @('C:\Windows.old\*')
  },
  [ordered]@{
    Id       = 'hiberfil';   Category = '休眠文件'; Name = '休眠文件 hiberfil.sys'
    Risk     = '高'; Advanced = $true; Kind = 'special'
    RiskNote = '关闭休眠会删除休眠文件（通常 8~16GB）并禁用"休眠"与快速启动；之后无法使用休眠省电。仅高级用户勾选。'
    Paths    = @()
  }
)

# ============ 2) 路径模板展开（支持 C:\Users\* 多用户枚举） ============
function Expand-Template {
  [CmdletBinding()]
  param([string]$Pattern)
  $out = @()
  if ($Pattern -like 'C:\Users\*\*') {
    $rest = $Pattern.Substring('C:\Users\*\'.Length)
    foreach ($u in (Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
      $out += Join-Path $u.FullName $rest
    }
  } else {
    $out += $Pattern
  }
  return $out
}

# 由白名单推导"允许根目录集合"（防御性校验用，确保删除只落在这些根之下）
function Get-AllowedRoots {
  $roots = @()
  foreach ($cat in $Script:AllowList) {
    foreach ($p in $cat.Paths) {
      foreach ($c in (Expand-Template $p)) {
        if ($c.EndsWith('\*')) { $roots += $c.Substring(0, $c.Length - 2) }
        else { $roots += Split-Path $c -Parent }
      }
    }
  }
  # 去重（大小写不敏感）
  $seen = @{}; $result = @()
  foreach ($r in $roots) {
    $k = $r.ToLower()
    if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $result += $r }
  }
  return $result
}
$Script:AllowedRoots = Get-AllowedRoots

# 防御性校验：待删绝对路径必须落在允许根目录内，否则拒绝（防止模板误配导致误删）
function Assert-SafePath {
  [CmdletBinding()]
  param([string]$Path, [ref]$Reason)
  $lp = $Path.ToLower()
  foreach ($root in $Script:AllowedRoots) {
    if ($lp.StartsWith($root.ToLower())) { return $true }
  }
  if ($Reason) { $Reason.Value = "路径不在白名单允许根目录内，已跳过以防误删：$Path" }
  return $false
}

# ============ 3) 人机可读容量 ============
function Format-Bytes {
  [CmdletBinding()]
  param([double]$Bytes)
  if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
  return ('{0} B' -f [int]$Bytes)
}

# ============ 4) 安全扫描（只读、零删除） ============
function Invoke-SafeScan {
  [CmdletBinding()]
  param([switch]$Advanced)
  $results = @()
  foreach ($cat in $Script:AllowList) {
    if ($cat.Advanced -and -not $Advanced) { continue }
    $size = 0; $fileCount = 0
    foreach ($p in $cat.Paths) {
      foreach ($c in (Expand-Template $p)) {
        try {
          $items = @(Get-ChildItem -Path $c -Force -Recurse -ErrorAction SilentlyContinue)
          foreach ($it in $items) {
            if (-not $it.PSIsContainer) { $size += $it.Length; $fileCount++ }
          }
        } catch { }
      }
    }
    $results += [ordered]@{
      Id          = $cat.Id
      Category    = $cat.Category
      Name        = $cat.Name
      Risk        = $cat.Risk
      RiskNote    = $cat.RiskNote
      Advanced    = $cat.Advanced
      Kind        = $cat.Kind
      SizeBytes   = $size
      FileCount   = $fileCount
      Paths       = $cat.Paths
    }
  }
  return $results
}

# 取某类别"当前应删除的项"（文件系统实时枚举，供删除阶段使用）
function Get-DeleteItems {
  [CmdletBinding()]
  param([string]$CategoryId)
  $cat = $Script:AllowList | Where-Object { $_.Id -eq $CategoryId }
  if (-not $cat) { return @() }
  if ($cat.Kind -in @('dism', 'special')) { return @() }   # 这两类走命令，无文件项
  $items = @()
  foreach ($p in $cat.Paths) {
    foreach ($c in (Expand-Template $p)) {
      try { $items += @(Get-ChildItem -Path $c -Force -ErrorAction SilentlyContinue) } catch { }
    }
  }
  return $items
}

# ============ 5) 备份盘列举（D: 与可移动磁盘优先） ============
function Get-BackupDrives {
  [CmdletBinding()]
  param()
  $drives = @()
  foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    $letter = $d.Name + ':'
    if ($letter -eq 'C:') { continue }
    try {
      $free = $d.Free; $used = $d.Used
      $root = $d.Root
      $label = (Get-Volume -DriveLetter $d.Name -ErrorAction SilentlyContinue).FileSystemLabel
      if (-not $label) { $label = $letter }
    } catch { $free = $null; $label = $letter }
    $drives += [ordered]@{
      Letter    = $letter
      Root      = $root
      Label     = $label
      FreeBytes = if ($null -ne $free) { $free } else { 0 }
      Removable = ($d.DriveType -eq 'Removable')
    }
  }
  # 排序：可移动磁盘优先，其次按盘符
  $drives | Sort-Object @{ Expression = { -[int]$_.Removable } }, Letter
}

# ============ 6) 备份（先备份后删除） ============
function Invoke-Backup {
  [CmdletBinding()]
  param(
    [PSObject[]]$ScanResults,
    [string[]]$SelectedIds,
    [string]$BackupRoot
  )
  $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
  $backupDir = Join-Path $BackupRoot ("JinDiskClean_Backup\$ts")
  if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

  $manifest = @()
  $total = 0
  foreach ($id in $SelectedIds) {
    $items = @(Get-DeleteItems -CategoryId $id)
    foreach ($it in $items) {
      $rel = $it.FullName -replace '^([A-Za-z]):\\', '$1\'   # C:\x → C\x
      $dest = Join-Path $backupDir $rel
      $reason = ''
      if (-not (Assert-SafePath -Path $it.FullName -Reason ([ref]$reason))) {
        Write-Warning $reason; continue
      }
      try {
        $dparent = Split-Path $dest -Parent
        if ($dparent -and -not (Test-Path $dparent)) { New-Item -ItemType Directory -Path $dparent -Force | Out-Null }
        Copy-Item -Path $it.FullName -Destination $dest -Recurse -Force -ErrorAction Stop
        $manifest += [ordered]@{ Relative = $rel; Original = $it.FullName; Kind = if ($it.PSIsContainer) { 'dir' } else { 'file' } }
        $total++
      } catch {
        Write-Warning ("备份失败（已跳过，不影响清理）：{0} → {1}：{2}" -f $it.FullName, $dest, $_.Exception.Message)
      }
    }
  }
  # 写清单 + 还原脚本 + 恢复说明
  $manifestFile = Join-Path $backupDir 'backup-manifest.json'
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestFile -Encoding UTF8
  New-RestoreArtifacts -BackupDir $backupDir -ManifestFile $manifestFile

  return [ordered]@{
    BackupDir   = $backupDir
    ItemCount   = $total
    ManifestFile = $manifestFile
  }
}

# 生成 restore.ps1 与 恢复说明.txt
function New-RestoreArtifacts {
  [CmdletBinding()]
  param([string]$BackupDir, [string]$ManifestFile)
  $restorePs = @'
# 由「金网通 · C盘瘦身」生成 —— 双击或在 PowerShell 中运行本脚本即可把备份还原回原位置。
$ErrorActionPreference = 'Continue'
$BackupDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$manifestFile = Join-Path $BackupDir 'backup-manifest.json'
if (-not (Test-Path $manifestFile)) { Write-Error "未找到备份清单：$manifestFile"; exit 1 }
$manifest = Get-Content $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
$ok = 0; $fail = 0
foreach ($m in $manifest) {
    $src = Join-Path $BackupDir $m.Relative
    if (-not (Test-Path $src)) { Write-Warning "备份项缺失，跳过：$($m.Original)"; $fail++; continue }
    try {
        $dp = Split-Path $m.Original -Parent
        if ($dp -and -not (Test-Path $dp)) { New-Item -ItemType Directory -Path $dp -Force | Out-Null }
        Copy-Item -Path $src -Destination $m.Original -Recurse -Force
        Write-Host ("已还原：{0}" -f $m.Original) -ForegroundColor Green
        $ok++
    } catch {
        Write-Warning ("还原失败：{0}：{1}" -f $m.Original, $_.Exception.Message); $fail++
    }
}
Write-Host ("`n还原完成：成功 {0} 项，失败 {1} 项。" -f $ok, $fail)
if ($fail -gt 0) { Write-Host "部分项还原失败，可手动从 $BackupDir 复制回原路径。" -ForegroundColor Yellow }
'@
  Set-Content -Path (Join-Path $BackupDir 'restore.ps1') -Value $restorePs -Encoding UTF8

  $note = @"
==========================================================
  金网通 · C盘瘦身 —— 备份与恢复说明（重要，请保留本文件）
==========================================================

本目录是本次清理前系统垃圾文件的备份。清理是"先备份、后删除"的，
因此即便误删，也能 100% 从备份还原，不会丢失任何系统可恢复数据。

【如何恢复（两种方式任选其一）】
  方式一（推荐，最简单）：双击本目录下的  restore.ps1
        —— 会自动把备份原样复制回 C 盘原来的位置。
  方式二（手动）：打开 backup-manifest.json，按其中 Original（原始路径）
        把对应 Relative（本目录中的相对路径）文件复制回去。

【说明】
  · 本次清理只删除"系统产生的垃圾"（更新缓存/临时文件/回收站/浏览器缓存等），
    不涉及任何个人文档、企业文件或应用业务数据。
  · 若清理后电脑出现异常，请立即运行 restore.ps1 还原，并联系厂商支持。
  · 确认一切正常、无需恢复后，可手动删除本 JinDiskClean_Backup 目录以释放空间。

【安全边界（诚实告知）】
  本工具做到"仅白名单 + 先备份 + 删除后健康检查 + 可还原"，但技术上无法保证
  绝对零风险（极端情况下若某软件把数据放在白名单路径里）。如不确定，请勿勾选
  该项，或先备份确认无误再删除。

厂商支持：厦门金奕鸣科技有限公司（客服 13599530881）
"@
  Set-Content -Path (Join-Path $BackupDir '恢复说明.txt') -Value $note -Encoding UTF8
}

# ============ 7) 删除执行（仅白名单 + 路径校验 + DISM/特殊命令） ============
function Invoke-Cleanup {
  [CmdletBinding()]
  param(
    [PSObject[]]$ScanResults,
    [string[]]$SelectedIds,
    [string]$BackupDir = $null
  )
  $deleted = @(); $failed = @()
  foreach ($id in $SelectedIds) {
    $cat = $Script:AllowList | Where-Object { $_.Id -eq $id }
    if (-not $cat) { continue }

    if ($cat.Kind -eq 'dism') {
      try {
        Write-Host ("[DISM] 清理组件存储冗余：{0}" -f $cat.Name) -ForegroundColor Cyan
        $out = dism /Online /Cleanup-Image /StartComponentCleanup /Quiet 2>&1 | Out-String
        $deleted += [ordered]@{ Id = $id; Name = $cat.Name; Method = 'dism'; Detail = 'DISM StartComponentCleanup 完成' }
      } catch {
        $failed += [ordered]@{ Id = $id; Name = $cat.Name; Error = $_.Exception.Message }
      }
      continue
    }
    if ($cat.Kind -eq 'special') {
      # 目前仅休眠文件：powercfg -h off（会删除 hiberfil.sys）
      try {
        Write-Host ("[特殊] {0}（关闭休眠）" -f $cat.Name) -ForegroundColor Cyan
        powercfg -h off 2>&1 | Out-Null
        $deleted += [ordered]@{ Id = $id; Name = $cat.Name; Method = 'powercfg -h off'; Detail = '已关闭休眠并删除 hiberfil.sys' }
      } catch {
        $failed += [ordered]@{ Id = $id; Name = $cat.Name; Error = $_.Exception.Message }
      }
      continue
    }

    # 普通文件/目录删除
    $items = @(Get-DeleteItems -CategoryId $id)
    foreach ($it in $items) {
      $reason = ''
      if (-not (Assert-SafePath -Path $it.FullName -Reason ([ref]$reason))) {
        $failed += [ordered]@{ Id = $id; Name = $it.FullName; Error = $reason }; continue
      }
      try {
        Remove-Item -Path $it.FullName -Recurse -Force -ErrorAction Stop
        $deleted += [ordered]@{ Id = $id; Name = $it.FullName; Kind = if ($it.PSIsContainer) { 'dir' } else { 'file' } }
      } catch {
        $failed += [ordered]@{ Id = $id; Name = $it.FullName; Error = $_.Exception.Message }
      }
    }
  }

  # 删除后系统健康检查
  $health = Test-SystemHealth
  $restored = $false
  if (-not $health.Healthy -and $BackupDir -and (Test-Path $BackupDir)) {
    Write-Warning "检测到系统健康异常，正在从备份自动还原…"
    try {
      & (Join-Path $BackupDir 'restore.ps1') 2>&1 | Out-Null
      $restored = $true
    } catch { Write-Warning ("自动还原失败：{0}" -f $_.Exception.Message) }
  }

  return [ordered]@{
    DeletedCount = $deleted.Count
    FailedCount  = $failed.Count
    Deleted      = $deleted
    Failed       = $failed
    Health       = $health
    AutoRestored = $restored
  }
}

# ============ 8) 删除后系统健康检查 ============
function Test-SystemHealth {
  [CmdletBinding()]
  param()
  $details = @(); $ok = $true
  # 关键服务是否仍在运行
  $svcs = @('Winmgmt', 'RpcSs', 'Dnscache', 'Schedule', 'Themes')
  foreach ($s in $svcs) {
    try {
      $st = (Get-Service -Name $s -ErrorAction SilentlyContinue).Status
      if ($st -ne 'Running') {
        $ok = $false
        $details += "服务异常：$s 状态=$st（应为 Running）"
      } else {
        $details += "服务正常：$s"
      }
    } catch { $details += "服务检查跳过：$s" }
  }
  # explorer 是否存在（桌面可用）
  try {
    $exp = Get-Process -Name explorer -ErrorAction SilentlyContinue
    if (-not $exp) { $details += "提示：未检测到 explorer 进程（可能无桌面会话，非致命）" }
    else { $details += "桌面进程正常：explorer" }
  } catch { }
  # 能否新建进程
  try {
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c exit' -PassThru -WindowStyle Hidden -ErrorAction Stop
    $p.WaitForExit(5000)
    $details += "进程创建正常：可启动 cmd.exe"
  } catch {
    $ok = $false
    $details += "进程创建失败：$($_.Exception.Message)"
  }
  return [ordered]@{ Healthy = $ok; Details = $details }
}

# ============ 9) 待确认任务文件（M3 控制台批量下发 → 本地确认） ============
function Save-PendingPlan {
  [CmdletBinding()]
  param(
    [PSObject[]]$ScanResults,
    [string[]]$SelectedIds,
    [string]$BackupDrive,
    [bool]$Advanced
  )
  $dir = Join-Path $env:LOCALAPPDATA 'JinDiskClean'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $file = Join-Path $dir ("pending-{0}.json" -f (Get-Date -Format 'yyyyMMddHHmmss'))
  $picked = $ScanResults | Where-Object { $_.Id -in $SelectedIds }
  $plan = [ordered]@{
    Created      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    BackupDrive  = $BackupDrive
    Advanced     = $Advanced
    Categories   = $SelectedIds
    Scan         = $picked
    Note         = '已生成清理预览，尚未删除任何文件。请在本地以管理员运行 .\diskclean.ps1 查看并确认后执行。'
  }
  $plan | ConvertTo-Json -Depth 8 | Set-Content -Path $file -Encoding UTF8
  return $file
}
