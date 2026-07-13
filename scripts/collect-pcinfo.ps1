<#
.SYNOPSIS   自动采集本机"联网互通"所需信息，输出一行 JSON
.DESCRIPTION
  在每一台电脑上正常运行（无需管理员权限）：
    右键 -> 使用 PowerShell 运行
    或在 PowerShell 中：  .\collect-pcinfo.ps1
  把控制台打印出的那一行 JSON 文本发回即可。
  请在包括"文件服务器"在内的每一台电脑上都跑一次。
#>

. .\lib-init.ps1
$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$ci  = Get-ComputerInfo

$netList = @(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway })
if ($netList.Count -ge 1) {
    $primary = $netList[0]
    $ip4     = ($primary.IPv4Address    | Select-Object -ExpandProperty IPAddress)
    $gw      = ($primary.IPv4DefaultGateway | Select-Object -ExpandProperty NextHop)
    $dns     = ($primary.DNSServer       | Select-Object -ExpandProperty ServerAddresses)
    $adapter = $primary.InterfaceAlias
} else {
    $ip4 = $gw = $dns = $adapter = $null
}

# 版本：Home(Core) 不支持作为 RDP 主机；Professional/Enterprise/Education 支持
$edition    = $ci.WindowsEditionId
$rdpHostOK  = $edition -notmatch 'Core|Home'

$info = [PSCustomObject]@{
    ComputerName   = $env:COMPUTERNAME
    OS             = $os.Caption
    Edition        = $edition
    IsDomainJoined = $cs.PartOfDomain
    DomainOrWG     = if ($cs.PartOfDomain) { $cs.Domain } else { $cs.Workgroup }
    IP             = $ip4
    Gateway        = $gw
    DNS            = $dns
    Adapter        = $adapter
    RDP_HostOK     = $rdpHostOK
}

# 输出紧凑 JSON，便于整行复制
$info | ConvertTo-Json -Compress
