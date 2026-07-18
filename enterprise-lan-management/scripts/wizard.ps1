<#
.SYNOPSIS  公司局域网互联互通 - 中文配置向导
.DESCRIPTION
  以中文交互菜单逐步收集关键配置，支持「上一步 / 下一步 / 退出」，
  最终生成 company-config.json；可选择直接启动部署（deploy.ps1）。
  关键配置全部由用户在此菜单中选配，无需手动编辑 JSON。
.PARAMETER ConfigFile  输出的配置文件路径（默认 .\company-config.json）
.PARAMETER SkipDeploy  仅生成配置，不自动启动部署
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = ".\company-config.json",
    [switch]$SkipDeploy
)

. .\lib-init.ps1
. .\lib-license.ps1
# 权限最大化：非管理员自动提权（UAC 由用户确认，即"用户决策"）
if ($MyInvocation.InvocationName -ne '.') { Request-AdminOrElevate -ScriptPath $PSCommandPath -Bound $PSBoundParameters -Unbound $args }

# 授权校验（商业闭环：无效授权即终止向导）
$lic = Get-License -Path $null
if (-not $lic.Valid) { Write-Error "授权校验未通过：$($lic.Reason)"; exit 1 }
$dl = Get-LicenseDaysLeft -Path $null
if ($null -ne $dl) { Write-Host ("授权剩余天数：$dl") -ForegroundColor Cyan }

# ---------- 默认状态 ----------
$cfg = [PSCustomObject]@{
    WorkgroupName    = "COMPANY"
    UseDomain        = $false
    DomainName       = ""
    DomainController = ""
    MgmtUser         = "itadmin"
    FileServer       = "AUTO"
    FileServerName   = ""
    ShareRoot        = "D:\CompanyShare"
    MapDriveLetter   = "S"
    AutoRename       = $true
    RenamePrefix     = "PC"
    InstallRustDesk  = $true
    RustDeskSetPw    = $false
    Discover         = "auto"
    BlockRdpPublic   = $true
    TrustedHosts     = "discovered"
    RemoteAccess     = "none"
}

$total = 8
$step  = 1

function Show-Header($title) {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "      公司局域网互联互通 · 中文配置向导" -ForegroundColor Cyan
    Write-Host ("      步骤 {0} / {1} ：$title" -f $step, $total) -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Get-Text($prompt, $default) {
    $msg = if ($default) { "$prompt (默认 $default)" } else { $prompt }
    $r = Read-Host $msg
    if ([string]::IsNullOrWhiteSpace($r)) { return $default } else { return $r.Trim() }
}

function Get-Menu($prompt, $options) {
    # $options: @(@{Key="AUTO"; Label="..."}, ...)
    Write-Host $prompt -ForegroundColor White
    for ($i = 0; $i -lt $options.Count; $i++) {
        Write-Host ("   {0}. {1}" -f ($i + 1), $options[$i].Label) -ForegroundColor White
    }
    Write-Host "   [0] 返回上一步    [Q] 退出向导" -ForegroundColor DarkGray
    while ($true) {
        $r = Read-Host "请选择"
        if ($r -eq 'Q' -or $r -eq 'q') { return 'QUIT' }
        if ($r -eq '0') { return 'BACK' }
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $options.Count) {
            return $options[$r - 1].Key
        }
        Write-Warning "输入无效，请重试。"
    }
}

while ($true) {
    $nav = 'next'
    switch ($step) {
        1 {
            Show-Header "互联模式"
            $opt = @(
                @{Key='WG';  Label="工作组（推荐，无需额外服务器）"},
                @{Key='DOM'; Label="AD 域（需域控制器，需手动加域）"}
            )
            $r = Get-Menu "请选择互联模式：" $opt
            if ($r -eq 'QUIT') { exit }
            if ($r -eq 'BACK') { $nav = 'back'; break }
            if ($r -eq 'WG') {
                $cfg.UseDomain = $false
                $cfg.WorkgroupName = Get-Text "请输入工作组名" $cfg.WorkgroupName
            } else {
                $cfg.UseDomain = $true
                $cfg.DomainName = Get-Text "请输入域名（如 corp.local）" $cfg.DomainName
                $cfg.DomainController = Get-Text "请输入域控制器 IP" $cfg.DomainController
                Write-Host "提示：域模式需手动将电脑加入域，向导仅记录参数。" -ForegroundColor Yellow
            }
        }
        2 {
            Show-Header "统一管理账号"
            $cfg.MgmtUser = Get-Text "请输入统一管理账号名" $cfg.MgmtUser
            Write-Host "说明：该账号密码将在「部署」运行时现场输入，不会写入配置文件。" -ForegroundColor Yellow
        }
        3 {
            Show-Header "文件服务器策略"
            $opt = @(
                @{Key='AUTO';  Label="AUTO（自动认领/复用已有的 CompanyShare）"},
                @{Key='NAMED'; Label="指定一台主机名作为文件服务器"},
                @{Key='THIS';  Label="本机即为文件服务器"}
            )
            $r = Get-Menu "请选择文件服务器策略：" $opt
            if ($r -eq 'QUIT') { exit }
            if ($r -eq 'BACK') { $nav = 'back'; break }
            if ($r -eq 'AUTO') {
                $cfg.FileServer = 'AUTO'
            } elseif ($r -eq 'NAMED') {
                $cfg.FileServer = Get-Text "请输入文件服务器主机名" "PC-FILE"
            } else {
                $cfg.FileServer = $env:COMPUTERNAME
            }
            $cfg.ShareRoot = Get-Text "请输入共享根目录" $cfg.ShareRoot
            $cfg.MapDriveLetter = Get-Text "请输入映射盘符" $cfg.MapDriveLetter
        }
        4 {
            Show-Header "自动改名"
            $opt = @(
                @{Key='ON';  Label="开启（把 WIN-xxxx / DESKTOP-xxxx 改为 前缀-NN）"},
                @{Key='OFF'; Label="关闭"}
            )
            $r = Get-Menu "是否自动改名？" $opt
            if ($r -eq 'QUIT') { exit }
            if ($r -eq 'BACK') { $nav = 'back'; break }
            if ($r -eq 'ON') {
                $cfg.AutoRename = $true
                $cfg.RenamePrefix = Get-Text "请输入改名前缀" $cfg.RenamePrefix
            } else {
                $cfg.AutoRename = $false
            }
        }
        5 {
            Show-Header "家庭版远程替代（RustDesk）"
            $opt = @(
                @{Key='ON';  Label="自动安装 RustDesk（家庭版远程桌面替代，推荐）"},
                @{Key='OFF'; Label="关闭"}
            )
            $r = Get-Menu "是否自动安装 RustDesk？" $opt
            if ($r -eq 'QUIT') { exit }
            if ($r -eq 'BACK') { $nav = 'back'; break }
            if ($r -eq 'ON') {
                $cfg.InstallRustDesk = $true
                $opt2 = @(
                    @{Key='YES'; Label="是（部署时现场输入无人值守密码，不存盘）"},
                    @{Key='NO';  Label="否（仅安装，手动设置）"}
                )
                $r2 = Get-Menu "是否为 RustDesk 设置无人值守密码？" $opt2
                if ($r2 -eq 'QUIT') { exit }
                if ($r2 -eq 'BACK') { $nav = 'back'; break }
                $cfg.RustDeskSetPw = ($r2 -eq 'YES')
            } else {
                $cfg.InstallRustDesk = $false
            }
        }
        6 {
            Show-Header "发现范围"
            $opt = @(
                @{Key='AUTO';   Label="自动（使用本机所在子网）"},
                @{Key='MANUAL'; Label="手动指定范围"}
            )
            $r = Get-Menu "请选择发现范围：" $opt
            if ($r -eq 'QUIT') { exit }
            if ($r -eq 'BACK') { $nav = 'back'; break }
            if ($r -eq 'AUTO') {
                $cfg.Discover = 'auto'
            } else {
                $cfg.Discover = Get-Text "请输入范围（如 192.168.1.1-254 或 192.168.1.0/24）" "192.168.1.1-254"
            }
        }
        7 {
            Show-Header "安全选项"
            $opt1 = @(
                @{Key='YES'; Label="是（推荐：不要把 3389 映射到公网）"},
                @{Key='NO';  Label="否（不推荐）"}
            )
            $r1 = Get-Menu "是否禁止 RDP 暴露到公网？" $opt1
            if ($r1 -eq 'QUIT') { exit }
            if ($r1 -eq 'BACK') { $nav = 'back'; break }
            $cfg.BlockRdpPublic = ($r1 -eq 'YES')

            $opt2 = @(
                @{Key='discovered'; Label="仅发现的对端 IP"},
                @{Key='all';        Label="全部（*）"},
                @{Key='off';        Label="关闭"}
            )
            $r2 = Get-Menu "WinRM TrustedHosts 范围？" $opt2
            if ($r2 -eq 'QUIT') { exit }
            if ($r2 -eq 'BACK') { $nav = 'back'; break }
            if ($r2 -eq 'all') { $cfg.TrustedHosts = '*' } elseif ($r2 -eq 'off') { $cfg.TrustedHosts = 'off' } else { $cfg.TrustedHosts = 'discovered' }

            $opt3 = @(
                @{Key='none';     Label="不需要远程办公"},
                @{Key='tailscale';Label="Tailscale（零信任组网）"},
                @{Key='zerotier'; Label="ZeroTier（虚拟局域网）"}
            )
            $r3 = Get-Menu "是否需要远程/外网办公接入？" $opt3
            if ($r3 -eq 'QUIT') { exit }
            if ($r3 -eq 'BACK') { $nav = 'back'; break }
            $cfg.RemoteAccess = $r3
        }
        8 {
            Show-Header "确认与生成"
            Write-Host "请确认以下配置：" -ForegroundColor White
            $mode = if ($cfg.UseDomain) { "AD 域 ($($cfg.DomainName) / $($cfg.DomainController))" } else { "工作组 $($cfg.WorkgroupName)" }
            $rn   = if ($cfg.AutoRename) { "开启，前缀 $($cfg.RenamePrefix)" } else { "关闭" }
            $rd   = if ($cfg.InstallRustDesk) { "开启（无人值守密码: $(if ($cfg.RustDeskSetPw) {'部署时输入'} else {'手动'}))" } else { "关闭" }
            Write-Host ("  互联模式      : {0}" -f $mode)
            Write-Host ("  管理账号      : {0}（密码部署时输入）" -f $cfg.MgmtUser)
            Write-Host ("  文件服务器    : {0}" -f $cfg.FileServer)
            Write-Host ("  共享根目录    : {0}  映射盘符: {1}:" -f $cfg.ShareRoot, $cfg.MapDriveLetter)
            Write-Host ("  自动改名      : {0}" -f $rn)
            Write-Host ("  RustDesk      : {0}" -f $rd)
            Write-Host ("  发现范围      : {0}" -f $cfg.Discover)
            Write-Host ("  安全          : RDP公网=$(if($cfg.BlockRdpPublic){'禁止'}else{'允许'})  TrustedHosts=$($cfg.TrustedHosts)  远程接入=$($cfg.RemoteAccess)")
            Write-Host ""
            $opt = @(
                @{Key='GENDEP'; Label="生成配置并开始部署"},
                @{Key='GEN';    Label="仅生成配置（不部署）"},
                @{Key='BACK';   Label="返回上一步修改"}
            )
            $r = Get-Menu "请选择：" $opt
            if ($r -eq 'QUIT') { exit }
            if ($r -eq 'BACK') { $nav = 'back'; break }
            if ($r -eq 'GENDEP' -or $r -eq 'GEN') {
                $out = [ordered]@{
                    WorkgroupName    = $cfg.WorkgroupName
                    UseDomain        = $cfg.UseDomain
                    DomainName       = $cfg.DomainName
                    DomainController = $cfg.DomainController
                    MgmtUser         = $cfg.MgmtUser
                    FileServer       = $cfg.FileServer
                    ShareRoot        = $cfg.ShareRoot
                    MapDriveLetter   = $cfg.MapDriveLetter
                    AutoRename       = $cfg.AutoRename
                    RenamePrefix     = $cfg.RenamePrefix
                    InstallRustDesk  = $cfg.InstallRustDesk
                    RustDeskSetPw    = $cfg.RustDeskSetPw
                    Discover         = $cfg.Discover
                    BlockRdpPublic   = $cfg.BlockRdpPublic
                    TrustedHosts     = $cfg.TrustedHosts
                    RemoteAccess     = $cfg.RemoteAccess
                }
                $out | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigFile
                Write-Host "配置已写入 $ConfigFile" -ForegroundColor Green
                if ($r -eq 'GENDEP' -and -not $SkipDeploy) {
                    Write-Host "即将启动部署..." -ForegroundColor Cyan
                    & .\deploy.ps1 -ConfigFile $ConfigFile
                }
                exit
            }
        }
    }
    if ($nav -eq 'back') { if ($step -gt 1) { $step-- } }
    elseif ($step -lt $total) { $step++ }
}
