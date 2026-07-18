<#
.SYNOPSIS  厂商参考激活服务（M2，仅演示/自测用）：订单号 + 机器指纹 → 返回厂商签名的 .lic。
.DESCRIPTION
  商业闭环"在线激活"供给端的参考实现（HttpListener 本地服务）。
  收到 {order, fingerprint} 后，按厂商内部 orders.json 映射签发 .lic 并返回，
  客户端 Request-OnlineActivation 直接保存为 company.lic 即激活。
  生产环境应替换为真实后端（鉴权、支付对账、限流、HTTPS），本文件仅验证闭环。
.EXAMPLE
  .\activate-server.ps1 -Port 8765 -OrdersFile .\orders.json
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [string]$PrivateKeyFile = '.\vendor.key.json',
    [string]$OrdersFile = '.\orders.json'
)
. .\lib-init.ps1
. .\lib-license.ps1

if (-not (Test-Path $PrivateKeyFile)) { Write-Error "缺少厂商私钥 $PrivateKeyFile。"; exit 1 }
$privXml = Get-Content $PrivateKeyFile -Raw
$orders = if (Test-Path $OrdersFile) { Get-Content $OrdersFile -Raw | ConvertFrom-Json } else { [PSCustomObject]@{} }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch { Write-Error "无法启动监听（可能端口占用或需管理员）：$_"; exit 1 }
Write-Host "激活服务已启动 http://localhost:$Port/  (Ctrl+C 停止)" -ForegroundColor Green
Write-Host "  POST /activate  Body: {""order"":""<订单号>"", ""fingerprint"":""<机器指纹>""}" -ForegroundColor Cyan

try {
    while ($true) {
        $ctx = $listener.GetContext(); $req = $ctx.Request; $resp = $ctx.Response
        $out = ''
        if ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/activate') {
            $reader = New-Object System.IO.StreamReader($req.InputStream)
            $inp = try { $reader.ReadToEnd() | ConvertFrom-Json } catch { $null }
            $order = if ($inp) { $inp.order } else { '' }
            $fp = if ($inp) { $inp.fingerprint } else { '' }
            $cfg = if ($order) { $orders.$order } else { $null }
            if (-not $cfg) {
                $out = (@{ error = '未知订单号或订单未授权' } | ConvertTo-Json)
            } else {
                $features = if ($cfg.Features) { @($cfg.Features) } else { @('interconnect', 'list', 'inventory', 'netpolicy', 'netcheck', 'remotemgmt') }
                $claims = [ordered]@{
                    Id = [guid]::NewGuid().ToString()
                    Company = $cfg.Company
                    Edition = $cfg.Edition
                    MaxDevices = if ($null -ne $cfg.MaxDevices) { $cfg.MaxDevices } else { 50 }
                    Features = $features
                    Issued = (Get-Date -Format 'yyyy-MM-dd')
                    Expiry = if ($cfg.Days -gt 0) { (Get-Date).AddDays($cfg.Days).ToString('yyyy-MM-dd') } else { $null }
                    Fingerprint = $fp
                }
                $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
                $rsa.FromXmlString($privXml)
                $payload = [System.Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))
                $oid = [System.Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256')
                $sig = $rsa.SignData($payload, $oid)
                $out = ([ordered]@{ payload = [System.Convert]::ToBase64String($payload); signature = [System.Convert]::ToBase64String($sig) } | ConvertTo-Json -Compress)
            }
        } else {
            $out = (@{ error = 'method not allowed' } | ConvertTo-Json)
        }
        $buf = [System.Text.Encoding]::UTF8.GetBytes($out)
        $resp.ContentType = 'application/json'; $resp.ContentLength64 = $buf.Length
        $resp.OutputStream.Write($buf, 0, $buf.Length); $resp.OutputStream.Close()
    }
} finally {
    $listener.Stop(); $listener.Close()
}
