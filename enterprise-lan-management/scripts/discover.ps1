<#
.SYNOPSIS  仅做局域网发现，打印全网对端（只读，不修改任何配置）
.DESCRIPTION  用于部署前预览：看脚本会"看到"哪些电脑。
#>
param([string]$ConfigFile = ".\company-config.json")
. .\lib-init.ps1
. .\lib-discovery.ps1

$cfg = if (Test-Path $ConfigFile) { Get-Content $ConfigFile -Raw | ConvertFrom-Json } else { [PSCustomObject]@{ Discover = "auto" } }
$selfIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } | Select-Object -First 1).IPAddress

$peers = Find-Peers -Range $cfg.Discover -SelfIP $selfIP
$peers | Format-Table -AutoSize
Write-Host "共发现 $($peers.Count) 个地址（含本机）。" -ForegroundColor Green
