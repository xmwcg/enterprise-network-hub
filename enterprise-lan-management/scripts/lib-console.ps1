<#
.SYNOPSIS  集中控制台共享库（M3）：设备注册表 + 任务队列 + 共享数据读取
.DESCRIPTION
  无外部依赖（JSON 文件存储）。控制台与终端代理(agent)共用本库。
  生产环境可把 JSON 文件存储替换为 SQLite/真实数据库（见《商业闭环后续开发方案》M5）。
  本文件被 dot-source 时仅提供函数，不执行主体。
#>
param()

$script:ConsoleDefaultPort = 8080

function Get-ConsoleConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigFile = ".\company-config.json",
        [int]$Port
    )
    $fs = $null
    if (Test-Path $ConfigFile) {
        try {
            $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            if ($cfg.FileServer -and $cfg.FileServer -ne "AUTO") { $fs = $cfg.FileServer }
        } catch { }
    }
    # 中心存储：默认本地 console-data（多控制台场景可用 -DataDir 指向共享 UNC）
    $root = Join-Path $PSScriptRoot "console-data"
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    if (-not $Port) { $Port = $script:ConsoleDefaultPort }

    # 管理员令牌（首次运行生成并持久化）
    $tokFile = Join-Path $root "console.token"
    if (-not (Test-Path $tokFile)) {
        Set-Content -Path $tokFile -Value ([guid]::NewGuid().ToString()) -Encoding UTF8
    }
    [PSCustomObject]@{
        RootDir        = $root
        Port           = $Port
        Token          = (Get-Content $tokFile -Raw -Encoding UTF8).Trim()
        FileServerHost = $fs
    }
}

function Read-JsonFile {
    param([string]$Path, $Default = $null)
    if (-not (Test-Path $Path)) { return $Default }
    try { return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $Default }
}

function Write-JsonFile {
    param([string]$Path, $Object)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Object | ConvertTo-Json -Depth 8 -Compress | Set-Content -Path $Path -Encoding UTF8
}

# ---------- 设备注册表 ----------
function Get-DeviceList {
    param([string]$RootDir)
    $dir = Join-Path $RootDir "devices"
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem $dir -Filter *.json | ForEach-Object { Read-JsonFile $_.FullName @{} }
}

function Register-Device {
    param([string]$RootDir, [PSObject]$Device)
    $dir = Join-Path $RootDir "devices"
    $id = if ($Device.Id) { $Device.Id } else { $Device.ComputerName }
    if (-not $id) { return $null }
    $file = Join-Path $dir "$id.json"
    $existing = Read-JsonFile $file $null
    $tok = if ($existing -and $existing.Token) { $existing.Token } else { [guid]::NewGuid().ToString() }
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $rec = [ordered]@{
        Id           = $id
        ComputerName = if ($Device.ComputerName) { $Device.ComputerName } else { $id }
        IP           = $Device.IP
        OS           = $Device.OS
        Edition      = $Device.Edition
        IsFileServer = [bool]$Device.IsFileServer
        Token        = $tok
        Status       = 'online'
        LastSeen     = $now
        FirstSeen    = if ($existing) { $existing.FirstSeen } else { $now }
    }
    Write-JsonFile $file $rec
    return $rec
}

function Update-DeviceHeartbeat {
    param([string]$RootDir, [string]$Id, [string]$Status = 'online')
    $file = Join-Path $RootDir "devices\$Id.json"
    $rec = Read-JsonFile $file $null
    if (-not $rec) { return $false }
    $rec.LastSeen = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $rec.Status = $Status
    Write-JsonFile $file $rec
    return $true
}

# ---------- 任务队列 ----------
function New-Task {
    param(
        [string]$RootDir,
        [string]$Type,
        [string]$PayloadJson,
        [string[]]$Targets = @('ALL'),
        [string]$Creator = 'console'
    )
    $id = "T" + (Get-Date -Format 'yyyyMMddHHmmss') + "-" + [guid]::NewGuid().ToString().Substring(0, 4)
    $items = @()
    if ($Targets -contains 'ALL' -or $Targets.Count -eq 0) {
        foreach ($d in (Get-DeviceList -RootDir $RootDir)) {
            $items += [ordered]@{ DeviceId = $d.Id; Status = 'pending'; Result = $null; Updated = $null }
        }
    } else {
        foreach ($t in $Targets) {
            $items += [ordered]@{ DeviceId = $t; Status = 'pending'; Result = $null; Updated = $null }
        }
    }
    $task = [ordered]@{
        Id      = $id
        Type    = $Type
        Payload = $PayloadJson
        Targets = @($Targets)
        Creator = $Creator
        Created = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Status  = if ($items.Count -eq 0) { 'empty' } else { 'active' }
        Items   = $items
    }
    Write-JsonFile (Join-Path $RootDir "tasks\$id.json") $task
    return $task
}

function Get-TaskList {
    param([string]$RootDir)
    $dir = Join-Path $RootDir "tasks"
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem $dir -Filter *.json | ForEach-Object { Read-JsonFile $_.FullName @{} } |
        Sort-Object { $_.Created } -Descending
}

function Get-TaskDetail {
    param([string]$RootDir, [string]$Id)
    return Read-JsonFile (Join-Path $RootDir "tasks\$Id.json") $null
}

function Claim-AgentTask {
    param([string]$RootDir, [string]$DeviceId)
    foreach ($t in (Get-TaskList -RootDir $RootDir)) {
        if ($t.Status -notin @('active')) { continue }
        foreach ($it in $t.Items) {
            if ($it.DeviceId -eq $DeviceId -and $it.Status -eq 'pending') {
                $it.Status = 'running'
                $it.Updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                Write-JsonFile (Join-Path $RootDir "tasks\$($t.Id).json") $t
                return [ordered]@{
                    TaskId  = $t.Id
                    Item    = $it
                    Type    = $t.Type
                    Payload = $t.Payload
                }
            }
        }
    }
    return $null
}

function Report-TaskResult {
    param([string]$RootDir, [string]$TaskId, [string]$DeviceId, [PSObject]$Result, [string]$Status = 'done')
    $f = Join-Path $RootDir "tasks\$TaskId.json"
    $t = Read-JsonFile $f $null
    if (-not $t) { return $false }
    foreach ($it in $t.Items) {
        if ($it.DeviceId -eq $DeviceId) {
            $it.Status = $Status
            $it.Result = $Result
            $it.Updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
    }
    $closed = ($t.Items | Where-Object { $_.Status -eq 'done' -or $_.Status -eq 'failed' }).Count
    if ($closed -eq $t.Items.Count) { $t.Status = 'completed' }
    Write-JsonFile $f $t
    return $true
}

# ---------- 兼容既有 Mgmt$ 共享数据（deploy.ps1 / manager.ps1 产出） ----------
function Get-InventoryFromShare {
    param([string]$FileServerHost)
    if (-not $FileServerHost) { return @() }
    $dir = "\\$FileServerHost\Mgmt$\hosts"
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem $dir -Filter *.json | ForEach-Object { Read-JsonFile $_.FullName @{} }
}

function Get-AuditFromShare {
    param([string]$FileServerHost, [int]$Last = 50)
    if (-not $FileServerHost) { return @() }
    $dir = "\\$FileServerHost\Mgmt$\audit"
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem $dir -Filter *.json | Sort-Object LastWriteTime -Descending |
        Select-Object -First $Last | ForEach-Object { Read-JsonFile $_.FullName @{} }
}

function Get-NetPolicyFromShare {
    param([string]$FileServerHost)
    if (-not $FileServerHost) { return @() }
    $dir = "\\$FileServerHost\Mgmt$\netpolicy"
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem $dir -Filter *.json | ForEach-Object { Read-JsonFile $_.FullName @{} }
}
