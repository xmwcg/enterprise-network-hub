<#
.SYNOPSIS  金网通安装引导器（M1）：把脚本集部署到本机并创建快捷方式与卸载项。
.DESCRIPTION
  交互式一键安装：
    · 检查 PowerShell 5.1+ 与操作系统；
    · 将 scripts/ 复制到目标目录（默认 %ProgramFiles%\JinNetConnect）；
    · 创建桌面快捷方式（中文图形向导 wizard-gui.ps1）；
    · 写入卸载注册表项（控制面板-卸载）；
    · 提示放入厂商签发的 company.lic（注意：安装器【不】生成授权，私钥仅厂商持有）。
  可重复运行（幂等）。卸载：删除目标目录 + 注册表项即可。
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $env:ProgramFiles 'JinNetConnect'),
    [switch]$NoDesktopShortcut
)

$ErrorActionPreference = 'Stop'

# 自动提权（安装需写 ProgramFiles 与注册表）
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -WorkingDirectory $PSScriptRoot
    exit
}

# 1) 环境检查
if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Error "需要 PowerShell 5.1 或更高版本，当前为 $($PSVersionTable.PSVersion)。"; exit 1
}
$os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue)
if ($os -and $os.ProductType -eq 1) { } # 工作站
Write-Host "环境检查通过：PowerShell $($PSVersionTable.PSVersion) / $($os.Caption)" -ForegroundColor Green

# 2) 复制脚本集
$src = $PSScriptRoot
if (-not (Test-Path $src)) { Write-Error "源目录不存在：$src"; exit 1 }
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
Copy-Item -Path (Join-Path $src '*') -Destination $Destination -Recurse -Force
Write-Host "已部署到：$Destination" -ForegroundColor Green

# 3) 桌面快捷方式（指向图形向导）
if (-not $NoDesktopShortcut) {
    $ws = New-Object -ComObject WScript.Shell
    $link = Join-Path ([Environment]::GetFolderPath('Desktop')) '金网通-配置向导.lnk'
    $sc = $ws.CreateShortcut($link)
    $sc.TargetPath = 'powershell.exe'
    $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Destination 'wizard-gui.ps1')`""
    $sc.WorkingDirectory = $Destination
    $sc.Description = '金网通 · 企业局域网互联互通配置向导'
    $sc.Save()
    Write-Host "已创建桌面快捷方式：$link" -ForegroundColor Green
}

# 4) 卸载注册表项（控制面板-程序和功能）
$regPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\JinNetConnect'
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name 'DisplayName'    -Value '金网通 企业局域网互联互通'
Set-ItemProperty -Path $regPath -Name 'DisplayVersion' -Value '1.0.0'
Set-ItemProperty -Path $regPath -Name 'Publisher'      -Value '厦门金奕鸣科技有限公司'
Set-ItemProperty -Path $regPath -Name 'InstallLocation' -Value $Destination
Set-ItemProperty -Path $regPath -Name 'UninstallString' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"Remove-Item -Recurse -Force '$Destination'; Remove-Item -Path '$regPath' -Force\""
Write-Host "已写入卸载信息（控制面板-卸载）。" -ForegroundColor Green

# 5) 授权文件提示（关键：安装器不生成授权，私钥仅厂商持有）
$licDst = Join-Path $Destination 'company.lic'
if (Test-Path $licDst) {
    Write-Host "检测到 company.lic，激活就绪。" -ForegroundColor Green
} else {
    Write-Host @"

【重要】尚未发现授权文件 company.lic。
  · 请向厦门金奕鸣科技获取厂商签发的 company.lic，放入：
      $licDst
  · 或将 Free 版（3 台、仅基础互联）开箱即用，无需授权文件。
  · 注意：本安装器不会生成授权——授权签发须由厂商用 gen-license.ps1 完成（私钥不随产品分发）。
"@ -ForegroundColor Yellow
}

Write-Host @"

安装完成。下一步：
  1) 双击桌面『金网通-配置向导』运行 wizard-gui.ps1；
  2) 放入 company.lic（如需付费版），否则以 Free 版运行；
  3) 按向导生成 company-config.json 后，在每台员工机运行 deploy.ps1。
"@ -ForegroundColor Cyan
