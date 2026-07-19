<#
.SYNOPSIS  金网通 · 安装包编译脚本 V2
.DESCRIPTION
  自动调用 Inno Setup Compiler 编译 installer.iss 生成 setup.exe，
  然后用 Authenticode 签名（如果证书可用）。
.PARAMETER Version  安装包版本号
.PARAMETER OutputDir  输出目录
#>
param(
  [string]$Version = "2.0.0",
  [string]$OutputDir = ".\build\output",
  [switch]$Sign,
  [string]$PfxPath,
  [string]$PfxPassword
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildDir   = Join-Path $ScriptRoot "build"

# ========== 1. 查找 Inno Setup Compiler ==========
$iscc = $null
$paths = @(
  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
  "C:\Program Files\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
)
foreach ($p in $paths) {
  if (Test-Path $p) { $iscc = $p; break }
}

if (-not $iscc) {
  Write-Host "ERR: 未找到 Inno Setup Compiler (ISCC.exe)"
  Write-Host "  请安装 Inno Setup: https://jrsoftware.org/isdl.php"
  exit 1
}

Write-Host "Inno Setup: $iscc"

# ========== 2. 更新版本号 ==========
$issFile = Join-Path $BuildDir "installer.iss"
$issContent = [IO.File]::ReadAllText($issFile)
$issContent = $issContent -replace '#define MyAppVersion "[\d\.]+"', "#define MyAppVersion `"$Version`""
[IO.File]::WriteAllText($issFile, $issContent, [Text.Encoding]::UTF8)
Write-Host "版本: $Version"

# ========== 3. 编译 ==========
Write-Host "编译中..."
$result = & $iscc "/O$OutputDir" $issFile 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host "ERR: 编译失败"
  Write-Host $result
  exit 1
}

Write-Host "OK: 编译完成"

# 找到生成的 exe
$setupFile = Get-ChildItem -Path $OutputDir -Filter "*.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($setupFile) {
  $sizeMB = [math]::Round($setupFile.Length / 1MB, 1)
  Write-Host "  安装包: $($setupFile.FullName) ($sizeMB MB)"
} else {
  Write-Host "WARN: 未找到安装包文件"
}

# ========== 4. Authenticode 签名 ==========
if ($Sign) {
  $cert = $null
  if ($PfxPath) {
    $sec = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
    $cert = Get-PfxCertificate -FilePath $PfxPath
  } else {
    $certs = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue)
    if ($certs.Count -gt 0) { $cert = $certs[0] }
  }

  if ($cert) {
    Set-AuthenticodeSignature -FilePath $setupFile.FullName -Certificate $cert -TimestampServer "http://timestamp.digicert.com"
    Write-Host "签名: OK -> $($setupFile.FullName)"
  } else {
    Write-Host "WARN: 未找到代码签名证书，已跳过签名"
  }
}

Write-Host ""
Write-Host "=== 安装包构建完成 ==="
Write-Host "  文件: $($setupFile.FullName)"
Write-Host "  版本: $Version"
Write-Host "  大小: $sizeMB MB"