<#
.SYNOPSIS  授权与激活库（商业闭环核心）
.DESCRIPTION
  提供离线授权校验能力，构成"商业上线"闭环的关键一环：
    · RSA-2048 签名验证（防伪造/篡改）
    · 有效期校验
    · 设备数上限校验
    · 功能权益门禁（按版本开放能力）
  公钥内嵌于本文件，供客户端验证；私钥仅由厂商 gen-license.ps1 持有，绝不入库/分发。
  未检测到 .lic 文件时，默认按 Free 版运行（3 台设备、仅基础互联 + 主机列表），
  保证内部用户开箱可用，同时把高级管控能力留给授权版本，形成营收闭环。
.NOTES
  本文件中的公钥初始为占位符，由厂商在发布前运行一次 gen-license.ps1 自动替换；
  若仍为占位符，则视为"厂商未初始化"，校验直接失败。
#>

# 内嵌公钥（发布前由 gen-license.ps1 写入真实 RSA 公钥 XML）
$script:LicensePublicKeyXml = '__LICENSE_PUBLIC_KEY__'

# 版本与功能权益模型（商业分层）
$script:EditionDefs = [ordered]@{
    Free       = [ordered]@{ MaxDevices = 3;  Features = @('interconnect', 'list');                                                          Label = '免费版' }
    Trial      = [ordered]@{ MaxDevices = 25; Features = @('interconnect', 'list', 'inventory', 'netpolicy', 'netcheck', 'remotemgmt');     Label = '试用版(30天)' }
    Pro        = [ordered]@{ MaxDevices = 50; Features = @('interconnect', 'list', 'inventory', 'netpolicy', 'netcheck', 'remotemgmt');     Label = '专业版' }
    Enterprise = [ordered]@{ MaxDevices = 0;  Features = @('interconnect', 'list', 'inventory', 'netpolicy', 'netcheck', 'remotemgmt', 'support'); Label = '企业版' }
}

function New-LicenseResult {
    param([bool]$Valid, [string]$Reason, [string]$Source = '')
    $def = $script:EditionDefs['Free']
    [PSCustomObject]@{
        Valid        = $Valid
        Reason       = $Reason
        Source       = $Source
        Company      = ''
        Edition      = 'Free'
        EditionLabel = $def.Label
        MaxDevices   = $def.MaxDevices
        Features     = $def.Features
        Expiry       = $null
        Issued       = $null
    }
}

function Get-LicenseFile {
    param([string]$Path)
    if ($Path -and (Test-Path $Path)) { return $Path }
    $cands = @('.\company.lic', (Join-Path $PSScriptRoot 'company.lic'), (Join-Path (Get-Location) 'company.lic'))
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return $null
}

<#
.SYNOPSIS  读取并校验授权文件
.OUTPUTS  PSCustomObject { Valid, Reason, Source, Company, Edition, EditionLabel, MaxDevices, Features, Expiry, Issued }
#>
function Get-License {
    [CmdletBinding()]
    param([string]$Path)
    $file = Get-LicenseFile -Path $Path
    if (-not $file) {
        $def = $script:EditionDefs['Free']
        return [PSCustomObject]@{
            Valid = $true; Reason = '未检测到授权文件，按 Free 版运行（功能受限，可联系厂商升级）。'
            Source = 'default-free'; Company = ''; Edition = 'Free'; EditionLabel = $def.Label
            MaxDevices = $def.MaxDevices; Features = $def.Features; Expiry = $null; Issued = $null
        }
    }
    try {
        $doc = Get-Content $file -Raw | ConvertFrom-Json
        if (-not $doc.payload -or -not $doc.signature) { return New-LicenseResult -Valid $false -Reason '授权文件格式非法。' -Source $file }
        $payload = [System.Convert]::FromBase64String($doc.payload)
        $sig = [System.Convert]::FromBase64String($doc.signature)
        if ($script:LicensePublicKeyXml -eq '__LICENSE_PUBLIC_KEY__') {
            return New-LicenseResult -Valid $false -Reason '授权公钥未初始化（厂商未运行 gen-license.ps1 写入公钥）。' -Source $file
        }
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString($script:LicensePublicKeyXml)
        $oid = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
        if (-not $rsa.VerifyData($payload, $oid, $sig)) {
            return New-LicenseResult -Valid $false -Reason '授权签名校验失败（文件被篡改或非法）。' -Source $file
        }
        $claims = [System.Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json
        $expiry = if ($claims.Expiry) { [datetime]::Parse($claims.Expiry) } else { $null }
        if ($expiry -and $expiry -lt (Get-Date)) {
            return New-LicenseResult -Valid $false -Reason "授权已过期（有效期至 $($expiry.ToString('yyyy-MM-dd'))），请续费/升级。" -Source $file
        }
        $ed = if ($claims.Edition -and $script:EditionDefs[$claims.Edition]) { $claims.Edition } else { 'Free' }
        $feats = if ($claims.Features) { @($claims.Features) } else { $script:EditionDefs[$ed].Features }
        $max = if ($null -ne $claims.MaxDevices) { [int]$claims.MaxDevices } else { $script:EditionDefs[$ed].MaxDevices }
        [PSCustomObject]@{
            Valid = $true; Reason = '授权有效。'; Source = $file
            Company = $claims.Company; Edition = $ed; EditionLabel = $script:EditionDefs[$ed].Label
            MaxDevices = $max; Features = $feats; Expiry = $expiry; Issued = $claims.Issued
        }
    } catch {
        return New-LicenseResult -Valid $false -Reason "授权文件解析失败：$_" -Source $file
    }
}

<#
.SYNOPSIS  授权校验 + 功能权益门禁 + 设备数上限
.DESCRIPTION
  在部署/管控脚本启动时调用。返回授权对象；不通过则返回 $null 并输出错误。
#>
function Assert-License {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$RequireFeature,
        [int]$CurrentDevices = 0,
        [switch]$Quiet
    )
    $lic = Get-License -Path $Path
    if (-not $lic.Valid) {
        Write-Error "授权校验未通过：$($lic.Reason)"
        return $null
    }
    if ($RequireFeature -and $lic.Features -notcontains $RequireFeature) {
        $editions = ($script:EditionDefs.GetEnumerator() | Where-Object { $_.Value.Features -contains $RequireFeature } | ForEach-Object { $_.Key }) -join ' / '
        Write-Error "当前授权版本（$($lic.EditionLabel)）不包含功能「$RequireFeature」。需升级至：$editions。"
        return $null
    }
    if ($lic.MaxDevices -gt 0 -and $CurrentDevices -gt $lic.MaxDevices) {
        Write-Error "已超出授权设备数上限（$CurrentDevices / $($lic.MaxDevices)）。请升级授权或联系厂商。"
        return $null
    }
    if (-not $Quiet) {
        $exp = if ($lic.Expiry) { $lic.Expiry.ToString('yyyy-MM-dd') } else { '永久' }
        $cap = if ($lic.MaxDevices -eq 0) { '不限' } else { [string]$lic.MaxDevices }
        Write-Host "授权：$($lic.EditionLabel)  公司=$($lic.Company)  设备上限=$cap  有效期至=$exp" -ForegroundColor Cyan
    }
    $lic
}

<#
.SYNOPSIS  统计已注册设备数（用于设备上限门禁）
#>
function Get-DeviceCount {
    param([string]$FileServerHost)
    if (-not $FileServerHost) { return 1 }
    try {
        $dir = "\\$FileServerHost\Mgmt$\hosts"
        if (Test-Path $dir) { return @(Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue).Count }
    } catch {}
    return 1
}
