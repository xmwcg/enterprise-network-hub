<#
.SYNOPSIS  集中管理控制台（M3）：本地 Web 服务 + 任务队列 + 设备注册
.DESCRIPTION
  在管理机/文件服务器上以管理员运行。启动后访问 http://localhost:<Port>/ 打开仪表盘。
  - 读取现有 Mgmt$ 资产/审计（兼容 deploy.ps1/manager.ps1 产出）；
  - 提供任务队列：创建任务后，由各终端 agent 拉取并在本地执行（netpolicy/netcheck/command）；
  - 所有写操作需管理员令牌（启动时会打印）。
.PARAMETER Port   监听端口（默认 8080）
.PARAMETER Lan    监听 0.0.0.0（局域网可访问，需 netsh urlacl 保留，脚本会提示命令）
.PARAMETER DataDir 中心数据存储目录（默认 scripts/console-data；多控制台可指向共享 UNC）
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [string]$DataDir,
    [string]$ConfigFile = ".\company-config.json",
    [switch]$Lan
)
. .\lib-init.ps1
. .\lib-license.ps1
. .\lib-console.ps1
. .\lib-console-v2.ps1

if ($MyInvocation.InvocationName -ne '.') { Request-AdminOrElevate -ScriptPath $PSCommandPath -Bound $PSBoundParameters -Unbound $args }

# 授权门禁（商业闭环：控制台属于 remotemgmt 功能权益）
$lic = Assert-License -Path $null -RequireFeature 'remotemgmt' -Quiet:$false
if (-not $lic) { exit 1 }

$cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { $null }
$fs = if ($cfg -and $cfg.FileServer -and $cfg.FileServer -ne 'AUTO') { $cfg.FileServer } else { $null }

$conf = Get-ConsoleConfig -ConfigFile $ConfigFile -Port $Port
if ($DataDir) { $conf.RootDir = $DataDir; if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null } }
$token = $conf.Token

# ---------- 启动 HTTP 监听 ----------
$listener = New-Object System.Net.HttpListener
$bind = if ($Lan) { "http://+:$Port/" } else { "http://localhost:$Port/" }
try {
    $listener.Prefixes.Add($bind)
    $listener.Start()
} catch {
    if ($Lan) {
        Write-Warning ("监听 {0} 失败：需 URL 保留。请以管理员运行以下命令后重试：`n  netsh http add urlacl url=http://+:{1}/ user=$env:USERDOMAIN\$env:USERNAME" -f $bind, $Port)
    }
    throw
}
Write-Host "集中控制台已启动： $bind" -ForegroundColor Green
Write-Host "  仪表盘： http://localhost:$Port/" -ForegroundColor Cyan
Write-Host "  管理员令牌： $token" -ForegroundColor Yellow
Write-Host "  数据目录： $($conf.RootDir)" -ForegroundColor Cyan
Write-Host "  (Ctrl+C 停止)" -ForegroundColor DarkGray

# ---------- 辅助函数 ----------
function Send-Json($ctx, $obj, $code = 200) {
    $b = [System.Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = 'application/json; charset=utf-8'
    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
    $ctx.Response.OutputStream.Close()
}
function Send-Html($ctx, $html) {
    $b = [System.Text.Encoding]::UTF8.GetBytes($html)
    $ctx.Response.ContentType = 'text/html; charset=utf-8'
    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
    $ctx.Response.OutputStream.Close()
}
function Read-Body($ctx) {
    $enc = if ($ctx.Request.ContentEncoding) { $ctx.Request.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
    $sr = New-Object System.IO.StreamReader($ctx.Request.InputStream, $enc)
    $s = $sr.ReadToEnd(); $sr.Dispose()
    return $s
}
function Check-Token($ctx) {
    $h = $ctx.Request.Headers['X-Console-Token']
    if (-not $h) { $h = if ($ctx.Request.QueryString['token']) { $ctx.Request.QueryString['token'] } else { '' } }
    return ($h -eq $token)
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $path = $req.Url.LocalPath
        $method = $req.HttpMethod
        try {
            switch -Regex ($path) {
                '^/$' {
                    $html = Get-Content (Join-Path $conf.RootDir 'dashboard.html') -Raw -Encoding UTF8
                    Send-Html $ctx $html
                    break
                }
                '^/api/status$' {
                    Send-Json $ctx ([ordered]@{
                        ok          = $true
                        fileServer  = $fs
                        port        = $Port
                        devices     = (Get-DeviceList $conf.RootDir).Count
                        tasks       = (Get-TaskList $conf.RootDir).Count
                        token       = $token
                    })
                    break
                }
                '^/api/devices$' {
                    Send-Json $ctx (Get-DeviceList $conf.RootDir)
                    break
                }
                '^/api/inventory$' {
                    Send-Json $ctx (Get-InventoryFromShare $fs)
                    break
                }
                '^/api/audit$' {
                    Send-Json $ctx (Get-AuditFromShare $fs)
                    break
                }
                '^/api/netpolicy$' {
                    Send-Json $ctx (Get-NetPolicyFromShare $fs)
                    break
                }
                '^/api/tasks$' {
                    if ($method -eq 'GET') {
                        Send-Json $ctx (Get-TaskList $conf.RootDir)
                    } elseif ($method -eq 'POST') {
                        if (-not (Check-Token $ctx)) { Send-Json $ctx @{ error = 'unauthorized' } 401; break }
                        $body = Read-Body $ctx | ConvertFrom-Json
                        $pj = if ($body.Payload) { ($body.Payload | ConvertTo-Json -Compress) } else { '{}' }
                        $tg = if ($body.Targets) { @($body.Targets) } else { @('ALL') }
                        $t = New-Task -RootDir $conf.RootDir -Type $body.Type -PayloadJson $pj -Targets $tg -Creator 'console'
                        Send-Json $ctx $t 201
                    }
                    break
                }
                '^/api/tasks/([^/]+)$' {
                    if ($method -eq 'GET') {
                        $t = Get-TaskDetail $conf.RootDir $Matches[1]
                        if ($t) { Send-Json $ctx $t } else { Send-Json $ctx @{ error = 'not found' } 404 }
                    }
                    break
                }
                '^/api/agent/register$' {
                    if ($method -eq 'POST') {
                        if (-not (Check-Token $ctx)) { Send-Json $ctx @{ error = 'unauthorized' } 401; break }
                        $d = Read-Body $ctx | ConvertFrom-Json
                        $rec = Register-Device -RootDir $conf.RootDir -Device $d
                        Send-Json $ctx $rec 201
                    }
                    break
                }
                '^/api/agent/tasks$' {
                    if ($method -eq 'GET') {
                        $dev = $req.QueryString['device']
                        $t = Claim-AgentTask -RootDir $conf.RootDir -DeviceId $dev
                        if ($t) { Send-Json $ctx $t } else { Send-Json $ctx @{ empty = $true } }
                    }
                    break
                }
                '^/api/agent/tasks/result$' {
                    if ($method -eq 'POST') {
                        if (-not (Check-Token $ctx)) { Send-Json $ctx @{ error = 'unauthorized' } 401; break }
                        $b = Read-Body $ctx | ConvertFrom-Json
                        $ok = Report-TaskResult -RootDir $conf.RootDir -TaskId $b.TaskId -DeviceId $b.DeviceId -Result $b.Result -Status $b.Status
                        Send-Json $ctx @{ ok = [bool]$ok }
                    }
                    break
                }
                # === V2 资产管理 API ===
                '^/api/v2/dashboard$' {
                    Send-Json  (Get-DashboardSummary .RootDir)
                    break
                }
                '^/api/v2/assets$' {
                    if ( -eq 'GET') {
                        Send-Json  @(Get-Assets .RootDir)
                    } elseif ( -eq 'POST') {
                        if (-not (Check-Token )) { Send-Json  @{ error = 'unauthorized' } 401; break }
                         = Read-Body  | ConvertFrom-Json
                         = Add-Asset .RootDir 
                        Send-Json   201
                    }
                    break
                }
                '^/api/v2/assets/([^/]+)$' {
                    if ( -eq 'PUT') {
                        if (-not (Check-Token )) { Send-Json  @{ error = 'unauthorized' } 401; break }
                         = Read-Body  | ConvertFrom-Json
                         = Update-Asset .RootDir [1] 
                        if () { Send-Json   } else { Send-Json  @{ error = 'not found' } 404 }
                    } elseif ( -eq 'DELETE') {
                        if (-not (Check-Token )) { Send-Json  @{ error = 'unauthorized' } 401; break }
                        Remove-Asset .RootDir [1]
                        Send-Json  @{ ok = True }
                    }
                    break
                }
                '^/api/v2/price$' {
                    if ( -eq 'POST') {
                         = Read-Body  | ConvertFrom-Json
                         = Search-Price -Keyword .keyword -Category .category
                        Send-Json  
                    }
                    break
                }
                default {
                    Send-Json $ctx @{ error = 'not found' } 404
                }
            }
        } catch {
            try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch { }
        }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Host "`n控制台已停止。" -ForegroundColor Yellow
}
