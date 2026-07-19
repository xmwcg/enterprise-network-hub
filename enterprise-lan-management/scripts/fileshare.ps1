<#
.SYNOPSIS  金网通 · 跨系统文件共享 V2
.DESCRIPTION
  Windows: SMB 共享一键配置
  Linux: Samba/NFS 配置生成
  Web传输: 局域网 HTTP 文件互传（Python SimpleHTTPServer）
  权限检测 + 一键修复
#>
param(
  [string]$SharePath,           # 要共享的目录路径，默认 C:\ShareFolder
  [string]$ShareName = "JinWangTong",  # 共享名
  [switch]$Remove,              # 移除共享
  [switch]$Status,              # 查看当前共享状态
  [switch]$WebTransfer,         # 启动 Web 文件传输服务
  [int]$WebPort = 8899,         # Web 传输端口
  [switch]$Linux,               # 生成 Linux Samba/NFS 配置
  [switch]$All,                 # 一键全部执行
  [string]$OutputConfig         # 输出配置到文件
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

# ========== 1. SMB 共享（Windows） ==========
function Get-ShareStatus {
  Write-Host "=== 当前共享状态 ==="
  try {
    $shares = Get-WmiObject -Class Win32_Share -Filter "Type=0"  # Type 0 = Disk
    foreach ($s in $shares) {
      Write-Host "  共享名: $($s.Name)"
      Write-Host "    路径: $($s.Path)"
      Write-Host "    描述: $($s.Description)"
      Write-Host ""
    }
    if ($shares.Count -eq 0) { Write-Host "  无磁盘共享" }
  } catch { Write-Host "ERR: $_" }
}

function New-Share {
  if (-not $isAdmin) { Write-Host "ERR:需要管理员权限来创建共享"; return }
  $path = if ($SharePath) { $SharePath } else { "C:\JinWangTongShare" }

  # 创建目录
  if (-not (Test-Path $path)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Write-Host "创建目录: $path"
  }

  # 设置 NTFS 权限（Everyone 读取）
  try {
    $acl = Get-Acl $path
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl $path $acl
    Write-Host "NTFS权限: Everyone Read"
  } catch { Write-Host "WARN: NTFS权限设置失败: $_" }

  # 创建共享
  try {
    $result = ([wmiclass]"Win32_Share").Create($path, $ShareName, 0, $null, "金网通共享文件夹")
    if ($result.ReturnValue -eq 0) {
      Write-Host "OK: 共享已创建 -> \\$env:COMPUTERNAME\$ShareName"
    } else {
      Write-Host "ERR: 共享创建失败 code=$($result.ReturnValue)"
    }
  } catch { Write-Host "ERR: $_" }
}

function Remove-ShareByName {
  if (-not $isAdmin) { Write-Host "ERR:需要管理员权限"; return }
  try {
    $share = Get-WmiObject -Class Win32_Share -Filter "Name='$ShareName'"
    if ($share) { $share.Delete(); Write-Host "OK: 已移除共享 $ShareName" }
    else { Write-Host "共享 $ShareName 不存在" }
  } catch { Write-Host "ERR: $_" }
}

# ========== 2. Web 文件传输（跨平台） ==========
function Start-WebTransfer {
  $path = if ($SharePath) { $SharePath } else { "C:\JinWangTongShare" }
  if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }

  Write-Host "=== 局域网 Web 文件传输 ==="
  Write-Host "  目录: $path"
  Write-Host "  地址: http://$($env:COMPUTERNAME):$WebPort"
  Write-Host ""

  # 获取本机 IP
  $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch "^127\." -and $_.PrefixOrigin -ne "WellKnown" } | Select-Object -First 3)
  foreach ($ip in $ips) {
    Write-Host "  IP: http://$($ip.IPAddress):$WebPort"
  }

  Write-Host ""
  Write-Host "  其他电脑浏览器访问即可下载文件"
  Write-Host "  按 Ctrl+C 停止服务"
  Write-Host ""

  # 启动 Python SimpleHTTP 服务器
  try {
    $pythonCmd = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" }
    elseif (Get-Command python -ErrorAction SilentlyContinue) { "python" }
    else { Write-Host "ERR: 未安装 Python"; return }

    Set-Location $path
    & $pythonCmd -m http.server $WebPort --bind 0.0.0.0
  } catch { Write-Host "ERR: $_" }
}

# ========== 3. Linux Samba/NFS 配置生成 ==========
function Get-LinuxConfig {
  $hostname = $env:COMPUTERNAME
  $path = if ($SharePath) { $SharePath -replace '\\', '/' } else { "/srv/jinwangtong" }

  $sambaConf = @"
# ========== 金网通 Linux Samba 配置 ==========
# 安装: sudo apt install samba -y  或  sudo yum install samba -y
# 应用到 /etc/samba/smb.conf 末尾，然后:
#   sudo systemctl enable smbd --now
#   sudo smbpasswd -a <用户名>

[${ShareName}]
   comment = 金网通共享文件夹
   path = ${path}
   browsable = yes
   writable = no
   read only = yes
   guest ok = yes
   create mask = 0644
   directory mask = 0755

[${ShareName}_rw]
   comment = 金网通共享文件夹(可写)
   path = ${path}
   browsable = yes
   writable = yes
   read only = no
   guest ok = no
   valid users = @jinwangtong
   create mask = 0664
   directory mask = 0775
"@

  $nfsConf = @"
# ========== 金网通 Linux NFS 配置 ==========
# 安装: sudo apt install nfs-kernel-server -y
# 应用到 /etc/exports 末尾，然后:
#   sudo exportfs -a && sudo systemctl restart nfs-kernel-server

${path} *(ro,sync,no_subtree_check,no_root_squash)
"@

  Write-Host "=== Linux Samba 配置 ==="
  Write-Host $sambaConf
  Write-Host "`n=== Linux NFS 配置 ==="
  Write-Host $nfsConf

  if ($OutputConfig) {
    $fullConf = "# 金网通跨系统文件共享配置`n# 生成时间: $(Get-Date)`n`n" + $sambaConf + "`n`n" + $nfsConf
    [IO.File]::WriteAllText($OutputConfig, $fullConf, [Text.Encoding]::UTF8)
    Write-Host "OK: 配置已写入 $OutputConfig"
  }
}

# ========== 主入口 ==========
if ($Status) { Get-ShareStatus; exit }
if ($Remove) { Remove-ShareByName; exit }
if ($WebTransfer) { Start-WebTransfer; exit }
if ($Linux) { Get-LinuxConfig; exit }

if ($All) {
  Write-Host "=== 金网通 一键跨系统文件共享 ==="
  Get-ShareStatus
  Write-Host "---"
  New-Share
  Write-Host "---"
  Get-LinuxConfig
  exit
}

# 默认：创建共享 + 显示 Web 传输提示
New-Share
Write-Host ""
Write-Host "提示: 加 -WebTransfer 可启动局域网 HTTP 传输服务"
Write-Host "提示: 加 -Linux 可生成 Linux 服务器配置"