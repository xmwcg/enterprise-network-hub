<#
.SYNOPSIS  局域网发现库：子网枚举、端口探测、对端发现
.DESCRIPTION  被 deploy.ps1 / discover.ps1 通过 ". .\lib-discovery.ps1" 引入。
#>

function Get-SubnetHosts {
    param(
        [string]$IP,
        [int]$Prefix
    )
    $ipBytes = [Net.IPAddress]::Parse($IP).GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) { [array]::Reverse($ipBytes) }
    $ipInt   = [BitConverter]::ToUInt32($ipBytes, 0)
    $maskInt = if ($Prefix -eq 0) { [uint32]0 } else { ([uint32]0xFFFFFFFF) -shl (32 - $Prefix) }
    $netInt  = $ipInt -band $maskInt
    $bcast   = $netInt -bor ((-bnot $maskInt) -band [uint32]0xFFFFFFFF)
    $hosts = @()
    for ($i = $netInt + 1; $i -lt $bcast; $i++) {
        $b = [BitConverter]::GetBytes($i)
        if ([BitConverter]::IsLittleEndian) { [array]::Reverse($b) }
        $hosts += [Net.IPAddress]::new($b).ToString()
    }
    $hosts
}

function Test-TcpPort {
    param([string]$IP, [int]$Port, [int]$TimeoutMs = 300)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect($IP, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $tcp.EndConnect($iar); $true }
        else { $false }
    } catch { $false }
    finally { try { $tcp.Close() } catch {} }
}

function Get-LocalSubnet {
    $addr = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.PrefixLength -ge 8 -and $_.PrefixLength -le 30 } |
        Sort-Object -Property PrefixLength -Descending |
        Select-Object -First 1
    if (-not $addr) { return $null }
    [PSCustomObject]@{ IP = $addr.IPAddress; Prefix = $addr.PrefixLength }
}

function Find-Peers {
    param(
        [string]$Range = "auto",
        [string]$SelfIP,
        [int]$MaxHosts = 1024
    )
    if ($Range -eq "auto") {
        $sub = Get-LocalSubnet
        if (-not $sub) { Write-Warning "无法确定本机子网。"; return @() }
        $hosts = Get-SubnetHosts -IP $sub.IP -Prefix $sub.Prefix
    } elseif ($Range -match '^(.+?)\.(\d+)-(\d+)$') {
        $base = $Matches[1]; $a = [int]$Matches[2]; $b = [int]$Matches[3]
        $hosts = @(); for ($i = $a; $i -le $b; $i++) { $hosts += "$base.$i" }
    } elseif ($Range -match '^(.+?)/(\d+)$') {
        $hosts = Get-SubnetHosts -IP $Matches[1] -Prefix ([int]$Matches[2])
    } else { Write-Warning "Range 格式无法识别：$Range"; return @() }

    if ($hosts.Count -gt $MaxHosts) {
        Write-Warning "主机数 $($hosts.Count) 超过上限 $MaxHosts，截断。"
        $hosts = $hosts | Select-Object -First $MaxHosts
    }

    $peers = @()
    Write-Host "扫描 $($hosts.Count) 个地址..." -ForegroundColor Cyan
    foreach ($ip in $hosts) {
        $alive = $false
        if ($ip -eq $SelfIP) { $alive = $true }
        else {
            if (Test-Connection -ComputerName $ip -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction SilentlyContinue) { $alive = $true }
            elseif (Test-TcpPort -IP $ip -Port 445) { $alive = $true }
            elseif (Test-TcpPort -IP $ip -Port 3389) { $alive = $true }
        }
        if ($alive) {
            $name = $ip
            try { $name = [Net.Dns]::GetHostByAddress($ip).HostName } catch {}
            $rdp = Test-TcpPort -IP $ip -Port 3389 -TimeoutMs 200
            $smb = Test-TcpPort -IP $ip -Port 445  -TimeoutMs 200
            $peers += [PSCustomObject]@{
                IP     = $ip
                Name   = $name
                RDP    = $rdp
                SMB    = $smb
                IsSelf = ($ip -eq $SelfIP)
            }
        }
    }
    $peers
}
