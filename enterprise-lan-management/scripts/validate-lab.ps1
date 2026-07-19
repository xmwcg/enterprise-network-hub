<#
.SYNOPSIS  金网通实验室验证：在公司 2-3 台机器上验证部署结果与试用门控
.DESCRIPTION
  在"管理机/文件服务器"以管理员运行一次，自动检查：
    1) 本机：网络类别(专用) / WinRM 运行 / RDP 3389 监听 / S盘映射 / 本地审计目录
    2) 中心：Mgmt$ 已上报主机数（验证多机互联）
    3) 试用门控：Test-Trial 状态；用 -ForceExpire 可回拨首跑时间模拟"已过期"，确认弹窗逻辑
  每台员工机也可单独运行做自检（不依赖中心）。
.EXAMPLE
  # 正常检查（15天试用期内）
  .\validate-lab.ps1
  # 模拟过期，确认弹窗逻辑
  .\validate-lab.ps1 -ForceExpire
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = ".\company-config.json",
    [int]$TrialDays = 15,
    [switch]$ForceExpire
)
. .\lib-init.ps1
. .\lib-discovery.ps1
. .\lib-audit.ps1
. .\license-core.ps1

Set-TrialConfig -TrialDays $TrialDays
if ($ForceExpire) {
    # 回拨首跑时间，强制进入"已过期"分支，验证 Show-ExpiryNotice 弹窗
    $back = (Get-Date).AddDays(-($TrialDays + 1)).ToString('yyyy-MM-dd HH:mm:ss')
    [ordered]@{ firstRun = $back; trialId = [guid]::NewGuid().ToString() } |
        ConvertTo-Json -Compress | Set-Content -Path (Join-Path $PSScriptRoot 'trial.json') -Encoding utf8
    Write-Host "  [模拟] 已回拨 trial.json 首跑时间至 $back（强制过期）" -ForegroundColor Yellow
}
$pass = 0; $fail = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host ("  [OK]   $name : $detail") -ForegroundColor Green; $script:pass++ }
    else { Write-Host ("  [FAIL] $name : $detail") -ForegroundColor Red; $script:fail++ }
}

Write-Host "`n========== 本机自检 ($env:COMPUTERNAME) ==========" -ForegroundColor Cyan
$prof = Get-NetConnectionProfile | Select-Object -First 1
Check "网络类别=专用" ($prof -and $prof.NetworkCategory -eq 'Private') ($prof.NetworkCategory)
$wr = Get-Service WinRM -ErrorAction SilentlyContinue
Check "WinRM 服务运行" ($wr -and $wr.Status -eq 'Running') ($wr.Status)
$rdp = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
Check "RDP 监听 3389" ($null -ne $rdp) $(if ($rdp) { '监听中' } else { '未监听(家庭版正常)' })
$cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { $null }
$letter = if ($cfg -and $cfg.MapDriveLetter) { $cfg.MapDriveLetter } else { 'S' }
$drv = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
Check "S盘映射($letter`:)" ($null -ne $drv) $(if ($drv) { $drv.Root } else { '未映射' })
$audit = Join-Path $env:ProgramData "CompanyMgmt\audit"
Check "本地审计目录存在" (Test-Path $audit) ($audit)

if ($cfg) {
    $fs = if ($cfg.FileServer -ne 'AUTO') { $cfg.FileServer } else { $env:COMPUTERNAME }
    $hostDir = "\\$fs\Mgmt$\hosts"
    if (Test-Path $hostDir) {
        $n = @(Get-ChildItem $hostDir -Filter *.json).Count
        Check "中心已上报主机数" ($n -ge 1) ("$n 台（含本机，说明多机互联成功）")
    } else {
        Check "中心已上报主机数" $false "未找到 $hostDir（本机可能尚未 deploy 或非文件服务器）"
    }
}

Write-Host "`n========== 试用 / 授权门控 ==========" -ForegroundColor Cyan
$t = Test-Trial
Check "试用状态可读" ($true) ("Edition=$($t.Edition) IsExpired=$($t.IsExpired) DaysLeft=$($t.DaysLeft)")
if ($t.IsExpired) {
    Write-Host "  -> 客户将看到过期引导：" -ForegroundColor Yellow
    Show-ExpiryNotice
} else {
    Write-Host "  -> 当前在试用/已授权期内，不弹过期引导。" -ForegroundColor Gray
}

Write-Host "`n========== 结论 ==========" -ForegroundColor White
Write-Host ("  通过 $pass 项 / 失败 $fail 项") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { Write-Host "  存在失败项，请先在各机运行 deploy.ps1 完成部署，再回到本机重跑。" -ForegroundColor Yellow }
