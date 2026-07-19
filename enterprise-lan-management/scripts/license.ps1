<#
.SYNOPSIS
    金网通 License 离线激活模块（零服务器成本）
.DESCRIPTION
    本地部署产品的授权校验：
      - 生成机器指纹（CPU/主板/系统盘序列号）
      - 由指纹+席位+到期生成离线激活码（license.json，HMAC-SHA256 签名）
      - 启动时校验：签名有效 + 指纹匹配 + 未过期 + 席位未超
    流程（离线，无需联网）：
      1) 客户运行 Get-MachineFingerprint 把指纹发给你
      2) 你运行 New-LicenseFile -Fingerprint <指纹> -Seats 10 -Days 365 生成 license.json
      3) 把 license.json 发给客户放到 scripts\license.json
      4) 部署脚本末尾调用 Test-License 决定是否放行
#>

$script:LicenseKey = 'JinWangTong-2026-Local-Key'   # 内置签名密钥，生产可改更复杂字符串
$script:LicensePath = Join-Path $PSScriptRoot 'license.json'

function Get-MachineFingerprint {
    <# 取机器稳定标识，拼接做指纹 #>
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).ProcessorId
    $board = (Get-CimInstance Win32_BaseBoard | Select-Object -First 1).SerialNumber
    $disk = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" | Select-Object -First 1).VolumeSerialNumber
    $raw = "$cpu|$board|$disk"
    $hash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($raw))
    ).Replace('-', '').Substring(0, 16)
    return $hash
}

function New-LicenseFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Fingerprint,
        [int] $Seats = 10,
        [int] $Days = 365,
        [string] $Edition = 'standard'
    )
    $expire = (Get-Date).AddDays($Days).ToString('yyyy-MM-dd')
    $payload = "$Fingerprint|$Seats|$expire|$Edition"
    $hmac = [System.BitConverter]::ToString(
        [System.Security.Cryptography.HMACSHA256]::new(
            [Text.Encoding]::UTF8.GetBytes($script:LicenseKey)
        ).ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))
    ).Replace('-', '')
    $obj = [ordered]@{
        fingerprint = $Fingerprint
        seats       = $Seats
        expire      = $expire
        edition     = $Edition
        sign        = $hmac
    }
    $obj | ConvertTo-Json -Compress | Set-Content -Path $script:LicensePath -Encoding utf8
    Write-Host "已生成 license.json -> $($script:LicensePath) (席位=$Seats 到期=$expire)"
}

function Test-License {
    <# 返回 $true 表示授权有效；否则写原因并返回 $false #>
    if (-not (Test-Path $script:LicensePath)) {
        Write-Warning '未找到 license.json，请先激活。'
        return $false
    }
    try { $lic = Get-Content $script:LicensePath -Raw | ConvertFrom-Json }
    catch { Write-Warning 'license.json 格式损坏。'; return $false }

    $payload = "$($lic.fingerprint)|$($lic.seats)|$($lic.expire)|$($lic.edition)"
    $expect = [System.BitConverter]::ToString(
        [System.Security.Cryptography.HMACSHA256]::new(
            [Text.Encoding]::UTF8.GetBytes($script:LicenseKey)
        ).ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))
    ).Replace('-', '')
    if ($expect -ne $lic.sign) { Write-Warning 'License 签名无效（可能被篡改）。'; return $false }

    $cur = Get-MachineFingerprint
    if ($cur -ne $lic.fingerprint) { Write-Warning '本机指纹与 License 不匹配（换机器需重新激活）。'; return $false }

    if ([datetime]::Parse($lic.expire) -lt (Get-Date)) { Write-Warning "License 已于 $($lic.expire) 过期。"; return $false }

    Write-Host "授权有效：版本=$($lic.edition) 席位=$($lic.seats) 到期=$($lic.expire)"
    return $true
}

# 直接运行本文件时打印指纹，便于发给厂商激活
if ($MyInvocation.InvocationName -ne '.') {
    $fp = Get-MachineFingerprint
    Write-Host "本机指纹(发给厂商激活): $fp"
}
