<#
.SYNOPSIS  统一初始化：编码 + 控制台 + 自动提权（所有入口脚本请先 dot-source 本文件）
.DESCRIPTION
  · 统一文件写入编码为 UTF-8（带 BOM），彻底杜绝 PowerShell 5.1 默认 ANSI 读取导致的中文乱码；
    PowerShell 7 下使用 utf8BOM，保证跨版本一致。
  · 控制台输出设为 UTF-8，避免中文在终端显示乱码。
  · 提供 Request-AdminOrElevate：非管理员时自动提权（UAC 由用户确认），实现"权限最大化 + 用户决策"。
#>

# ---------- 1) 文件写入一律 UTF-8（带 BOM，跨 PS 5.1 / 7 一致） ----------
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $enc = 'utf8BOM'
} else {
    $enc = 'utf8'   # Windows PowerShell 5.1 中 utf8 = 带 BOM 的 UTF-8
}
$PSDefaultParameterValues['Out-File:Encoding']      = $enc
$PSDefaultParameterValues['Set-Content:Encoding']   = $enc
$PSDefaultParameterValues['Add-Content:Encoding']   = $enc
$PSDefaultParameterValues['Export-Csv:Encoding']    = $enc

# ---------- 2) 控制台输出 UTF-8，避免中文在终端乱码 ----------
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------- 3) 自动提权（权限最大化，UAC 由用户确认 = 用户决策） ----------
function Request-AdminOrElevate {
    [CmdletBinding()]
    param(
        [string]$ScriptPath,
        [hashtable]$Bound = @{},
        [array]$Unbound = @()
    )
    $wp = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($wp.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) { return }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('-NoProfile -ExecutionPolicy Bypass -File "')
    [void]$sb.Append($ScriptPath)
    [void]$sb.Append('"')
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [switch]) {
            if ($v.IsPresent) { [void]$sb.Append(" -$k") }
        } else {
            [void]$sb.Append(" -$k ""$v""")
        }
    }
    foreach ($a in $Unbound) { [void]$sb.Append(" ""$a""") }

    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList $sb.ToString() `
            -Verb RunAs `
            -WorkingDirectory (Split-Path $ScriptPath)
        exit
    } catch {
        Write-Error ("自动提权失败（可能被取消或受限于组策略）。请右键 PowerShell 选择「以管理员身份运行」后重试。`n" + $_)
        exit 1
    }
}

# ---------- 4) 代码签名校验（防篡改，M1 工具函数；默认不启用，供 sign-scripts.ps1 与 M4 门禁使用） ----------
function Test-JinSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedSubject = ''
    )
    if (-not (Test-Path $Path)) { return $false }
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    } catch {
        return $false
    }
    if ($sig.Status -eq 'NotFound') { return $null }   # 未签名 = 开发态（允许）
    if ($sig.Status -ne 'Valid') { return $false }     # 签名存在但无效 = 篡改/过期
    if ($ExpectedSubject -and $sig.SignerCertificate.Subject -notlike "*$ExpectedSubject*") { return $false }
    return $true
}
