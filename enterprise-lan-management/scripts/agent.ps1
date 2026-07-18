<#
.SYNOPSIS  终端代理（M3）：向控制台注册、拉取并执行任务、上报结果
.DESCRIPTION
  在每台终端（被管控电脑）以管理员运行一次启动，之后常驻轮询控制台的任务队列。
  支持任务类型：
    · command  - 在本地执行一段 PowerShell 命令（Payload.command）
    · netpolicy- 本地应用上网策略（Payload.policy=allow|deny, Payload.hardcut）
    · netcheck - 本地执行网络体检
  复用本仓库 netpolicy.ps1 / netcheck.ps1 的成熟函数，保证与 manager.ps1 行为一致。
.PARAMETER ConsoleUrl  控制台地址（默认 http://localhost:8080）
.PARAMETER Token       管理员令牌（与控制台启动时打印的一致；注册/上报需携带）
.PARAMETER IntervalSec 轮询间隔秒（默认 15）
.PARAMETER NoLoop      只处理一轮即退出（便于调试/一次性执行）
#>
[CmdletBinding()]
param(
    [string]$ConsoleUrl = 'http://localhost:8080',
    [string]$Token,
    [int]$IntervalSec = 15,
    [switch]$NoLoop
)
. .\lib-init.ps1
. .\lib-console.ps1
. .\netpolicy.ps1
. .\netcheck.ps1

if ($MyInvocation.InvocationName -ne '.') { Request-AdminOrElevate -ScriptPath $PSCommandPath -Bound $PSBoundParameters -Unbound $args }

if (-not $Token) { Write-Error "请提供 -Token（控制台启动时打印的管理员令牌）。"; exit 1 }

# ---------- 采集本机信息并注册 ----------
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.PrefixLength -lt 32 } | Select-Object -First 1).IPAddress
$self = [ordered]@{
    ComputerName = $env:COMPUTERNAME
    IP           = $ip
    OS           = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    Edition      = (Get-ComputerInfo -ErrorAction SilentlyContinue).WindowsEditionId
    IsFileServer = $false
}
$regBody = $self | ConvertTo-Json -Compress
try {
    $reg = Invoke-RestMethod -Uri "$ConsoleUrl/api/agent/register" -Method Post `
        -Body $regBody -ContentType 'application/json' `
        -Headers @{ 'X-Console-Token' = $Token } -TimeoutSec 15 -ErrorAction Stop
} catch {
    Write-Error "注册失败：$_"; exit 1
}
$devId = $reg.Id
Write-Host "已向控制台注册： $devId  (令牌已记录，后续轮询自动携带)" -ForegroundColor Green

# ---------- 任务执行 ----------
function Invoke-AgentTask {
    param([PSObject]$Task)
    $type = $Task.Type
    $payload = $Task.Payload | ConvertFrom-Json
    $out = [ordered]@{ Type = $type; ExecutedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
    try {
        switch ($type) {
            'command' {
                $sb = [ScriptBlock]::Create($payload.command)
                $res = & $sb 2>&1 | Out-String
                $out.Output = $res
            }
            'netpolicy' {
                $block = ($payload.policy -eq 'deny')
                $r = Set-InternetPolicy -Block $block -HardCut:([bool]$payload.hardcut)
                $out.Policy = $r.Policy; $out.IP = $r.IP; $out.MAC = $r.MAC
            }
            'netcheck' {
                $r = Invoke-NetCheck
                $out.Score = $r.Score; $out.Fail = $r.Fail; $out.Warn = $r.Warn
            }
            default { $out.Error = "不支持的任务类型：$type" }
        }
        $out.Success = $true
    } catch {
        $out.Success = $false
        $out.Error = $_.Exception.Message
    }
    return $out
}

Write-Host "开始轮询任务队列（间隔 $IntervalSec 秒）... 按 Ctrl+C 退出。" -ForegroundColor DarkGray
do {
    try {
        $task = Invoke-RestMethod -Uri "$ConsoleUrl/api/agent/tasks?device=$devId" -Method Get `
            -Headers @{ 'X-Console-Token' = $Token } -TimeoutSec 15 -ErrorAction Stop
    } catch {
        Write-Warning "轮询失败：$_"; Start-Sleep -Seconds $IntervalSec; continue
    }
    if ($task.empty -or -not $task.TaskId) {
        Start-Sleep -Seconds $IntervalSec; continue
    }
    Write-Host ("拉取到任务 {0}（类型={1}），执行中..." -f $task.TaskId, $task.Type) -ForegroundColor Cyan
    $result = Invoke-AgentTask -Task $task
    $status = if ($result.Success) { 'done' } else { 'failed' }
    $body = [ordered]@{ TaskId = $task.TaskId; DeviceId = $devId; Status = $status; Result = $result } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri "$ConsoleUrl/api/agent/tasks/result" -Method Post `
            -Body $body -ContentType 'application/json' `
            -Headers @{ 'X-Console-Token' = $Token } -TimeoutSec 15 -ErrorAction Stop | Out-Null
        Write-Host ("任务 {0} 已上报结果： {1}" -f $task.TaskId, $status) -ForegroundColor Green
    } catch {
        Write-Warning "结果上报失败：$_"
    }
    if (-not $NoLoop) { Start-Sleep -Seconds $IntervalSec }
} while (-not $NoLoop)
