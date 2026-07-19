<#
.SYNOPSIS  金网通 · 完整硬件与系统信息扫描引擎 V2
.DESCRIPTION
  PS 2.0+ 全兼容。采集：CPU/主板/内存/硬盘/GPU/网卡/显示器/BIOS/OS/软件等。
  输出标准 JSON 到 stdout，供资产管理模块入库。
#>
param([string]$OutputPath, [string]$DetailLevel = "fast")

$PSVersionOK = $PSVersionTable.PSVersion -and $PSVersionTable.PSVersion.Major -ge 5

function Safe-WMI { param([string]$Class,$ns="root\cimv2")
  try { if($PSVersionOK){Get-CimInstance -ClassName $Class -Namespace $ns -ErrorAction Stop}else{Get-WmiObject -Class $Class -Namespace $ns -ErrorAction Stop} } catch{$null}
}
function BytesToGB($b){if(!$b-or$b-le0){0}else{[math]::Round($b/1073741824,2)}}

# 系统
$OS=Safe-WMI Win32_OperatingSystem; $CS=Safe-WMI Win32_ComputerSystem; $BIOS=Safe-WMI Win32_BIOS; $MB=Safe-WMI Win32_BaseBoard
$edition=try{(Get-ComputerInfo -Property WindowsEditionId -ErrorAction Stop).WindowsEditionId}catch{""}

$sys=@{hostname=$env:COMPUTERNAME;osCaption=$OS.Caption;osVersion=$OS.Version;osArch=$OS.OSArchitecture;edition=$edition;isDomain=$CS.PartOfDomain;domainOrWG=if($CS.PartOfDomain){$CS.Domain}else{$CS.Workgroup};manufacturer=$CS.Manufacturer;model=$CS.Model;systemType=$CS.SystemType}

# BIOS
$bios=@{manufacturer=$BIOS.Manufacturer;version=$BIOS.SMBIOSBIOSVersion;serial=$BIOS.SerialNumber}

# 主板
$mb=@{manufacturer=$MB.Manufacturer;product=$MB.Product;serial=$MB.SerialNumber}

# CPU
$cpus=@(Safe-WMI Win32_Processor); $cl=@(); foreach($c in $cpus){$cl+=@{name=($c.Name -replace '\s+',' ');cores=$c.NumberOfCores;threads=$c.NumberOfLogicalProcessors;maxMHz=$c.MaxClockSpeed}}
$cpu=@{count=$cl.Count;totalCores=($cl|%{$_.cores}|Measure -Sum).Sum;detail=$cl}

# 内存
$mems=@(Safe-WMI Win32_PhysicalMemory); $ml=@(); foreach($m in $mems){$ml+=@{slot=$m.DeviceLocator;capGB=BytesToGB $m.Capacity;speed=$m.Speed;part=($m.PartNumber -replace '\s+',' ')}}
$tg=BytesToGB($OS.TotalVisibleMemorySize*1024); $fg=BytesToGB($OS.FreePhysicalMemory*1024)
$mem=@{totalGB=$tg;freeGB=$fg;usedGB=[math]::Round($tg-$fg,2);slots=$ml.Count;modules=$ml}

# 硬盘
$diskList=@(Safe-WMI Win32_DiskDrive); $dl=@(); $pdList=@(Get-PhysicalDisk -ErrorAction SilentlyContinue); foreach($d in $diskList){$pd=$pdList|?{$_.SerialNumber -eq $d.SerialNumber}|Select -First 1;$busType=if($pd){$pd.BusType}else{$d.InterfaceType};$dl+=@{model=($d.Model -replace '\s+',' ');sizeGB=BytesToGB $d.Size;interface=$busType;media=$d.MediaType}}
$vols=@(Safe-WMI Win32_LogicalDisk|?{$_.DriveType -eq 3}); $vl=@(); foreach($v in $vols){$vl+=@{drive=$v.DeviceID;label=$v.VolumeName;totalGB=BytesToGB $v.Size;freeGB=BytesToGB $v.FreeSpace;usagePct=if($v.Size-gt0){[math]::Round(($v.Size-$v.FreeSpace)/$v.Size*100,1)}else{0}}}
$disk=@{physical=$dl;volumes=$vl}

# GPU
$gpuList=@(Safe-WMI Win32_VideoController); $gl=@(); foreach($g in $gpuList){$vram=0;try{$vram=[math]::Round($g.AdapterRAM/1048576,0)}catch{};$gl+=@{name=($g.Name -replace '\s+',' ');vramMB=$vram;driver=$g.DriverVersion}}
$gpu=$gl

# 网卡
$nas=@(Safe-WMI Win32_NetworkAdapter|?{$_.PhysicalAdapter -and $_.NetEnabled}); $nl=@()
foreach($na in $nas){$nl+=@{name=$na.Name;mac=$na.MACAddress;speedMbps=if($na.Speed){[math]::Round($na.Speed/1000000,0)}else{0}}}

$net=$nl

# 显示器
$mons=@(Safe-WMI Win32_DesktopMonitor); $monl=@(); foreach($m in $mons){$monl+=@{name=($m.Name -replace '\s+',' ');w=$m.ScreenWidth;h=$m.ScreenHeight}}

# TPM检测
$tpmOk=$false;try{$tp=Safe-WMI Win32_Tpm -ns 'root\cimv2\Security\MicrosoftTpm';if($tp){$tpmOk=$true}}catch{}

# 输出
$out=@{scanTime=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss');psVersion=$PSVersionTable.PSVersion.ToString();system=$sys;bios=$bios;motherboard=$mb;cpu=$cpu;memory=$mem;disk=$disk;gpu=$gpu;network=$net;monitors=$monl;tpmPresent=$tpmOk}
$json=$out|ConvertTo-Json -Depth 8 -Compress
if($OutputPath){[IO.File]::WriteAllText($OutputPath,$json,[Text.Encoding]::UTF8);Write-Host "OK:$OutputPath"}else{Write-Output $json}