<#
.SYNOPSIS  代码签名工具（M1）：用 Authenticode 证书对 scripts/*.ps1 批量签名。
.DESCRIPTION
  对仓库内全部 .ps1 进行 Authenticode 签名，签名后即可用 lib-init 的
  Test-JinSignature 做防篡改校验（M4 门禁）。
  证书来源二选一：
    1) 当前用户/本地计算机证书存储中按 Subject 匹配（推荐，已安装代码证书时）；
    2) 指定 PFX 文件路径 + 密码。
  若无可用证书，打印获取指引并以非零退出码退出（绝不破坏未签名的开发态）。
.EXAMPLE
  .\sign-scripts.ps1                                  # 按默认 Subject 从证书存储取证书签名
  .\sign-scripts.ps1 -PfxPath .\code.pfx -PfxPassword 'x'   # 用 PFX 签名
  .\sign-scripts.ps1 -VerifyOnly                      # 仅校验现有签名，不重新签
#>
[CmdletBinding()]
param(
    [string]$CertSubject = '厦门金奕鸣科技有限公司',
    [string]$PfxPath = '',
    [string]$PfxPassword = '',
    [string]$ScriptsDir = $PSScriptRoot,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

# 解析签名证书
$cert = $null
if ($PfxPath) {
    if (-not (Test-Path $PfxPath)) { Write-Error "PFX 不存在：$PfxPath"; exit 2 }
    $sec = if ($PfxPassword) { ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force } else { $null }
    $cert = if ($sec) { [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path $PfxPath), $sec) }
            else      { [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path $PfxPath)) }
    # 确认具备代码签名用途
    if (-not ($cert.EnhancedKeyUsageList | Where-Object { $_.FriendlyName -like '*Code Signing*' })) {
        Write-Warning "该证书未包含『代码签名』用途（Enhanced Key Usage），系统/杀软可能不信任。"
    }
} else {
    $candidates = @(
        [System.Security.Cryptography.X509Certificates.StoreName]::My,
        [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher
    )
    foreach ($storeName in $candidates) {
        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new($storeName, 'LocalMachine')
        try { $store.Open('ReadOnly'); $cert = $store.Certificates | Where-Object { $_.Subject -like "*$CertSubject*" -and $_.NotAfter -gt (Get-Date) } | Select-Object -First 1; if ($cert) { break } } finally { $store.Close() }
        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new($storeName, 'CurrentUser')
        try { $store.Open('ReadOnly'); $cert = $store.Certificates | Where-Object { $_.Subject -like "*$CertSubject*" -and $_.NotAfter -gt (Get-Date) } | Select-Object -First 1; if ($cert) { break } } finally { $store.Close() }
    }
}

$ps1 = Get-ChildItem -Path $ScriptsDir -Filter *.ps1 -File

if ($VerifyOnly) {
    $ok = $true
    foreach ($f in $ps1) {
        $r = Test-JinSignature -Path $f.FullName
        $tag = if ($r -eq $true) { 'VALID ' } elseif ($r -eq $null) { 'UNSIGNED' } else { 'BAD  ' }
        if ($r -ne $true) { $ok = $false }
        Write-Host ("{0}  {1}" -f $tag, $f.Name)
    }
    if (-not $ok) { Write-Warning "存在未签名或无效签名的脚本。"; exit 1 }
    Write-Host "全部脚本签名有效。" -ForegroundColor Green; exit 0
}

if (-not $cert) {
    Write-Error @"

未找到可用的代码签名证书（Subject 匹配 '$CertSubject'）。
获取方式（二选一）：
  1) 向受信任 CA（如 DigiCert / GlobalSign / 国内 CA）购买『代码签名证书』并安装到本机证书存储；
     EV 代码签名证书还能通过 SmartScreen 快速建立信誉，强烈推荐用于对外发布。
  2) 自签测试：
       New-SelfSignedCertificate -Subject 'CN=$CertSubject' -Type CodeSigningCert `
         -CertStoreLocation Cert:\CurrentUser\My
     注意：自签证书仅本机/受信任内网可用，对外发布须用受信任 CA 证书。
"@
    exit 2
}

Write-Host "使用签名证书：$($cert.Subject)  (有效期至 $($cert.NotAfter.ToString('yyyy-MM-dd')))" -ForegroundColor Cyan
$signed = 0; $failed = 0
foreach ($f in $ps1) {
    try {
        Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert -TimestampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256 | Out-Null
        $r = Test-JinSignature -Path $f.FullName
        if ($r -ne $true) { Write-Warning ("签名后校验失败：{0}" -f $f.Name); $failed++ } else { $signed++; Write-Host ("SIGNED  {0}" -f $f.Name) -ForegroundColor Green }
    } catch {
        Write-Warning ("签名异常 {0}: {1}" -f $f.Name, $_); $failed++
    }
}
Write-Host "`n完成：成功 $signed 个，失败 $failed 个。" -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 }
exit 0
