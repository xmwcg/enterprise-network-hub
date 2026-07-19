<#
.SYNOPSIS  厂商授权吊销工具（M2）：把指定 LicenseId 加入厂商签名的吊销名单。
.DESCRIPTION
  商业闭环的"撤销"能力：客户退款/违约后，即使其手持 .lic 也无法继续使用。
  吊销名单 revoked.json 本身用厂商私钥签名，客户端用内嵌公钥验证后比对 Id，
  防止名单被篡改。本工具仅厂商内部使用（需 vendor.key.json），绝不随产品分发。
.EXAMPLE
  .\revoke-license.ps1 -LicenseId "a1b2c3..." -Reason "客户退款"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LicenseId,
    [string]$Reason = '',
    [string]$PrivateKeyFile = '.\vendor.key.json',
    [string]$RevokeFile = '.\revoked.json'
)
. .\lib-init.ps1
. .\lib-license.ps1

if (-not (Test-Path $PrivateKeyFile)) { Write-Error "未找到厂商私钥 $PrivateKeyFile，请先运行 gen-license.ps1。"; exit 1 }
$privXml = Get-Content $PrivateKeyFile -Raw

# 载入既有名单（若有）并校验其签名
$ids = @()
if (Test-Path $RevokeFile) {
    $doc = Get-Content $RevokeFile -Raw | ConvertFrom-Json
    if ($doc.payload -and $doc.signature) {
        $payload = [System.Convert]::FromBase64String($doc.payload)
        $sig = [System.Convert]::FromBase64String($doc.signature)
        if ($script:LicensePublicKeyXml -eq '__LICENSE_PUBLIC_KEY__') { Write-Error '授权公钥未初始化。'; exit 1 }
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString($script:LicensePublicKeyXml)
        $oid = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
        if (-not $rsa.VerifyData($payload, $oid, $sig)) { Write-Error '现有 revoked.json 签名无效，中止以避免损坏。'; exit 1 }
        $ids = @([System.Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json)
    }
}
if (@($ids) -contains $LicenseId) { Write-Host '该授权已在吊销列表中。' -ForegroundColor Yellow; exit 0 }

$ids += [ordered]@{ id = $LicenseId; reason = $Reason; at = (Get-Date -Format 'yyyy-MM-dd') }

# 用厂商私钥重新签名
$rsa2 = New-Object System.Security.Cryptography.RSACryptoServiceProvider
$rsa2.FromXmlString($privXml)
$payload = [System.Text.Encoding]::UTF8.GetBytes(($ids | ConvertTo-Json -Compress))
$oid2 = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
$sig = $rsa2.SignData($payload, $oid2)
[ordered]@{ payload = [System.Convert]::ToBase64String($payload); signature = [System.Convert]::ToBase64String($sig) } | ConvertTo-Json -Compress | Set-Content -Path $RevokeFile
Write-Host "已吊销 LicenseId=$LicenseId，写入 $RevokeFile" -ForegroundColor Green
Write-Host '请将该 revoked.json 分发/托管给客户（客户端校验时会比对）。' -ForegroundColor Cyan
