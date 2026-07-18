<#
.SYNOPSIS  厂商授权签发工具（仅厂商内部使用，切勿随产品分发）
.DESCRIPTION
  商业闭环的"供给端"：
    1) 首次运行自动生成 RSA-2048 密钥对：
       - 私钥存 vendor.key.json（务必保密、加入 .gitignore、绝不随产品分发）
       - 公钥自动写入 lib-license.ps1 的占位符，供客户端验证
    2) 对授权声明（公司/版本/设备数/有效期/功能）用私钥签名，输出 .lic 文件
  客户拿到 .lic 放入 scripts/ 即完成激活；工具每次启动校验，超限/过期即阻断，驱动续费。
.PARAMETER Company      授权公司名
.PARAMETER Edition      Free / Trial / Pro / Enterprise
.PARAMETER MaxDevices   设备数上限（0=不限；不填则按版本默认）
.PARAMETER Days         有效天数（0=永久）；Trial 建议 30
.PARAMETER Features     功能列表（逗号分隔）；不填按版本默认
.PARAMETER OutFile      输出 .lic 路径
.PARAMETER PrivateKeyFile  厂商私钥存储路径（保密）
#>
[CmdletBinding()]
param(
    [string]$Company = '示例客户公司',
    [ValidateSet('Free', 'Trial', 'Pro', 'Enterprise')][string]$Edition = 'Pro',
    [int]$MaxDevices = 0,
    [int]$Days = 365,
    [string]$Features = '',
    [string]$OutFile = '.\company.lic',
    [string]$PrivateKeyFile = '.\vendor.key.json'
)
. .\lib-init.ps1

# 各版本默认设备上限（MaxDevices=0 且非企业版时使用）
$edDefs = [ordered]@{
    Free       = 3
    Trial      = 25
    Pro        = 50
    Enterprise = 0
}
$edFeatures = [ordered]@{
    Free       = @('interconnect', 'list')
    Trial      = @('interconnect', 'list', 'inventory', 'netpolicy', 'netcheck', 'remotemgmt')
    Pro        = @('interconnect', 'list', 'inventory', 'netpolicy', 'netcheck', 'remotemgmt')
    Enterprise = @('interconnect', 'list', 'inventory', 'netpolicy', 'netcheck', 'remotemgmt', 'support')
}

# ---------- 1) 密钥对初始化（仅一次） ----------
$libPath = Join-Path $PSScriptRoot 'lib-license.ps1'
if (-not (Test-Path $PrivateKeyFile)) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
    $privXml = $rsa.ToXmlString($true)
    $pubXml = $rsa.ToXmlString($false)
    $privXml | Set-Content -Path $PrivateKeyFile -Encoding UTF8
    # 写入公钥到 lib-license.ps1（替换占位符）
    $lib = Get-Content $libPath -Raw
    $lib = $lib.Replace("'__LICENSE_PUBLIC_KEY__'", "'$pubXml'")
    Set-Content -Path $libPath -Value $lib
    Write-Host "已生成 RSA-2048 密钥对。" -ForegroundColor Green
    Write-Host "  私钥 -> $PrivateKeyFile（请保密、加入 .gitignore、切勿随产品分发）" -ForegroundColor Yellow
    Write-Host "  公钥已写入 lib-license.ps1。" -ForegroundColor Green
} else {
    $privXml = Get-Content $PrivateKeyFile -Raw
    Write-Host "复用已有私钥：$PrivateKeyFile" -ForegroundColor Cyan
}

# ---------- 2) 组装授权声明 ----------
if ($MaxDevices -eq 0 -and $Edition -ne 'Enterprise') { $MaxDevices = $edDefs[$Edition] }
$features = if ($Features) { @($Features -split ',') } else { $edFeatures[$Edition] }
$claims = [ordered]@{
    Company    = $Company
    Edition    = $Edition
    MaxDevices = $MaxDevices
    Features   = $features
    Issued     = (Get-Date -Format 'yyyy-MM-dd')
    Expiry     = if ($Days -gt 0) { (Get-Date).AddDays($Days).ToString('yyyy-MM-dd') } else { $null }
}

# ---------- 3) 签名并输出 .lic ----------
$rsa2 = New-Object System.Security.Cryptography.RSACryptoServiceProvider
$rsa2.FromXmlString($privXml)
$payload = [System.Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))
$oid = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
$sig = $rsa2.SignData($payload, $oid)
$out = [ordered]@{
    payload  = [System.Convert]::ToBase64String($payload)
    signature = [System.Convert]::ToBase64String($sig)
}
$out | ConvertTo-Json -Compress | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "已签发授权 -> $OutFile" -ForegroundColor Green
Write-Host "  版本=$Edition  设备上限=$(if($MaxDevices -eq 0){'不限'}else{$MaxDevices})  有效期=$(if($Days -gt 0){"$Days 天"}else{'永久'})  功能=$(($features -join ','))" -ForegroundColor Cyan
