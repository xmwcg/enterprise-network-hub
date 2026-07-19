<#
.SYNOPSIS  金网通统一授权核心（试用计时 + 版本门控），供脚本/Web/安装包三方案共用
.DESCRIPTION
  在 license.ps1（机器指纹 + license.json HMAC 签名 + Test-License）之上扩展：
    · 试用计时：首次运行写 trial.json，默认 15 天内为 trial 版全功能；
    · 版本判定：trial（试用中）| basic（过期未购，仅基础互联）| pro | enterprise
    · 统一过期引导文案 Show-ExpiryNotice + Open-PurchasePage
  用法（被 deploy.ps1 / manager.ps1 dot-source）：
    . .\license-core.ps1
    $t = Test-Trial          # 返回 IsTrial/IsExpired/Edition/DaysLeft/Licensed
    if ($t.IsExpired) { Show-ExpiryNotice }   # 弹"试用已过期，请购买专业版解锁更多强大功能"
#>
. $PSScriptRoot/license.ps1

$script:TrialDays   = 15
$script:TrialPath   = Join-Path $PSScriptRoot 'trial.json'
# 金网通购买页（挂在你的 aibak.site 站点上，接微信/支付宝支付）
$script:PurchaseUrl = 'https://aibak.site/jinwangtong'

function Set-TrialConfig {
    param([int]$TrialDays, [string]$PurchaseUrl)
    if ($PSBoundParameters.ContainsKey('TrialDays')) { $script:TrialDays = $TrialDays }
    if ($PSBoundParameters.ContainsKey('PurchaseUrl')) { $script:PurchaseUrl = $PurchaseUrl }
}

function New-TrialState {
    $obj = [ordered]@{
        firstRun = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        trialId  = [guid]::NewGuid().ToString()
    }
    $obj | ConvertTo-Json -Compress | Set-Content -Path $script:TrialPath -Encoding utf8
}

function Get-LicenseEdition {
    <# 校验 license.json，有效返回版本字符串，否则 $null #>
    if (-not (Test-Path $script:LicensePath)) { return $null }
    try { $lic = Get-Content $script:LicensePath -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $lic.sign) { return $null }
    $payload = "$($lic.fingerprint)|$($lic.seats)|$($lic.expire)|$($lic.edition)"
    $expect = [System.BitConverter]::ToString(
        [System.Security.Cryptography.HMACSHA256]::new(
            [Text.Encoding]::UTF8.GetBytes($script:LicenseKey)
        ).ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))
    ).Replace('-', '')
    if ($expect -ne $lic.sign) { return $null }
    if ([datetime]::Parse($lic.expire) -lt (Get-Date)) { return $null }
    return $lic.edition
}

function Test-Trial {
    $edition = Get-LicenseEdition
    if ($edition) {
        return [PSCustomObject]@{
            IsTrial   = $false
            IsExpired = $false
            Edition   = $edition
            DaysLeft  = 9999
            Licensed  = $true
        }
    }
    if (-not (Test-Path $script:TrialPath)) { New-TrialState }
    try { $t = Get-Content $script:TrialPath -Raw | ConvertFrom-Json }
    catch { New-TrialState; $t = Get-Content $script:TrialPath -Raw | ConvertFrom-Json }
    $first       = [datetime]::Parse($t.firstRun)
    $elapsedDays = [math]::Floor(((Get-Date) - $first).TotalDays)
    $left        = $script:TrialDays - $elapsedDays
    if ($left -gt 0) {
        return [PSCustomObject]@{ IsTrial = $true; IsExpired = $false; Edition = 'trial'; DaysLeft = $left; Licensed = $false }
    }
    return [PSCustomObject]@{ IsTrial = $true; IsExpired = $true; Edition = 'basic'; DaysLeft = 0; Licensed = $false }
}

function Get-Edition { (Test-Trial).Edition }

function Show-ExpiryNotice {
    Write-Host ''
    Write-Host ('=' * 54) -ForegroundColor Red
    Write-Host '  试用已过期，请购买专业版解锁更多强大功能' -ForegroundColor Red
    Write-Host ("  购买地址：$($script:PurchaseUrl)") -ForegroundColor Yellow
    Write-Host ('=' * 54) -ForegroundColor Red
    Write-Host ''
}

function Open-PurchasePage {
    try { Start-Process $script:PurchaseUrl }
    catch { Write-Warning "无法自动打开浏览器，请手动访问：$($script:PurchaseUrl)" }
}
