<#
.SYNOPSIS  统一审计日志（溯源追责）
.DESCRIPTION
  所有部署 / 管控动作写入本地与中心（Mgmt$\audit）的 JSONL 日志，供公司溯源追责。
  每条日志含：时间、操作员、目标、动作、结果等字段。本地始终留存，中心可达时同步。
.PARAMETER FileServerHost  文件服务器主机名（为空则只写本地）
.PARAMETER LogName         日志文件名（默认 operations；改名溯源用 rename）
.PARAMETER Entry           日志条目对象（哈希或 PSCustomObject）
#>
function Write-Audit {
    [CmdletBinding()]
    param(
        [string]$FileServerHost,
        [string]$LogName = "operations",
        [Parameter(Mandatory)]$Entry
    )
    $Entry.Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    if (-not $Entry.Operator) { $Entry.Operator = $env:USERNAME }
    $line = $Entry | ConvertTo-Json -Compress -Depth 4
    $localDir = Join-Path $env:ProgramData "CompanyMgmt\audit"
    try {
        if (-not (Test-Path $localDir)) { New-Item -ItemType Directory -Path $localDir -Force | Out-Null }
        Add-Content -Path (Join-Path $localDir "$LogName.log") -Value $line -Encoding UTF8
    } catch {}
    if ($FileServerHost) {
        $ad = "\\$FileServerHost\Mgmt$\audit"
        try {
            if (-not (Test-Path $ad)) { New-Item -ItemType Directory -Path $ad -Force | Out-Null }
            Add-Content -Path "$ad\$LogName.log" -Value $line -Encoding UTF8
        } catch {}
    }
}
