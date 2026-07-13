<#
.SYNOPSIS  统一管控：读取中心清单，批量远程执行 / 推送文件 / 执行脚本 / 收集资产并审计
.DESCRIPTION
  在管理机上以管理员运行。使用 company-config.json 中的管理账号，通过 WinRM 与每台
  已上报的电脑通信（基于 deploy.ps1 自动采集并上报的信息）。所有管控动作均写入审计日志。
.PARAMETER Command         要在每台电脑上执行的脚本块（默认：取系统版本与开机时间）
.PARAMETER ListOnly        仅列出已发现主机，不执行命令
.PARAMETER FileServerHost  显式指定文件服务器主机名（当配置为 AUTO 时需要）
.PARAMETER CollectInventory 一键收集全网清单并导出 Excel（.xlsx，优先 Import-Excel / COM Excel，降级 CSV）
.PARAMETER ExportPath      导出文件路径（默认 .\Inventory_<日期>.xlsx）
.PARAMETER Online          收集时通过 WinRM 实时拉取在线状态与开机时间（默认开启）
.PARAMETER PushFile        批量推送本地文件到每台远程 C:\Temp（配合 -FilePath；-Run 可远程执行）
.PARAMETER FilePath        要推送的本地文件路径
.PARAMETER Run             推送后远程执行该文件
.PARAMETER RunArgs         远程执行时的参数
.PARAMETER ScriptFile      批量在每台远程执行指定本地脚本文件（配合 -ScriptFilePath）
.PARAMETER ScriptFilePath  要批量执行的本地 .ps1 路径
.PARAMETER NetPolicy       批量上网管控：allow=全网恢复上网 / deny=全网禁止上网
.PARAMETER HardCut         配合 -NetPolicy deny：一并阻塞 DNS(53) 实现硬断网
.PARAMETER NetCheck        批量对全网执行网络体检，结果写入中心 Mgmt$\netcheck
.PARAMETER NetReport       汇总查看全网"上网策略"与"网络体检"两张报表
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = ".\company-config.json",
    [ScriptBlock]$Command = { Get-CimInstance Win32_OperatingSystem | Select-Object Caption, LastBootUpTime },
    [switch]$ListOnly,
    [string]$FileServerHost,
    [switch]$CollectInventory,
    [string]$ExportPath,
    [switch]$Online = $true,
    [switch]$PushFile,
    [string]$FilePath,
    [switch]$Run,
    [string]$RunArgs,
    [switch]$ScriptFile,
    [string]$ScriptFilePath,
    [ValidateSet('allow', 'deny')][string]$NetPolicy,
    [switch]$HardCut,
    [switch]$NetCheck,
    [switch]$NetReport
)
. .\lib-init.ps1
. .\lib-discovery.ps1
. .\lib-audit.ps1
. .\netpolicy.ps1
. .\netcheck.ps1

# 权限最大化：非管理员自动提权（UAC 由用户确认，即"用户决策"）
if ($MyInvocation.InvocationName -ne '.') { Request-AdminOrElevate -ScriptPath $PSCommandPath -Bound $PSBoundParameters -Unbound $args }
$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$fs = if ($FileServerHost) { $FileServerHost } elseif ($cfg.FileServer -ne "AUTO") { $cfg.FileServer } else { $null }
if (-not $fs) { Write-Error "AUTO 模式下需通过 -FileServerHost 指定文件服务器，或把配置改为固定主机名。"; exit 1 }

$sec = Read-Host -Prompt "管理账号 [$($cfg.MgmtUser)] 密码" -AsSecureString
$cred = New-Object System.Management.Automation.PSCredential($cfg.MgmtUser, $sec)

function Get-HostList {
    $mgmt = "\\$fs\Mgmt$"
    $hostDir = "$mgmt\hosts"
    if (Test-Path $hostDir) {
        Get-ChildItem $hostDir -Filter *.json | ForEach-Object { Get-Content $_.FullName | ConvertFrom-Json }
    } else { Write-Warning "未找到 $hostDir，可能各机尚未运行 deploy.ps1 上报。"; @() }
}

# ---------- 收集全网资产并导出 Excel ----------
if ($CollectInventory) {
    $rows = @()
    $hosts = Get-HostList
    foreach ($h in $hosts) {
        $row = [ordered]@{
            主机名        = $h.ComputerName
            IP            = $h.IP
            系统          = $h.OS
            版本          = $h.Edition
            RDP主机支持   = if ($h.RDP_HostOK) { "是" } else { "否(家庭版)" }
            网关          = $h.Gateway
            DNS           = ($h.DNS -join ', ')
            文件服务器    = if ($h.IsFileServer) { "是" } else { "否" }
            在线          = ""
            开机时间      = ""
            上次上报      = ""
        }
        $f = Get-ChildItem "\\$fs\Mgmt$\hosts" -Filter "$($h.ComputerName).json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { $row.上次上报 = (Get-Date $f.LastWriteTime -Format 'yyyy-MM-dd HH:mm') }
        if ($Online) {
            $target = if ($h.IP) { $h.IP } else { $h.ComputerName }
            try {
                $r = Invoke-Command -ComputerName $target -Credential $cred -ScriptBlock {
                    $os = Get-CimInstance Win32_OperatingSystem
                    [PSCustomObject]@{ Online = $true; Boot = (Get-Date $os.LastBootUpTime -Format 'yyyy-MM-dd HH:mm') }
                } -ErrorAction Stop
                $row.在线 = "是"; $row.开机时间 = $r.Boot
            } catch { $row.在线 = "否 / 不可达" }
        }
        $rows += $row
    }
    if ($rows.Count -eq 0) { Write-Host "没有可收集的主机记录。" -ForegroundColor Yellow; return }
    if (-not $ExportPath) { $ExportPath = ".\Inventory_$(Get-Date -Format 'yyyyMMdd_HHmm').xlsx" }
    Export-Inventory -Rows $rows -Path $ExportPath
    Write-Audit -FileServerHost $fs -Entry @{ Target = "ALL"; Action = "CollectInventory"; Count = $rows.Count; Result = "OK" }
    return
}

# ---------- 批量推送文件 ----------
if ($PushFile) {
    if (-not $FilePath -or -not (Test-Path $FilePath)) { Write-Error "请提供有效的 -FilePath。"; exit 1 }
    $hosts = Get-HostList
    $ok = 0; $fail = 0; $leaf = Split-Path $FilePath -Leaf
    foreach ($h in $hosts) {
        $target = if ($h.IP) { $h.IP } else { $h.ComputerName }
        try {
            $sess = New-PSSession -ComputerName $target -Credential $cred -ErrorAction Stop
            Copy-Item -Path $FilePath -Destination "C:\Temp\" -ToSession $sess -ErrorAction Stop
            if ($Run) {
                Invoke-Command -Session $sess -ScriptBlock { param($f, $a) & "C:\Temp\$f" $a } -ArgumentList $leaf, $RunArgs -ErrorAction Stop
            }
            Remove-PSSession $sess
            Write-Host "OK   push $target" -ForegroundColor Green; $ok++
        } catch { Write-Warning "FAIL $target : $($_.Exception.Message)"; $fail++ }
    }
    Write-Audit -FileServerHost $fs -Entry @{ Target = "ALL"; Action = "PushFile"; File = $leaf; Run = $Run; Ok = $ok; Fail = $fail }
    return
}

# ---------- 批量执行脚本文件 ----------
if ($ScriptFile) {
    if (-not $ScriptFilePath -or -not (Test-Path $ScriptFilePath)) { Write-Error "请提供有效的 -ScriptFilePath。"; exit 1 }
    $hosts = Get-HostList
    $ok = 0; $fail = 0; $leaf = Split-Path $ScriptFilePath -Leaf
    foreach ($h in $hosts) {
        $target = if ($h.IP) { $h.IP } else { $h.ComputerName }
        try {
            Invoke-Command -ComputerName $target -Credential $cred -FilePath $ScriptFilePath -ErrorAction Stop
            Write-Host "OK   $target" -ForegroundColor Green; $ok++
        } catch { Write-Warning "FAIL $target : $($_.Exception.Message)"; $fail++ }
    }
    Write-Audit -FileServerHost $fs -Entry @{ Target = "ALL"; Action = "ScriptFile"; File = $leaf; Ok = $ok; Fail = $fail }
    return
}

# ---------- 批量上网管控 ----------
if ($NetPolicy) {
    $block = ($NetPolicy -eq 'deny')
    $hosts = Get-HostList
    $ok = 0; $fail = 0
    foreach ($h in $hosts) {
        $target = if ($h.IP) { $h.IP } else { $h.ComputerName }
        try {
            $r = Set-InternetPolicy -ComputerName $target -Credential $cred -Block $block -HardCut:$HardCut
            Write-NetPolicyState -FileServerHost $fs -ComputerName $h.ComputerName -Policy $r.Policy -IP $r.IP -MAC $r.MAC
            Write-Host "$($h.ComputerName) -> $($r.Policy)" -ForegroundColor $(if ($block) { 'Red' } else { 'Green' })
            $ok++
        } catch { Write-Warning "FAIL $($h.ComputerName) ($target): $($_.Exception.Message)"; $fail++ }
    }
    Write-Audit -FileServerHost $fs -Entry @{ Target = "ALL"; Action = "NetPolicy"; Policy = $NetPolicy; HardCut = [bool]$HardCut; Ok = $ok; Fail = $fail }
    return
}

# ---------- 批量网络体检 ----------
if ($NetCheck) {
    $hosts = Get-HostList
    $ok = 0; $fail = 0
    $dir = "\\$fs\Mgmt$\netcheck"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    foreach ($h in $hosts) {
        $target = if ($h.IP) { $h.IP } else { $h.ComputerName }
        try {
            $r = Invoke-NetCheck -ComputerName $target -Credential $cred
            $r | ConvertTo-Json -Depth 5 | Set-Content -Path "$dir\$($r.ComputerName).json" -Encoding UTF8 -ErrorAction SilentlyContinue
            $color = if ($r.Fail -gt 0) { 'Red' } elseif ($r.Warn -gt 0) { 'Yellow' } else { 'Green' }
            Write-Host "$($r.ComputerName) -> $($r.Score) (FAIL=$($r.Fail) WARN=$($r.Warn))" -ForegroundColor $color
            $ok++
        } catch { Write-Warning "FAIL $($h.ComputerName) ($target): $($_.Exception.Message)"; $fail++ }
    }
    Write-Audit -FileServerHost $fs -Entry @{ Target = "ALL"; Action = "NetCheck"; Ok = $ok; Fail = $fail }
    return
}

# ---------- 汇总报表：上网策略 + 网络体检 ----------
if ($NetReport) {
    $npDir = "\\$fs\Mgmt$\netpolicy"
    Write-Host "`n--- 上网策略 ---" -ForegroundColor Cyan
    if (Test-Path $npDir) {
        Get-ChildItem $npDir -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
            Select-Object ComputerName, IP, Policy, Operator, Time | Format-Table -AutoSize
    } else { Write-Host "（暂无策略记录，可运行 -NetPolicy 或 netpolicy.ps1 生成）" -ForegroundColor Yellow }

    $ncDir = "\\$fs\Mgmt$\netcheck"
    Write-Host "`n--- 网络体检 ---" -ForegroundColor Cyan
    if (Test-Path $ncDir) {
        Get-ChildItem $ncDir -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
            Select-Object ComputerName, IP, Score, Fail, Warn, Time | Format-Table -AutoSize
    } else { Write-Host "（暂无体检记录，可运行 -NetCheck 或 netcheck.ps1 生成）" -ForegroundColor Yellow }
    Write-Audit -FileServerHost $fs -Entry @{ Target = "ALL"; Action = "NetReport"; Result = "OK" }
    return
}

# ---------- 列出 / 默认远程命令 ----------
$hosts = Get-HostList
if ($ListOnly) {
    $hosts | Format-Table -AutoSize
    Write-Audit -FileServerHost $fs -Entry @{ Target = "ALL"; Action = "ListHosts"; Count = $hosts.Count; Result = "OK" }
    return
}

$ok = 0; $fail = 0
foreach ($h in $hosts) {
    $target = if ($h.IP) { $h.IP } else { $h.ComputerName }
    try {
        $r = Invoke-Command -ComputerName $target -Credential $cred -ScriptBlock $Command -ErrorAction Stop
        Write-Host "OK   $($h.ComputerName) ($target)" -ForegroundColor Green
        $r | Format-List | Out-String | Write-Host
        $ok++
    } catch { Write-Warning "FAIL $($h.ComputerName) ($target): $($_.Exception.Message)"; $fail++ }
}
Write-Audit -FileServerHost $fs -Entry @{ Target = "ALL"; Action = "RemoteCommand"; Ok = $ok; Fail = $fail }

# ---------- Excel 导出（被 CollectInventory 调用） ----------
function Export-Inventory($Rows, $Path) {
    $abs = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location) $Path }
    if (Get-Command Export-Excel -ErrorAction SilentlyContinue) {
        try {
            $Rows | Export-Excel -Path $abs -AutoSize -WorksheetName "资产清单" -ErrorAction Stop
            Write-Host "已用 Import-Excel 导出：$abs" -ForegroundColor Green; return
        } catch { Write-Warning "Import-Excel 导出失败，尝试 Excel COM：$_" }
    }
    try {
        $xl = New-Object -ComObject Excel.Application
        $xl.Visible = $false; $xl.DisplayAlerts = $false
        $wb = $xl.Workbooks.Add(); $ws = $wb.Worksheets.Item(1); $ws.Name = "资产清单"
        $cols = @($Rows[0].Keys)
        for ($c = 0; $c -lt $cols.Count; $c++) { $ws.Cells.Item(1, $c + 1) = [string]$cols[$c] }
        for ($r = 0; $r -lt $Rows.Count; $r++) {
            $c = 0
            foreach ($k in $cols) { $ws.Cells.Item($r + 2, $c + 1) = [string]$Rows[$r][$k]; $c++ }
        }
        $ws.UsedRange.EntireColumn.AutoFit() | Out-Null
        $wb.SaveAs($abs); $wb.Close(); $xl.Quit()
        Write-Host "已用 Excel COM 导出：$abs" -ForegroundColor Green; return
    } catch { Write-Warning "Excel COM 不可用，降级为 CSV：$_" }
    $csv = [IO.Path]::ChangeExtension($abs, ".csv")
    $Rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    Write-Host "Excel 不可用，已降级导出 CSV：$csv" -ForegroundColor Yellow
}
