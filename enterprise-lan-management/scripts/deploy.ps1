<#
.SYNOPSIS  公司局域网"打通"——自动检测本机 + 自动采集对端 + 直接部署
.DESCRIPTION
  在每一台电脑以管理员运行一次，脚本会：
  1) 自动检测本机（主机名 / IP / 系统 / 是否支持 RDP 主机）
  2) 载入公司配置 company-config.json（管理员一次性填写）
  3) 应用基线：网络发现 + SMB + RDP(NLA) + 工作组 + 统一管理账号
  4) 自动判定文件服务器角色（AUTO：子网内已有 CompanyShare 则作客户端，否则本机认领）
  5) 自动采集对端（子网扫描），生成全网清单
  6) 自动改名：把默认名（WIN-xxxx / DESKTOP-xxxx）改为 <前缀>-NN（如 PC-01），与对端协调避免冲突
  7) 直接部署：映射文件服务器共享、按采集结果设置 TrustedHosts、写入心跳与清单、启用 WinRM
  8) 家庭版自动安装 RustDesk 作为 RDP 替代（当 InstallRustDesk=true 且本机为家庭版）
.PARAMETER FileServer  显式指定本机为文件服务器（覆盖 AUTO 判定）
#>
[CmdletBinding()]
param(
    [switch]$FileServer,
    [string]$ConfigFile = ".\company-config.json"
)
. .\lib-init.ps1
. .\lib-discovery.ps1
. .\lib-audit.ps1
. .\lib-license.ps1

# 权限最大化：非管理员自动提权（UAC 由用户确认，即"用户决策"）
if ($MyInvocation.InvocationName -ne '.') { Request-AdminOrElevate -ScriptPath $PSCommandPath -Bound $PSBoundParameters -Unbound $args }

$script:FileServerHost = $null
$restart = $false

# ---------- 1) 自动检测本机 ----------
$self = [PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    IP           = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } | Select-Object -First 1).IPAddress
    MAC          = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Tunnel' } | Select-Object -First 1).MacAddress
    OS           = (Get-CimInstance Win32_OperatingSystem).Caption
    Edition      = (Get-ComputerInfo).WindowsEditionId
}
$self.RDP_OK = $self.Edition -notmatch 'Core|Home'
Write-Host "本机：$($self.ComputerName)  IP=$($self.IP)  $($self.OS) ($($self.Edition))  RDP主机=$($self.RDP_OK)" -ForegroundColor Green

# ---------- 2) 载入配置 ----------
if (-not (Test-Path $ConfigFile)) { Write-Error "未找到配置文件 $ConfigFile"; exit 1 }
$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

# ---------- 1.5) 授权校验（商业闭环：无效授权即终止部署） ----------
$lic = Get-License -Path $cfg.LicenseFile
if (-not $lic.Valid) { Write-Error "授权校验未通过：$($lic.Reason)"; exit 1 }
$exp = if ($lic.Expiry) { $lic.Expiry.ToString('yyyy-MM-dd') } else { '永久' }
$cap = if ($lic.MaxDevices -eq 0) { '不限' } else { [string]$lic.MaxDevices }
Write-Host "授权：$($lic.EditionLabel)  公司=$($lic.Company)  设备上限=$cap  有效期至=$exp" -ForegroundColor Cyan

# ---------- 3) 应用基线 ----------
Write-Host "`n[1/5] 应用网络基线（专用网络 + 发现 + SMB + RDP）..." -ForegroundColor Cyan
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
foreach ($svc in @("fdrespub", "SSDPSRV", "upnphost", "Dnscache", "LanmanServer", "LanmanWorkstation")) {
    try { Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop; Start-Service -Name $svc -ErrorAction Stop }
    catch { Write-Warning "服务 $svc 启动失败" }
}
Set-NetFirewallRule -DisplayGroup "Network Discovery"        -Enabled True -Profile Private
Set-NetFirewallRule -DisplayGroup "File and Printer Sharing" -Enabled True -Profile Private
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
Set-SmbServerConfiguration -EnableSMB2Protocol $true  -Force
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 1
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# 家庭版：自动安装 RustDesk 作为 RDP 替代
if ($cfg.InstallRustDesk -and -not $self.RDP_OK) {
    Write-Host "本机为家庭版（RDP 主机不可用），安装 RustDesk 作为远程桌面替代..." -ForegroundColor Yellow
    try {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) { throw "未找到 winget；请先安装 Microsoft Store 的 App Installer，或手动安装 RustDesk。" }
        & winget install --id RustDesk.RustDesk -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
        Write-Host "RustDesk 安装完成。" -ForegroundColor Green
        # 无人值守密码：优先向导标志 RustDeskSetPw（部署时现场输入，不落盘）；兼容旧字段 RustDeskPassword
        $rdPlain = $null
        if ($cfg.RustDeskSetPw) {
            $rdSec = Read-Host -Prompt "请输入 RustDesk 无人值守密码" -AsSecureString
            $rdPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($rdSec))
        } elseif ($cfg.RustDeskPassword) {
            $rdPlain = $cfg.RustDeskPassword
        }
        if ($rdPlain) {
            $cfgDir = Join-Path $env:ProgramData "RustDesk\config"
            New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
            $toml = "[options]`npassword = `"$rdPlain`"`n"
            if ($cfg.RustDeskServer) { $toml += "relay-server = `"$($cfg.RustDeskServer)`"`n" }
            Set-Content -Path (Join-Path $cfgDir "RustDesk.toml") -Value $toml -Encoding UTF8
            $svc = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
            if ($svc) { Restart-Service -Name "RustDesk" -Force -ErrorAction SilentlyContinue }
            Write-Host "已设置 RustDesk 无人值守密码。" -ForegroundColor Green
        } else {
            Write-Host "未设置无人值守密码，已安装但需手动设置（设置->安全->设置密码）。" -ForegroundColor Yellow
        }
    } catch { Write-Warning "RustDesk 处理失败：$_" }
}

$cs = Get-CimInstance Win32_ComputerSystem
if ($cfg.UseDomain) {
    if ($cs.PartOfDomain) { Write-Host "本机已加入域 $($cs.Domain)。" -ForegroundColor Green }
    else { Write-Host "配置为域模式（$($cfg.DomainName) / 域控 $($cfg.DomainController)）。请手动执行加域：Add-Computer -DomainName $($cfg.DomainName) -Credential (Get-Credential) -Restart" -ForegroundColor Yellow }
} elseif (-not $cs.PartOfDomain -and $cs.Workgroup -ne $cfg.WorkgroupName) {
    try { Add-Computer -WorkGroupName $cfg.WorkgroupName -ErrorAction Stop; Write-Host "已加入工作组 $($cfg.WorkgroupName)，需重启生效。" -ForegroundColor Yellow; $restart = $true }
    catch { Write-Warning "加入工作组失败：$_" }
}

# 统一管理账号
Write-Host "`n[2/5] 创建统一管理账号 $($cfg.MgmtUser)..." -ForegroundColor Cyan
$sec = Read-Host -Prompt "请输入管理账号 [$($cfg.MgmtUser)] 密码" -AsSecureString
try {
    if (-not (Get-LocalUser -Name $cfg.MgmtUser -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name $cfg.MgmtUser -Password $sec -PasswordNeverExpires:$true -UserMayNotChangePassword:$true -AccountNeverExpires
    }
    Add-LocalGroupMember -Group "Administrators"       -Member $cfg.MgmtUser -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "Remote Desktop Users" -Member $cfg.MgmtUser -ErrorAction SilentlyContinue
} catch { Write-Warning "账号配置失败：$_" }
$cred = New-Object System.Management.Automation.PSCredential($cfg.MgmtUser, $sec)

# ---------- 4) 自动采集对端并判定文件服务器角色 ----------
Write-Host "`n[3/5] 自动采集对端并判定文件服务器角色..." -ForegroundColor Cyan
$peers = Find-Peers -Range $cfg.Discover -SelfIP $self.IP
$peerExt = ($peers | Where-Object { -not $_.IsSelf }).Count
Write-Host "发现 $peerExt 台对端。"

# 自动改名：把默认名（WIN-xxxx / DESKTOP-xxxx）改为 <前缀>-NN，与对端协调避免冲突
if ($cfg.AutoRename -and $cfg.RenamePrefix) {
    $prefix = $cfg.RenamePrefix
    $pattern = "^$prefix-\d+$"
    $isDefault = $self.ComputerName -match '^WIN-|^DESKTOP-'
    if (($self.ComputerName -notmatch $pattern) -or $isDefault) {
        $used = @()
        foreach ($p in $peers) {
            if ($p.Name -match "^$prefix-(\d+)$") { $used += [int]$Matches[1] }
        }
        $next = 1
        if ($used.Count) { $next = ($used | Sort-Object -Descending | Select-Object -First 1) + 1 }
        # 与网络中已存活的候选名冲突预检，找一个空闲名
        $candidate = $null
        while ($next -le 254) {
            $try = "$prefix-$('{0:00}' -f $next)"
            $alive = $false
            try { if (Test-Connection -ComputerName $try -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction SilentlyContinue) { $alive = $true } } catch {}
            if (-not $alive) { $candidate = $try; break }
            $next++
        }
        if (-not $candidate) { Write-Warning "未找到空闲名称候选，跳过自动改名。" }
        else {
            $oldName = $self.ComputerName
            try {
                Rename-Computer -NewName $candidate -Force -ErrorAction Stop
                Write-Host "已请求改名：$oldName -> $candidate（重启后生效）" -ForegroundColor Yellow
                $self.ComputerName = $candidate
                $restart = $true
                $script:RenameTrace = [ordered]@{
                    OldName   = $oldName
                    NewName   = $candidate
                    IP        = $self.IP
                    MAC       = $self.MAC
                    Operator  = $env:USERNAME
                    Time      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    Result    = "Renamed"
                }
            } catch { Write-Warning "改名失败：$_" }
        }
    }
}

$isFileServer = $FileServer
if (-not $isFileServer) {
    if ($cfg.FileServer -ne "AUTO") {
        $script:FileServerHost = $cfg.FileServer
        $isFileServer = ($cfg.FileServer -eq $self.ComputerName)
        if ($isFileServer) { Write-Host "配置指定本机为文件服务器。" }
        else { Write-Host "配置指定文件服务器为 $($cfg.FileServer)（本机作为客户端）。" }
    } else {
        $existing = $peers | Where-Object { -not $_.IsSelf -and $_.SMB } | ForEach-Object {
            $unc = "\\$($_.Name)\CompanyShare"
            if (Test-Path $unc) { $_.Name }
        } | Select-Object -First 1
        if ($existing) { $script:FileServerHost = $existing; Write-Host "检测到已有文件服务器：$existing（本机作为客户端）。" }
        else { $isFileServer = $true; Write-Host "未发现现成共享，本机认领为文件服务器。" }
    }
}

if ($isFileServer) {
    $script:FileServerHost = $self.ComputerName
    if (-not (Test-Path $cfg.ShareRoot)) { New-Item -ItemType Directory -Path $cfg.ShareRoot | Out-Null }
    New-SmbShare -Name "CompanyShare" -Path $cfg.ShareRoot -FullAccess "Everyone" -ErrorAction SilentlyContinue
    $mgmtPath = Join-Path $cfg.ShareRoot "Mgmt"
    New-Item -ItemType Directory -Path $mgmtPath -Force | Out-Null
    New-SmbShare -Name "Mgmt$" -Path $mgmtPath -FullAccess $cfg.MgmtUser -ErrorAction SilentlyContinue
    Write-Host "文件服务器已就绪：\\$env:COMPUTERNAME\CompanyShare" -ForegroundColor Green
}

# 补充资产字段（闭合数据模型：让 manager 资产清单能正确读取，而非显示空白/错值）
try { $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop } catch { $gw = $null }
try { $dns = @((Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses) } catch { $dns = @() }
$self | Add-Member -NotePropertyName 'RDP_HostOK'  -NotePropertyValue $self.RDP_OK -Force
$self | Add-Member -NotePropertyName 'Gateway'     -NotePropertyValue $gw -Force
$self | Add-Member -NotePropertyName 'DNS'         -NotePropertyValue $dns -Force
$self | Add-Member -NotePropertyName 'IsFileServer' -NotePropertyValue $isFileServer -Force

# ---------- 5) 直接部署：映射共享 / TrustedHosts / 心跳清单 / WinRM ----------
Write-Host "`n[4/5] 直接部署：映射共享 / TrustedHosts / 心跳清单..." -ForegroundColor Cyan
if ($script:FileServerHost) {
    $unc = "\\$($script:FileServerHost)\CompanyShare"
    if (Test-Path $unc) {
        $letter = $cfg.MapDriveLetter
        if (-not (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name $letter -PSProvider FileSystem -Root $unc -Credential $cred -Persist -ErrorAction SilentlyContinue | Out-Null
            Write-Host "已映射 $unc -> ${letter}:"
        }
    }
    # 设备数上限门禁（商业闭环：超授权设备数则阻断，驱动升级）
    if ($lic.MaxDevices -gt 0) {
        $cur = Get-DeviceCount -FileServerHost $script:FileServerHost
        if (($cur + 1) -gt $lic.MaxDevices) {
            Write-Error "授权设备数已达上限（$cur / $($lic.MaxDevices)），无法继续部署，请升级授权或联系厂商。"
            exit 1
        }
    }

    # TrustedHosts：优先向导扁平字段 $cfg.TrustedHosts，兼容旧的 $cfg.Security.TrustedHosts
    $thMode = if ($null -ne $cfg.TrustedHosts) { $cfg.TrustedHosts } elseif ($cfg.Security) { $cfg.Security.TrustedHosts } else { "discovered" }
    switch ($thMode) {
        "discovered" {
            $ths = ($peers | Where-Object { -not $_.IsSelf } | ForEach-Object { $_.IP }) -join ','
            if ($ths) { Set-Item WSMan:\localhost\Client\TrustedHosts -Value $ths -Force; Write-Host "TrustedHosts 已设为发现的对端 IP。" }
        }
        "*"   { Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force; Write-Host "TrustedHosts 已设为全部（*）。" -ForegroundColor Yellow }
        "off" { Write-Host "TrustedHosts 按配置保持不变（off）。" }
        default {
            if ($thMode) { Set-Item WSMan:\localhost\Client\TrustedHosts -Value $thMode -Force; Write-Host "TrustedHosts 已设为：$thMode" }
        }
    }
    $mgmt = "\\$($script:FileServerHost)\Mgmt$"
    try {
        foreach ($sub in @($mgmt, "$mgmt\hosts", "$mgmt\inventory", "$mgmt\audit")) {
            if (-not (Test-Path $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null }
        }
        $self  | ConvertTo-Json | Set-Content -Path "$mgmt\hosts\$($self.ComputerName).json"   -Encoding UTF8
        $peers | ConvertTo-Json | Set-Content -Path "$mgmt\inventory\$($self.ComputerName)_peers.json" -Encoding UTF8
        if ($script:RenameTrace) {
            $script:RenameTrace | ConvertTo-Json | Set-Content -Path "$mgmt\audit\rename-$($script:RenameTrace.NewName).json" -Encoding UTF8
            Write-Host "改名溯源已写入 $mgmt\audit\rename-$($script:RenameTrace.NewName).json"
        }
        Write-Host "本机信息与对端清单已上报至 $mgmt"
    } catch { Write-Warning "上报失败：$_" }
}

Write-Host "`n[5/5] 启用 WinRM 远程管理..." -ForegroundColor Cyan
try { Enable-PSRemoting -Force -ErrorAction Stop; winrm quickconfig -q } catch { Write-Warning "WinRM 启用失败：$_" }

$role = if ($isFileServer) { "文件服务器" } else { "客户端" }
Write-Host "`n部署完成。本机角色：$role，文件服务器=$($script:FileServerHost)，发现对端=$peerExt" -ForegroundColor Green
Write-Audit -FileServerHost $script:FileServerHost -Entry ([ordered]@{
    Target          = $self.ComputerName
    Action          = "Deploy"
    Role            = $role
    DiscoveredPeers = $peerExt
    Result          = "OK"
})
if ($cfg.RemoteAccess -and $cfg.RemoteAccess -ne "none") {
    Write-Host "远程办公：配置为 $($cfg.RemoteAccess)。请在需外网接入的电脑上安装并登录 $($cfg.RemoteAccess)，本套脚本不代为安装组网客户端。" -ForegroundColor Yellow
}
if ($restart) {
    $a = Read-Host "是否现在重启使工作组生效？(Y/N)"
    if ($a -match '^[Yy]') { Restart-Computer -Force }
}
