<#
.SYNOPSIS  金网通 · C盘瘦身（系统垃圾清理）—— 单机入口（CLI 向导 + 简易图形双形态）
.DESCRIPTION
  · 仅清理"系统产生的垃圾"，不碰个人/企业任何生产文件与应用数据（见 lib-diskclean.ps1 白名单）。
  · 三步走：扫描（只读、零删除）→ 用户逐项勾选/跳过并选备份盘 → 确认后才执行删除。
  · 删除前可一键备份到 D: 或 U 盘；删除后做系统健康检查，异常自动从备份还原。
  · 无参数运行 = 图形界面（适合小白勾选）；加 -Cli / -ScanOnly / -Yes = 命令行模式。
  · 同时可作为 M3 控制台的 diskclean 任务在终端本地确认执行（见 agent.ps1）。
.PARAMETER Gui        强制图形界面
.PARAMETER Cli        强制命令行向导
.PARAMETER ScanOnly   仅扫描并打印可清理项（不删除、不备份）
.PARAMETER Advanced   包含高风险高级项（如休眠文件 hiberfil.sys）
.PARAMETER BackupDrive 备份盘盘符（如 D:）；CLI 模式下指定则跳过交互询问
.PARAMETER Categories 指定要清理的类别 Id 列表（逗号或数组）；CLI 模式下使用
.PARAMETER NoBackup   不备份直接删除（不推荐；跳过图形/交互的备份询问）
.PARAMETER Yes        跳过最终确认（需同时提供 Categories 与 BackupDrive/NoBackup，供脚本调用）
.PARAMETER TaskFile   读取控制台下发的待确认任务文件（由 agent 生成），展示并等待本地确认
#>
[CmdletBinding()]
param(
  [switch]$Gui,
  [switch]$Cli,
  [switch]$ScanOnly,
  [switch]$Advanced,
  [string]$BackupDrive,
  [string[]]$Categories,
  [switch]$NoBackup,
  [switch]$Yes,
  [string]$TaskFile
)

. .\lib-init.ps1
. .\lib-diskclean.ps1

# 管理员提权（删除系统目录需要权限；UAC 由用户确认 = 用户决策）
if ($MyInvocation.InvocationName -ne '.') { Request-AdminOrElevate -ScriptPath $PSCommandPath -Bound $PSBoundParameters -Unbound $args }

$cliMode = $ScanOnly -or $Yes -or $Cli -or $TaskFile -or ($Categories.Count -gt 0)
$useGui  = ($Gui -or -not $cliMode)

# ===================================================================
#  图形界面（WinForms）
# ===================================================================
function Start-Gui {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $bg      = [System.Drawing.Color]::FromArgb(30, 30, 30)
  $panelBg = [System.Drawing.Color]::FromArgb(37, 37, 38)
  $fieldBg = [System.Drawing.Color]::FromArgb(45, 45, 48)
  $fg      = [System.Drawing.Color]::FromArgb(212, 212, 212)
  $accent  = [System.Drawing.Color]::FromArgb(14, 99, 156)
  $accentFg= [System.Drawing.Color]::FromArgb(255, 255, 255)
  $dim     = [System.Drawing.Color]::FromArgb(150, 150, 150)
  $okCol   = [System.Drawing.Color]::FromArgb(78, 201, 116)
  $yelCol  = [System.Drawing.Color]::FromArgb(220, 180, 70)
  $badCol  = [System.Drawing.Color]::FromArgb(220, 90, 90)

  $form = New-Object Windows.Forms.Form
  $form.Text = "金网通 · C盘瘦身（系统垃圾清理）"
  $form.Size = New-Object Drawing.Size(820, 600)
  $form.StartPosition = "CenterScreen"
  $form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
  $form.BackColor = $bg; $form.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)

  # 标题 + 提示
  $lblTitle = New-Object Windows.Forms.Label
  $lblTitle.Text = "请勾选要清理的项目（仅系统产生的垃圾，不涉及您的文档/业务数据）"
  $lblTitle.Location = New-Object Drawing.Point(14, 10); $lblTitle.Size = New-Object Drawing.Size(780, 22)
  $lblTitle.ForeColor = $accentFg; $lblTitle.Font = New-Object Drawing.Font("Microsoft YaHei UI", 11, [Drawing.FontStyle]::Bold)
  $form.Controls.Add($lblTitle)

  # 勾选列表
  $chk = New-Object Windows.Forms.CheckedListBox
  $chk.Location = New-Object Drawing.Point(14, 40); $chk.Size = New-Object Drawing.Size(780, 300)
  $chk.BackColor = $fieldBg; $chk.ForeColor = $fg
  $chk.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
  $chk.CheckOnClick = $false
  $form.Controls.Add($chk)

  # 风险说明框
  $txtNote = New-Object Windows.Forms.TextBox
  $txtNote.Location = New-Object Drawing.Point(14, 346); $txtNote.Size = New-Object Drawing.Size(780, 70)
  $txtNote.Multiline = $true; $txtNote.ScrollBars = "Vertical"; $txtNote.ReadOnly = $true
  $txtNote.BackColor = $panelBg; $txtNote.ForeColor = $fg
  $txtNote.Font = New-Object Drawing.Font("Microsoft YaHei UI", 9)
  $txtNote.Text = "将鼠标移到项目上可看风险说明；勾选后点「备份并清理」会再次要求确认，确认前不会删除任何文件。"
  $form.Controls.Add($txtNote)

  # 备份盘选择
  $lblDrive = New-Object Windows.Forms.Label
  $lblDrive.Text = "备份到（删除前先备份，防误删）："; $lblDrive.Location = New-Object Drawing.Point(14, 424)
  $lblDrive.Size = New-Object Drawing.Size(240, 22); $lblDrive.ForeColor = $fg
  $form.Controls.Add($lblDrive)

  $cmbDrive = New-Object Windows.Forms.ComboBox
  $cmbDrive.Location = New-Object Drawing.Point(254, 420); $cmbDrive.Size = New-Object Drawing.Size(300, 24)
  $cmbDrive.BackColor = $fieldBg; $cmbDrive.ForeColor = $fg; $cmbDrive.DropDownStyle = "DropDownList"
  $cmbDrive.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
  $form.Controls.Add($cmbDrive)

  # 高级项
  $chkAdv = New-Object Windows.Forms.CheckBox
  $chkAdv.Text = "显示高级项（含休眠文件 hiberfil.sys 等高风险项）"
  $chkAdv.Location = New-Object Drawing.Point(570, 422); $chkAdv.Size = New-Object Drawing.Size(224, 22)
  $chkAdv.ForeColor = $yelCol; $chkAdv.Font = New-Object Drawing.Font("Microsoft YaHei UI", 9)
  $form.Controls.Add($chkAdv)

  # 日志框
  $txtLog = New-Object Windows.Forms.TextBox
  $txtLog.Location = New-Object Drawing.Point(14, 452); $txtLog.Size = New-Object Drawing.Size(780, 70)
  $txtLog.Multiline = $true; $txtLog.ScrollBars = "Vertical"; $txtLog.ReadOnly = $true
  $txtLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20); $txtLog.ForeColor = $okCol
  $txtLog.Font = New-Object Drawing.Font("Consolas", 9)
  $form.Controls.Add($txtLog)

  # 按钮
  $btnScan = New-Object Windows.Forms.Button
  $btnScan.Text = "重新扫描"; $btnScan.Size = New-Object Drawing.Size(100, 30)
  $btnScan.Location = New-Object Drawing.Point(14, 534); $btnScan.BackColor = $accent; $btnScan.ForeColor = $accentFg
  $btnScan.FlatStyle = "Flat"; $btnScan.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
  $form.Controls.Add($btnScan)

  $btnClean = New-Object Windows.Forms.Button
  $btnClean.Text = "备份并清理"; $btnClean.Size = New-Object Drawing.Size(120, 30)
  $btnClean.Location = New-Object Drawing.Point(124, 534); $btnClean.BackColor = $okCol; $btnClean.ForeColor = [System.Drawing.Color]::FromArgb(20,20,20)
  $btnClean.FlatStyle = "Flat"; $btnClean.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10, [Drawing.FontStyle]::Bold)
  $btnClean.Enabled = $false
  $form.Controls.Add($btnClean)

  $btnExit = New-Object Windows.Forms.Button
  $btnExit.Text = "退出"; $btnExit.Size = New-Object Drawing.Size(100, 30)
  $btnExit.Location = New-Object Drawing.Point(694, 534); $btnExit.BackColor = $accent; $btnExit.ForeColor = $accentFg
  $btnExit.FlatStyle = "Flat"; $btnExit.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
  $form.Controls.Add($btnExit)

  $script:guiScan = $null
  $script:guiIds = @()      # 与 chk 项一一对应的类别 Id（CheckedListBox 字符串项无 Tag）
  $script:driveLetters = @() # 与 cmbDrive 项一一对应的盘符（首项为 $null=不备份）
  function Log($m) { $txtLog.AppendText($m + "`r`n"); $txtLog.ScrollToCaret() }

  function Populate-List {
    $chk.Items.Clear(); $script:guiIds = @()
    $adv = $chkAdv.Checked
    $script:guiScan = Invoke-SafeScan -Advanced:$adv
    $total = 0
    foreach ($r in $script:guiScan) {
      $sz = Format-Bytes $r.SizeBytes
      $line = ("[{0}] {1}  ——  {2}（{3:N0} 个文件）" -f $r.Risk, $r.Name, $sz, $r.FileCount)
      $idx = $chk.Items.Add($line)
      $script:guiIds += $r.Id
      # 默认勾选：非高级、且占用>0 的项
      if (-not $r.Advanced -and $r.SizeBytes -gt 0) { $chk.SetItemChecked($idx, $true) }
      $total += $r.SizeBytes
    }
    Log ("扫描完成：共可清理约 {0}（仅系统垃圾）。请勾选要清理的项，确认前不会删除任何文件。" -f (Format-Bytes $total))
    Update-CleanEnabled
  }

  function Refresh-Drives {
    $cmbDrive.Items.Clear(); $script:driveLetters = @($null)
    $cmbDrive.Items.Add("不备份（直接删除，不推荐）") | Out-Null
    foreach ($d in (Get-BackupDrives)) {
      $tag = if ($d.Removable) { '（U盘）' } else { '' }
      $free = Format-Bytes $d.FreeBytes
      $cmbDrive.Items.Add(("{0}  {1} {2}  剩余 {3}" -f $d.Letter, $d.Label, $tag, $free)) | Out-Null
      $script:driveLetters += $d.Letter
    }
    if ($cmbDrive.Items.Count -gt 1) { $cmbDrive.SelectedIndex = 1 } else { $cmbDrive.SelectedIndex = 0 }
  }

  function Selected-Ids { $chk.CheckedIndices | ForEach-Object { $script:guiIds[$_] } }

  function Update-CleanEnabled { $btnClean.Enabled = ($chk.CheckedIndices.Count -gt 0) }

  $chk.Add_SelectedIndexChanged({
    $i = $chk.SelectedIndex
    if ($i -ge 0) {
      $id = $script:guiIds[$i]
      $r = $script:guiScan | Where-Object { $_.Id -eq $id }
      if ($r) { $txtNote.Text = ("【{0}】风险等级：{1}`n说明：{2}" -f $r.Name, $r.Risk, $r.RiskNote) }
    }
  })
  $chk.Add_ItemCheck({ Update-CleanEnabled })
  $chkAdv.Add_CheckedChanged({ Populate-List })
  $btnScan.Add_Click({ Populate-List; Refresh-Drives })
  $btnExit.Add_Click({ $form.Close() })

  $btnClean.Add_Click({
    $ids = @(Selected-Ids)
    if ($ids.Count -eq 0) { [Windows.Forms.MessageBox]::Show("请先勾选要清理的项目。", "提示", 'OK', 'Information'); return }
    $advList = ($script:guiScan | Where-Object { $_.Id -in $ids -and $_.Advanced }).Name
    $msg = "即将清理以下 {0} 类系统垃圾（删除前会先备份）：`n  - {1}" -f $ids.Count, (($script:guiScan | Where-Object { $_.Id -in $ids } | ForEach-Object { $_.Name }) -join "`n  - ")
    if ($advList) { $msg += "`n`n⚠ 包含高风险项：$($advList -join '、')，请确认已了解后果。" }
    $msg += "`n`n确认删除？此操作不可撤销（但可从备份恢复）。"
    $r = [Windows.Forms.MessageBox]::Show($msg, "最终确认", 'YesNo', 'Warning')
    if ($r -ne 'Yes') { Log "已取消，未删除任何文件。"; return }

    $backupDir = $null
    if ($cmbDrive.SelectedIndex -gt 0 -and $script:driveLetters[$cmbDrive.SelectedIndex]) {
      $drv = $script:driveLetters[$cmbDrive.SelectedIndex]
      Log ("正在备份到 {0} …" -f $drv)
      try {
        $bk = Invoke-Backup -ScanResults $script:guiScan -SelectedIds $ids -BackupRoot $drv
        $backupDir = $bk.BackupDir
        Log ("备份完成（{0} 项），备份目录：{1}" -f $bk.ItemCount, $backupDir)
        Log ("如需恢复：双击 {0}\restore.ps1 ，详见 恢复说明.txt" -f $backupDir)
      } catch {
        Log ("备份失败：$($_.Exception.Message)`n将改为直接清理（无备份）。" ); $backupDir = $null
      }
    } else {
      Log "未选择备份盘，将直接删除（不推荐）。如担心误删，请先选备份盘。"
    }

    Log "开始清理…"
    $rep = Invoke-Cleanup -ScanResults $script:guiScan -SelectedIds $ids -BackupDir $backupDir
    Log ("清理完成：成功 {0} 项，失败 {1} 项。" -f $rep.DeletedCount, $rep.FailedCount)
    foreach ($f in $rep.Failed) { Log ("  ✗ 失败：{0} —— {1}" -f $f.Name, $f.Error) }
    if ($rep.Health.Healthy) { Log "✔ 系统健康检查通过。" }
    else {
      Log "✗ 系统健康检查未通过："
      $rep.Health.Details | ForEach-Object { Log ("   - {0}" -f $_) }
      if ($rep.AutoRestored) { Log "已从备份自动还原，请重启确认。" }
    }
    [Windows.Forms.MessageBox]::Show("清理完成：成功 $($rep.DeletedCount) 项，失败 $($rep.FailedCount) 项。`n系统健康：$(if($rep.Health.Healthy){'通过'}else{'异常'}).", "完成", 'OK', 'Information')
  })

  Refresh-Drives
  Populate-List
  [Windows.Forms.Application]::EnableVisualStyles() | Out-Null
  $form.ShowDialog() | Out-Null
}

# ===================================================================
#  命令行向导
# ===================================================================
function Start-Cli {
  $adv = $Advanced
  Write-Host "`n===== 金网通 · C盘瘦身（系统垃圾清理）=====" -ForegroundColor Cyan
  Write-Host "说明：仅清理系统产生的垃圾，不碰您的文档/企业文件/应用数据。删除前可备份、可跳过。" -ForegroundColor DarkGray

  if ($TaskFile -and (Test-Path $TaskFile)) {
    $plan = Get-Content $TaskFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ("控制台已下发清理预览（创建于 {0}）。以下为待确认项：" -f $plan.Created) -ForegroundColor Yellow
    $scan = $plan.Scan
    $adv = [bool]$plan.Advanced
  } else {
    Write-Host "正在扫描系统垃圾（只读，不删除）…" -ForegroundColor Cyan
    $scan = Invoke-SafeScan -Advanced:$adv
  }

  $total = 0
  Write-Host ("`n{0,-6}{1,-22}{2,-14}{3,-12}{4}" -f "序号", "项目", "风险", "可清理", "说明") -ForegroundColor White
  Write-Host ("-" * 90) -ForegroundColor DarkGray
  $i = 0
  foreach ($r in $scan) {
    $i++
    $riskCol = if ($r.Risk -eq '高') { 'Red' } elseif ($r.Risk -eq '中') { 'Yellow' } else { 'Green' }
    Write-Host ("{0,-6}{1,-22}{2,-14}{3,-12}{4}" -f $i, $r.Name, $r.Risk, (Format-Bytes $r.SizeBytes), ($r.RiskNote.Substring(0, [Math]::Min(28, $r.RiskNote.Length)))) -ForegroundColor $riskCol
    $total += $r.SizeBytes
  }
  Write-Host ("-" * 90) -ForegroundColor DarkGray
  Write-Host ("合计可清理： {0}（仅系统垃圾，不含任何个人/企业数据）" -f (Format-Bytes $total)) -ForegroundColor Cyan

  if ($ScanOnly) {
    Write-Host "`n[ScanOnly] 仅扫描完成，未删除任何文件。" -ForegroundColor Green
    return
  }

  # 选择类别
  if ($Categories -and $Categories.Count -gt 0) {
    $sel = @($Categories)
  } else {
    $default = ($scan | Where-Object { -not $_.Advanced -and $_.SizeBytes -gt 0 }).Id
    Write-Host "`n默认勾选非高级且有占用的项：$($default -join ', ')" -ForegroundColor DarkGray
    Write-Host "请选择要清理的项（输入序号逗号分隔，如 1,2,5；all=全部；回车=默认；none=取消）：" -ForegroundColor White
    $ans = Read-Host "选择"
    if ($ans.Trim() -eq '') { $sel = $default }
    elseif ($ans.Trim() -eq 'none') { Write-Host "已取消。"; return }
    elseif ($ans.Trim() -eq 'all') { $sel = $scan.Id }
    else {
      $idxs = $ans.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
      $sel = @(); foreach ($n in $idxs) { if ([int]$n -ge 1 -and [int]$n -le $scan.Count) { $sel += $scan[[int]$n - 1].Id } }
    }
  }
  if ($sel.Count -eq 0) { Write-Host "未选择任何项，已退出。" -ForegroundColor Yellow; return }

  # 备份盘
  $backupDir = $null
  if ($NoBackup) {
    Write-Host "⚠ 已选择不备份直接删除（不推荐）。" -ForegroundColor Yellow
  } else {
    if (-not $BackupDrive) {
      $drives = @(Get-BackupDrives)
      Write-Host "`n可用备份盘：" -ForegroundColor White
      for ($k = 0; $k -lt $drives.Count; $k++) { Write-Host ("  {0}. {1} ({2}, 剩余 {3})" -f ($k+1), $drives[$k].Letter, $drives[$k].Label, (Format-Bytes $drives[$k].FreeBytes)) -ForegroundColor DarkGray }
      Write-Host "  0. 不备份直接删除（不推荐）" -ForegroundColor DarkGray
      $bi = Read-Host "选择备份盘序号（0=不备份）"
      if ($bi -match '^\d+$' -and [int]$bi -ge 1 -and [int]$bi -le $drives.Count) { $BackupDrive = $drives[[int]$bi - 1].Letter }
    }
    if ($BackupDrive) {
      Write-Host ("将先备份到 {0} …" -f $BackupDrive) -ForegroundColor Cyan
      $bk = Invoke-Backup -ScanResults $scan -SelectedIds $sel -BackupRoot $BackupDrive
      $backupDir = $bk.BackupDir
      Write-Host ("备份完成（{0} 项）→ {1}" -f $bk.ItemCount, $backupDir) -ForegroundColor Green
      Write-Host ("如需恢复：双击 {0}\restore.ps1 ，或查看 恢复说明.txt" -f $backupDir) -ForegroundColor DarkGray
    }
  }

  # 最终确认
  if (-not $Yes) {
    Write-Host "`n即将删除以下项目（仅系统垃圾）：" -ForegroundColor Yellow
    $scan | Where-Object { $_.Id -in $sel } | ForEach-Object { Write-Host ("  - [{0}] {1}（{2}）" -f $_.Risk, $_.Name, (Format-Bytes $_.SizeBytes)) -ForegroundColor White }
    $go = Read-Host "确认删除？(输入 YES 执行，其它取消)"
    if ($go -ne 'YES') { Write-Host "已取消，未删除任何文件。" -ForegroundColor Green; return }
  }

  Write-Host "`n开始清理…" -ForegroundColor Cyan
  $rep = Invoke-Cleanup -ScanResults $scan -SelectedIds $sel -BackupDir $backupDir
  Write-Host ("`n清理完成：成功 {0} 项，失败 {1} 项。" -f $rep.DeletedCount, $rep.FailedCount) -ForegroundColor Green
  foreach ($f in $rep.Failed) { Write-Warning ("失败：{0} —— {1}" -f $f.Name, $f.Error) }
  if ($rep.Health.Healthy) { Write-Host "✔ 系统健康检查通过。" -ForegroundColor Green }
  else {
    Write-Host "✗ 系统健康检查未通过：" -ForegroundColor Red
    $rep.Health.Details | ForEach-Object { Write-Host ("   - {0}" -f $_) -ForegroundColor Red }
    if ($rep.AutoRestored) { Write-Host "已从备份自动还原，请重启电脑确认。" -ForegroundColor Yellow }
  }
}

# ---------- 启动 ----------
if ($useGui) {
  try { Start-Gui } catch {
    Write-Warning "图形界面初始化失败（可能无桌面环境）：$_ 将改用命令行模式。"
    $Cli = $true; Start-Cli
  }
} else {
  Start-Cli
}
