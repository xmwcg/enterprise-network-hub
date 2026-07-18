<#
.SYNOPSIS  上网管控：按主机允许/禁止访问互联网，并集中溯源
.DESCRIPTION
  客户端防火墙方式实现"可上网 / 可禁用"：
    · 禁止(deny) = 阻塞本机出站 TCP 80/443（可选含 DNS 53）从而断网；
    · 允许(allow) = 禁用该规则恢复上网。
  策略状态写入中心 Mgmt$\netpolicy\<主机>.json，供公司溯源追责；
  并可导出网关黑名单（IP/MAC）供路由器/网关侧封禁。
  本文件被 manager.ps1 dot-source 时仅提供函数（Set-InternetPolicy / Write-NetPolicyState），不执行主体。
.PARAMETER Action    allow | deny（与 -Block / -Unblock 二选一）
.PARAMETER Block     等价 -Action deny
.PARAMETER Unblock   等价 -Action allow
.PARAMETER ComputerName  目标主机（省略则本机）
.PARAMETER Credential    远程目标的管理凭据
.PARAMETER FileServerHost  文件服务器主机名（用于写策略状态与审计；省略则只写本地审计）
.PARAMETER Report         读取并列出所有已知主机的上网策略
.PARAMETER ExportGatewayBlacklist  导出被禁止主机的 IP/MAC 为 CSV（供网关封禁）
.PARAMETER HardCut         禁止时一并阻塞 DNS(53)，实现硬断网
.PARAMETER Silent          不打印结果（批量调用时由调用方汇总）
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [ValidateSet('allow', 'deny')][string]$Action,
    [switch]$Block,
    [switch]$Unblock,
    [string]$ComputerName,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$FileServerHost,
    [switch]$Report,
    [string]$ExportGatewayBlacklist,
    [switch]$HardCut,
    [switch]$Silent
)
. .\lib-init.ps1
. .\lib-audit.ps1
. .\lib-license.ps1

# 权限最大化：非管理员自动提权（UAC 由用户确认）
if ($MyInvocation.InvocationName -ne '.') { Request-AdminOrElevate -ScriptPath $PSCommandPath -Bound $PSBoundParameters -Unbound $args }

# ---------- 仅供内部/被引用：获取本机 IP / MAC ----------
function Get-NetAdapterInfo {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.PrefixLength -lt 32 } |
        Select-Object -First 1).IPAddress
    $mac = (Get-NetAdapter |
        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Tunnel' } |
        Select-Object -First 1).MacAddress
    [PSCustomObject]@{ IP = $ip; MAC = $mac }
}

# ---------- 核心：对某主机应用上网策略（本地或远程） ----------
function Set-InternetPolicy {
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential,
        [bool]$Block,
        [switch]$HardCut
    )
    $sb = {
        param($Block, $HardCut)
        $ruleName = "Company-NoInternet"
        $dnsRule = "$ruleName-DNS"
        if ($Block) {
            if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
                $ports = if ($HardCut) { "80,443,53" } else { "80,443" }
                New-NetFirewallRule -Name $ruleName -DisplayName "公司管控-禁止上网" `
                    -Direction Outbound -Action Block -Protocol TCP -RemotePort $ports -ErrorAction Stop | Out-Null
                if ($HardCut) {
                    New-NetFirewallRule -Name $dnsRule -DisplayName "公司管控-禁止DNS" `
                        -Direction Outbound -Action Block -Protocol UDP -RemotePort 53 -ErrorAction SilentlyContinue | Out-Null
                }
            } else {
                Enable-NetFirewallRule -Name $ruleName -ErrorAction Stop
                if ($HardCut) { Enable-NetFirewallRule -Name $dnsRule -ErrorAction SilentlyContinue }
            }
            $policy = "deny"
        } else {
            Disable-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
            Disable-NetFirewallRule -Name $dnsRule -ErrorAction SilentlyContinue
            $policy = "allow"
        }
        $info = Get-NetAdapterInfo
        [PSCustomObject]@{
            Policy = $policy
            IP     = $info.IP
            MAC    = $info.MAC
        }
    }
    if ($ComputerName) {
        Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock $sb -ArgumentList $Block, $HardCut
    } else {
        & $sb $Block $HardCut
    }
}

# ---------- 核心：写策略状态到中心（供溯源 + 网关黑名单导出） ----------
function Write-NetPolicyState {
    [CmdletBinding()]
    param(
        [string]$FileServerHost,
        [string]$ComputerName,
        [string]$Policy,
        [string]$IP,
        [string]$MAC
    )
    if (-not $FileServerHost) { return }
    $dir = "\\$FileServerHost\Mgmt$\netpolicy"
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [ordered]@{
            ComputerName = $ComputerName
            IP           = $IP
            MAC          = $MAC
            Policy       = $Policy
            Operator     = $env:USERNAME
            Time         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json | Set-Content -Path "$dir\$ComputerName.json" -Encoding UTF8
    } catch {}
}

# ---------- 主体（仅当直接运行，而非被 dot-source） ----------
if ($MyInvocation.InvocationName -ne '.') {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "请以管理员身份运行。"; exit 1
    }

    # 授权校验（商业闭环：直接运行时也须校验功能权益）
    $lic = Assert-License -Path $null -RequireFeature 'netpolicy'
    if (-not $lic) { exit 1 }

    # 导出网关黑名单
    if ($ExportGatewayBlacklist) {
        if (-not $FileServerHost) { Write-Error "导出黑名单需 -FileServerHost 以读取策略状态。"; exit 1 }
        $dir = "\\$FileServerHost\Mgmt$\netpolicy"
        $denied = @()
        if (Test-Path $dir) {
            $denied = Get-ChildItem $dir -Filter *.json | ForEach-Object {
                $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($j.Policy -eq 'deny') { $j }
            }
        }
        if ($denied.Count -eq 0) { Write-Host "当前没有被禁止上网的主机，无需导出。" -ForegroundColor Yellow; return }
        $denied | Select-Object @{n = '主机名'; e = { $_.ComputerName } }, @{n = 'IP'; e = { $_.IP } }, @{n = 'MAC'; e = { $_.MAC } } |
            Export-Csv -Path $ExportGatewayBlacklist -NoTypeInformation -Encoding UTF8
        Write-Host "已导出网关黑名单（IP/MAC）：$ExportGatewayBlacklist（共 $($denied.Count) 台）" -ForegroundColor Green
        return
    }

    # 查看策略报表
    if ($Report) {
        if (-not $FileServerHost) { Write-Error "查看报表需 -FileServerHost。"; exit 1 }
        $dir = "\\$FileServerHost\Mgmt$\netpolicy"
        if (-not (Test-Path $dir)) { Write-Host "暂无上网策略记录。" -ForegroundColor Yellow; return }
        Get-ChildItem $dir -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
            Select-Object ComputerName, IP, MAC, Policy, Operator, Time | Format-Table -AutoSize
        return
    }

    # 应用策略
    if ($Action) { $block = ($Action -eq 'deny') }
    elseif ($Block) { $block = $true }
    elseif ($Unblock) { $block = $false }
    else { Write-Error "请指定 -Action allow|deny（或 -Block / -Unblock）。"; exit 1 }

    $target = if ($ComputerName) { $ComputerName } else { $env:COMPUTERNAME }
    $res = Set-InternetPolicy -ComputerName $ComputerName -Credential $Credential -Block $block -HardCut:$HardCut
    Write-NetPolicyState -FileServerHost $FileServerHost -ComputerName $target -Policy $res.Policy -IP $res.IP -MAC $res.MAC
    Write-Audit -FileServerHost $FileServerHost -Entry @{
        Target = $target; Action = "NetPolicy"; Policy = $res.Policy; HardCut = [bool]$HardCut; Result = "OK"
    }
    if (-not $Silent) {
        $verb = if ($block) { "已禁止上网" } else { "已恢复上网" }
        $color = if ($block) { 'Red' } else { 'Green' }
        Write-Host "$target -> $verb（策略=$($res.Policy)）" -ForegroundColor $color
    }
}
