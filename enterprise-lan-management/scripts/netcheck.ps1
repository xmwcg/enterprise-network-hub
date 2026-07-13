<#
.SYNOPSIS  网络体检：只读检查本机/远端网络健康并集中汇总
.DESCRIPTION
  检查项（全部只读，不改任何配置）：网络类别、IP 冲突(启发式)、网关可达、DNS 解析、
  SMB 监听、RDP 监听、监听端口、多网卡(双网卡)、WinRM 状态。
  结果写入中心 Mgmt$\netcheck\<主机>.json，供公司溯源与趋势查看。
  本文件被 manager.ps1 dot-source 时仅提供 Invoke-NetCheck 函数，不执行主体。
.PARAMETER ComputerName  目标主机（省略则本机）
.PARAMETER Credential    远程目标的管理凭据
.PARAMETER FileServerHost  文件服务器主机名（写体检结果 + 审计；省略则只写本地审计）
.PARAMETER Report         读取并汇总所有已知主机的体检结论
.PARAMETER Silent         不打印（批量调用时由调用方汇总）
#>
[CmdletBinding()]
param(
    [string]$ComputerName,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$FileServerHost,
    [switch]$Report,
    [switch]$Silent
)
. .\lib-init.ps1
. .\lib-audit.ps1

# 权限最大化：非管理员自动提权（UAC 由用户确认）
if ($MyInvocation.InvocationName -ne '.') { Request-AdminOrElevate -ScriptPath $PSCommandPath -Bound $PSBoundParameters -Unbound $args }

# ---------- 核心：对某主机执行网络体检（本地或远程） ----------
function Invoke-NetCheck {
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential
    )
    $sb = {
        $checks = @()
        $add = { param($Name, $Status, $Detail) $checks += [PSCustomObject]@{ 项目 = $Name; 状态 = $Status; 说明 = $Detail } }

        # 1) 网络类别（专用网络才允许发现/共享）
        $prof = Get-NetConnectionProfile | Select-Object -First 1
        & $add "网络类别" $(if ($prof -and $prof.NetworkCategory -eq 'Private') { 'OK' } else { 'WARN' }) `
            "$(if ($prof) { $prof.NetworkCategory } else { '未知' })"

        # 2) IP 冲突（启发式：本机 IP 的邻居 MAC 是否与本机网卡 MAC 一致；APIPA 视为异常）
        $ip = Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.PrefixLength -lt 32 } |
            Select-Object -First 1
        if (-not $ip) {
            & $add "IP地址" 'FAIL' "未获取到 IPv4 地址"
        } elseif ($ip.IPAddress -like '169.254.*') {
            & $add "IP地址" 'FAIL' "APIPA 自动地址($($ip.IPAddress))，DHCP 可能失效"
        } else {
            $ownMac = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Tunnel' } | Select-Object -First 1).MacAddress
            $nb = Get-NetNeighbor -IPAddress $ip.IPAddress -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Reachable' -and $_.LinkLayerAddress }
            $conflict = $false
            foreach ($n in $nb) { if ($n.LinkLayerAddress -ne $ownMac) { $conflict = $true } }
            & $add "IP冲突" $(if ($conflict) { 'FAIL' } else { 'OK' }) `
                $(if ($conflict) { "检测到同一 IP 存在多个 MAC，疑似冲突" } { "本机 IP=$($ip.IPAddress) 未发现冲突" })
        }

        # 3) 网关可达
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        $gwOk = $false
        if ($gw) { $gwOk = Test-Connection -ComputerName $gw -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction SilentlyContinue }
        & $add "网关可达" $(if ($gwOk) { 'OK' } else { 'FAIL' }) "网关=$gw $(if ($gwOk) { '可达' } else { '不可达' })"

        # 4) DNS 解析
        $dnsServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses
        $dnsOk = $false; $dnsDetail = "DNS服务器=$(($dnsServers -join ','))"
        if ($gw) {
            try { Resolve-DnsName -Name $gw -ErrorAction Stop | Out-Null; $dnsOk = $true }
            catch { $dnsDetail += "；解析网关名失败" }
        }
        & $add "DNS解析" $(if ($dnsOk) { 'OK' } else { 'WARN' }) $dnsDetail

        # 5) SMB 监听（本机是否提供文件共享）
        $smb = Get-NetTCPConnection -LocalPort 445 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        & $add "SMB服务" $(if ($smb) { 'OK' } else { 'WARN' }) $(if ($smb) { '本地 445 监听中' } else { '本地未监听 445（本机非文件服务器属正常）' })

        # 6) RDP 监听
        $rdp = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        & $add "RDP监听" $(if ($rdp) { 'OK' } else { 'WARN' }) $(if ($rdp) { '本地 3389 监听中' } else { '本地未监听 3389（家庭版或 RDP 未启用）' })

        # 7) 监听端口数量（异常增多提示可能有可疑服务）
        $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
        & $add "监听端口" 'OK' "共 $($listen.Count) 个监听端口"

        # 8) 多网卡（双网卡可能导致路由混乱）
        $nics = @(Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.PrefixLength -lt 32 })
        & $add "多网卡" $(if ($nics.Count -gt 1) { 'WARN' } else { 'OK' }) `
            "IPv4 网卡数=$($nics.Count)$(if ($nics.Count -gt 1) { '；多网卡可能导致默认路由冲突' } else { '' })"

        # 9) WinRM 状态（统一管控依赖）
        $wr = Get-Service -Name WinRM -ErrorAction SilentlyContinue
        & $add "WinRM" $(if ($wr -and $wr.Status -eq 'Running') { 'OK' } else { 'WARN' }) "WinRM=$(if ($wr) { $wr.Status } else { '未知' })"

        # 汇总
        $fail = @($checks | Where-Object { $_.状态 -eq 'FAIL' }).Count
        $warn = @($checks | Where-Object { $_.状态 -eq 'WARN' }).Count
        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            IP           = if ($ip) { $ip.IPAddress } else { $null }
            Time         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Fail         = $fail
            Warn         = $warn
            Score        = if ($fail -gt 0) { '异常' } elseif ($warn -gt 0) { '注意' } else { '健康' }
            Checks       = $checks
        }
    }
    if ($ComputerName) {
        Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock $sb
    } else {
        & $sb
    }
}

# ---------- 主体（仅当直接运行，而非被 dot-source） ----------
if ($MyInvocation.InvocationName -ne '.') {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "请以管理员身份运行。"; exit 1
    }

    # 汇总报表：读取中心所有体检记录
    if ($Report) {
        if (-not $FileServerHost) { Write-Error "查看报表需 -FileServerHost。"; exit 1 }
        $dir = "\\$FileServerHost\Mgmt$\netcheck"
        if (-not (Test-Path $dir)) { Write-Host "暂无体检记录。" -ForegroundColor Yellow; return }
        Get-ChildItem $dir -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
            Select-Object ComputerName, IP, Time, Score, Fail, Warn | Format-Table -AutoSize
        return
    }

    # 执行体检
    $target = if ($ComputerName) { $ComputerName } else { $env:COMPUTERNAME }
    $res = Invoke-NetCheck -ComputerName $ComputerName -Credential $Credential

    if (-not $Silent) {
        Write-Host "`n=== 网络体检：$target ===" -ForegroundColor Cyan
        $res.Checks | Format-Table -AutoSize
        $color = if ($res.Fail -gt 0) { 'Red' } elseif ($res.Warn -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host "综合结论：$($res.Score)（FAIL=$($res.Fail)  WARN=$($res.Warn)）" -ForegroundColor $color
    }

    if ($FileServerHost) {
        $dir = "\\$FileServerHost\Mgmt$\netcheck"
        try {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $res | ConvertTo-Json -Depth 5 | Set-Content -Path "$dir\$($res.ComputerName).json" -Encoding UTF8
        } catch {}
    }
    Write-Audit -FileServerHost $FileServerHost -Entry @{
        Target = $target; Action = "NetCheck"; Score = $res.Score; Fail = $res.Fail; Warn = $res.Warn; Result = "OK"
    }
}
