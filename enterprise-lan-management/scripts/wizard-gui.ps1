<#
.SYNOPSIS  公司局域网互联互通 - 中文图形化配置向导（WinForms）
.DESCRIPTION
  以中文图形界面逐步选配关键配置，支持「上一步 / 下一步 / 退出」，
  最终生成 company-config.json；可选择直接启动部署（deploy.ps1）。
  关键配置全部由用户在图形菜单中选配，无需手动编辑 JSON。
.PARAMETER ConfigFile  输出的配置文件路径（默认 .\company-config.json）
.PARAMETER SkipDeploy  仅生成配置，不自动启动部署
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = ".\company-config.json",
    [switch]$SkipDeploy
)

. .\lib-init.ps1
. .\lib-license.ps1
# 权限最大化：非管理员自动提权（UAC 由用户确认，即"用户决策"）
if ($MyInvocation.InvocationName -ne '.') { Request-AdminOrElevate -ScriptPath $PSCommandPath -Bound $PSBoundParameters -Unbound $args }

# 授权校验（商业闭环：无效授权即终止向导）
$lic = Get-License -Path $null
if (-not $lic.Valid) { Write-Error "授权校验未通过：$($lic.Reason)"; exit 1 }
$dl = Get-LicenseDaysLeft -Path $null
if ($null -ne $dl) { Write-Host ("授权剩余天数：$dl") -ForegroundColor Cyan }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 暗色主题（匹配 IDE） ----------
$bg       = [System.Drawing.Color]::FromArgb(30, 30, 30)
$panelBg  = [System.Drawing.Color]::FromArgb(37, 37, 38)
$fieldBg  = [System.Drawing.Color]::FromArgb(45, 45, 48)
$fg       = [System.Drawing.Color]::FromArgb(212, 212, 212)
$accent   = [System.Drawing.Color]::FromArgb(14, 99, 156)
$accentFg = [System.Drawing.Color]::FromArgb(255, 255, 255)
$dim      = [System.Drawing.Color]::FromArgb(150, 150, 150)
$okCol    = [System.Drawing.Color]::FromArgb(78, 201, 116)
$yelCol   = [System.Drawing.Color]::FromArgb(220, 180, 70)

# ---------- 状态 ----------
$script:state = [PSCustomObject]@{
    WorkgroupName    = "COMPANY"
    UseDomain        = $false
    DomainName       = ""
    DomainController = ""
    MgmtUser         = "itadmin"
    FileServer       = "AUTO"
    ShareRoot        = "D:\CompanyShare"
    MapDriveLetter   = "S"
    AutoRename       = $true
    RenamePrefix     = "PC"
    InstallRustDesk  = $true
    RustDeskSetPw    = $false
    Discover         = "auto"
    BlockRdpPublic   = $true
    TrustedHosts     = "discovered"
    RemoteAccess     = "none"
}
$script:currentStep = 1
$total = 8
$steps = @("互联模式", "统一管理账号", "文件服务器策略", "自动改名", "家庭版远程替代(RustDesk)", "发现范围", "安全选项", "确认与生成")
$script:inputs = @{}

# ---------- 辅助控件 ----------
function New-Label($text, $x, $y, $w, $h, $color, $size, $bold) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object Drawing.Point($x, $y)
    $l.Size = New-Object Drawing.Size($w, $h)
    $l.ForeColor = if ($color) { $color } else { $fg }
    if ($size) { $l.Font = New-Object Drawing.Font("Microsoft YaHei UI", $size, $(if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular })) }
    $l
}
function New-Radio($text, $checked, $x, $y, $w) {
    $r = New-Object Windows.Forms.RadioButton
    $r.Text = $text; $r.Checked = $checked
    $r.Location = New-Object Drawing.Point($x, $y)
    $r.Size = New-Object Drawing.Size($w, 26)
    $r.ForeColor = $fg
    $r.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
    $r
}
function New-Text($text, $x, $y, $w) {
    $t = New-Object Windows.Forms.TextBox
    $t.Text = $text; $t.Location = New-Object Drawing.Point($x, $y)
    $t.Size = New-Object Drawing.Size($w, 24)
    $t.ForeColor = $fg; $t.BackColor = $fieldBg
    $t.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
    $t
}
function New-Group($text, $x, $y, $w, $h) {
    $g = New-Object Windows.Forms.GroupBox
    $g.Text = $text; $g.Location = New-Object Drawing.Point($x, $y)
    $g.Size = New-Object Drawing.Size($w, $h); $g.ForeColor = $fg
    $g.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
    $g
}

# ---------- 表单 ----------
$form = New-Object Windows.Forms.Form
$form.Text = "公司局域网互联互通 · 中文配置向导  [授权：$($lic.EditionLabel)]"
$form.Size = New-Object Drawing.Size(760, 560)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = $bg
$form.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)

# 左侧步骤导航
$nav = New-Object Windows.Forms.Panel
$nav.Dock = "Left"; $nav.Width = 190; $nav.BackColor = $panelBg
$form.Controls.Add($nav)
$navLabels = @()
for ($i = 0; $i -lt $steps.Count; $i++) {
    $lbl = New-Object Windows.Forms.Label
    $lbl.Text = "  $(($i + 1).ToString('00')). $($steps[$i])"
    $lbl.Location = New-Object Drawing.Point(8, 16 + $i * 34)
    $lbl.Size = New-Object Drawing.Size(174, 28)
    $lbl.ForeColor = $dim
    $lbl.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
    $nav.Controls.Add($lbl)
    $navLabels += $lbl
}

# 右侧内容区
$content = New-Object Windows.Forms.Panel
$content.Dock = "Fill"; $content.BackColor = $bg
$content.AutoScroll = $true
$form.Controls.Add($content)

# 底部按钮区
$btnPanel = New-Object Windows.Forms.Panel
$btnPanel.Dock = "Bottom"; $btnPanel.Height = 54; $btnPanel.BackColor = $panelBg
$form.Controls.Add($btnPanel)

$btnExit = New-Object Windows.Forms.Button
$btnExit.Text = "退出"; $btnExit.Size = New-Object Drawing.Size(90, 32)
$btnExit.Location = New-Object Drawing.Point($form.Width - 104, 11)
$btnExit.BackColor = $accent; $btnExit.ForeColor = $accentFg
$btnExit.FlatStyle = "Flat"; $btnExit.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
$btnPanel.Controls.Add($btnExit)

$btnBack = New-Object Windows.Forms.Button
$btnBack.Text = "上一步"; $btnBack.Size = New-Object Drawing.Size(90, 32)
$btnBack.Location = New-Object Drawing.Point($form.Width - 300, 11)
$btnBack.BackColor = $accent; $btnBack.ForeColor = $accentFg
$btnBack.FlatStyle = "Flat"; $btnBack.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
$btnPanel.Controls.Add($btnBack)

$btnNext = New-Object Windows.Forms.Button
$btnNext.Text = "下一步"; $btnNext.Size = New-Object Drawing.Size(90, 32)
$btnNext.Location = New-Object Drawing.Point($form.Width - 200, 11)
$btnNext.BackColor = $accent; $btnNext.ForeColor = $accentFg
$btnNext.FlatStyle = "Flat"; $btnNext.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10, [Drawing.FontStyle]::Bold)
$btnPanel.Controls.Add($btnNext)

$btnGen = New-Object Windows.Forms.Button
$btnGen.Text = "生成并开始部署"; $btnGen.Size = New-Object Drawing.Size(120, 32)
$btnGen.Location = New-Object Drawing.Point($form.Width - 320, 11)
$btnGen.BackColor = $okCol; $btnGen.ForeColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$btnGen.FlatStyle = "Flat"; $btnGen.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10, [Drawing.FontStyle]::Bold)
$btnGen.Visible = $false
$btnPanel.Controls.Add($btnGen)

$btnGenOnly = New-Object Windows.Forms.Button
$btnGenOnly.Text = "仅生成配置"; $btnGenOnly.Size = New-Object Drawing.Size(100, 32)
$btnGenOnly.Location = New-Object Drawing.Point($form.Width - 196, 11)
$btnGenOnly.BackColor = $accent; $btnGenOnly.ForeColor = $accentFg
$btnGenOnly.FlatStyle = "Flat"; $btnGenOnly.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10)
$btnGenOnly.Visible = $false
$btnPanel.Controls.Add($btnGenOnly)

$btnBack.Add_Click({
    CaptureCurrent
    if ($script:currentStep -gt 1) { $script:currentStep--; Render-Step }
})
$btnNext.Add_Click({
    CaptureCurrent
    if ($script:currentStep -lt $total) { $script:currentStep++; Render-Step }
})
$btnExit.Add_Click({ $form.Close() })
$btnGen.Add_Click({
    CaptureCurrent
    Save-Config
    if (-not $SkipDeploy) {
        Write-Host "即将启动部署..." -ForegroundColor Cyan
        & .\deploy.ps1 -ConfigFile $ConfigFile
    }
    $form.Close()
})
$btnGenOnly.Add_Click({
    CaptureCurrent
    Save-Config
    $form.Close()
})

# ---------- 渲染当前步骤 ----------
function Render-Step {
    $content.Controls.Clear()
    $sp = New-Object Windows.Forms.Panel
    $sp.Dock = "Fill"
    $sp.BackColor = $bg
    $sp.AutoScroll = $true
    $content.Controls.Add($sp)
    $script:inputs = @{}

    $title = New-Label -text ("步骤 $($script:currentStep) / $total ：$($steps[$script:currentStep - 1])") -x 18 -y 12 -w 500 -h 26 -color $accentFg -size 14 -bold $true
    $sp.Controls.Add($title)

    switch ($script:currentStep) {
        1 {
            $i = $script:inputs
            $i.rbWG = New-Radio "工作组（推荐，无需额外服务器）" $true 18 60 360
            $i.rbDOM = New-Radio "AD 域（需域控制器，需手动加域）" $false 18 92 360
            $i.lblWG = New-Label "工作组名：" 40 132 120 24 $fg 10
            $i.txtWG = New-Text $script:state.WorkgroupName 170 128 200
            $i.lblDomain = New-Label "域名（如 corp.local）：" 40 132 160 24 $fg 10
            $i.txtDomain = New-Text $script:state.DomainName 200 128 200
            $i.lblDC = New-Label "域控制器 IP：" 40 168 160 24 $fg 10
            $i.txtDC = New-Text $script:state.DomainController 200 164 200
            $hint = New-Label "提示：域模式需手动将电脑加入域，向导仅记录参数。" 40 210 460 24 $dim 9
            $sp.Controls.AddRange(@($i.rbWG, $i.rbDOM, $i.lblWG, $i.txtWG, $i.lblDomain, $i.txtDomain, $i.lblDC, $i.txtDC, $hint))
            $i.rbWG.Add_CheckedChanged({ Set-Visibility })
            $i.rbDOM.Add_CheckedChanged({ Set-Visibility })
        }
        2 {
            $i = $script:inputs
            $i.lbl = New-Label "请输入统一管理账号名：" 18 60 300 24 $fg 10
            $i.txtMgmt = New-Text $script:state.MgmtUser 18 90 220
            $note = New-Label "说明：该账号密码将在「部署」运行时现场输入，不会写入配置文件。" 18 130 520 24 $yelCol 9
            $sp.Controls.AddRange(@($i.lbl, $i.txtMgmt, $note))
        }
        3 {
            $i = $script:inputs
            $i.rbFS_AUTO = New-Radio "AUTO（自动认领 / 复用已有的 CompanyShare）" $true 18 60 420
            $i.rbFS_NAMED = New-Radio "指定一台主机名作为文件服务器" $false 18 92 420
            $i.rbFS_THIS = New-Radio "本机即为文件服务器" $false 18 124 420
            $i.txtFSName = New-Text "PC-FILE" 40 158 200
            $i.lblShare = New-Label "共享根目录：" 18 200 120 24 $fg 10
            $i.txtShareRoot = New-Text $script:state.ShareRoot 140 196 240
            $i.lblMap = New-Label "映射盘符：" 18 236 120 24 $fg 10
            $i.txtMapDrive = New-Text $script:state.MapDriveLetter 140 232 60
            $sp.Controls.AddRange(@($i.rbFS_AUTO, $i.rbFS_NAMED, $i.rbFS_THIS, $i.txtFSName, $i.lblShare, $i.txtShareRoot, $i.lblMap, $i.txtMapDrive))
            $i.rbFS_NAMED.Add_CheckedChanged({ Set-Visibility })
        }
        4 {
            $i = $script:inputs
            $i.rbRN_ON = New-Radio "开启（把 WIN-xxxx / DESKTOP-xxxx 改为 前缀-NN）" $true 18 60 460
            $i.rbRN_OFF = New-Radio "关闭" $false 18 92 460
            $i.lblPrefix = New-Label "改名前缀：" 40 132 120 24 $fg 10
            $i.txtPrefix = New-Text $script:state.RenamePrefix 160 128 120
            $sp.Controls.AddRange(@($i.rbRN_ON, $i.rbRN_OFF, $i.lblPrefix, $i.txtPrefix))
            $i.rbRN_ON.Add_CheckedChanged({ Set-Visibility })
            $i.rbRN_OFF.Add_CheckedChanged({ Set-Visibility })
        }
        5 {
            $i = $script:inputs
            $i.rbRD_ON = New-Radio "自动安装 RustDesk（家庭版远程桌面替代，推荐）" $true 18 60 460
            $i.rbRD_OFF = New-Radio "关闭" $false 18 92 460
            $i.gbRDpw = New-Group "是否为 RustDesk 设置无人值守密码？" 40 126 420 96
            $i.rbRD_PW_YES = New-Radio "是（部署时现场输入，不存盘）" $true 56 150 380
            $i.rbRD_PW_NO = New-Radio "否（仅安装，手动设置）" $false 56 184 380
            $i.gbRDpw.Controls.AddRange(@($i.rbRD_PW_YES, $i.rbRD_PW_NO))
            $sp.Controls.AddRange(@($i.rbRD_ON, $i.rbRD_OFF, $i.gbRDpw))
            $i.rbRD_ON.Add_CheckedChanged({ Set-Visibility })
            $i.rbRD_OFF.Add_CheckedChanged({ Set-Visibility })
        }
        6 {
            $i = $script:inputs
            $i.rbDisc_AUTO = New-Radio "自动（使用本机所在子网）" $true 18 60 420
            $i.rbDisc_MANUAL = New-Radio "手动指定范围" $false 18 92 420
            $i.lblRange = New-Label "范围（如 192.168.1.1-254 或 192.168.1.0/24）：" 40 132 320 24 $fg 10
            $i.txtRange = New-Text "192.168.1.1-254" 40 160 240
            $sp.Controls.AddRange(@($i.rbDisc_AUTO, $i.rbDisc_MANUAL, $i.lblRange, $i.txtRange))
            $i.rbDisc_MANUAL.Add_CheckedChanged({ Set-Visibility })
        }
        7 {
            $i = $script:inputs
            $gb1 = New-Group "是否禁止 RDP 暴露到公网？" 18 56 420 78
            $i.rbBlock_YES = New-Radio "是（推荐：不要把 3389 映射到公网）" $true 16 22 380
            $i.rbBlock_NO = New-Radio "否（不推荐）" $false 16 48 380
            $gb1.Controls.AddRange(@($i.rbBlock_YES, $i.rbBlock_NO))

            $gb2 = New-Group "WinRM TrustedHosts 范围？" 18 148 420 108
            $i.rbTH_disc = New-Radio "仅发现的对端 IP（推荐）" $true 16 22 380
            $i.rbTH_all = New-Radio "全部（*）" $false 16 48 380
            $i.rbTH_off = New-Radio "关闭" $false 16 74 380
            $gb2.Controls.AddRange(@($i.rbTH_disc, $i.rbTH_all, $i.rbTH_off))

            $gb3 = New-Group "是否需要远程 / 外网办公接入？" 18 270 420 108
            $i.rbRA_none = New-Radio "不需要远程办公" $true 16 22 380
            $i.rbRA_ts = New-Radio "Tailscale（零信任组网）" $false 16 48 380
            $i.rbRA_zt = New-Radio "ZeroTier（虚拟局域网）" $false 16 74 380
            $gb3.Controls.AddRange(@($i.rbRA_none, $i.rbRA_ts, $i.rbRA_zt))

            $sp.Controls.AddRange(@($gb1, $gb2, $gb3))
        }
        8 {
            $s = $script:state
            $mode = if ($s.UseDomain) { "AD 域 ($($s.DomainName) / $($s.DomainController))" } else { "工作组 $($s.WorkgroupName)" }
            $rn = if ($s.AutoRename) { "开启，前缀 $($s.RenamePrefix)" } else { "关闭" }
            $rd = if ($s.InstallRustDesk) { "开启（无人值守密码: $(if ($s.RustDeskSetPw) { '部署时输入' } else { '手动' })）" } else { "关闭" }
            $lines = @(
                "互联模式      : $mode",
                "管理账号      : $($s.MgmtUser)（密码部署时输入）",
                "文件服务器    : $($s.FileServer)",
                "共享根目录    : $($s.ShareRoot)  映射盘符: $($s.MapDriveLetter):",
                "自动改名      : $rn",
                "RustDesk      : $rd",
                "发现范围      : $($s.Discover)",
                "安全          : RDP公网=$(if($s.BlockRdpPublic){'禁止'}else{'允许'})  TrustedHosts=$($s.TrustedHosts)  远程接入=$($s.RemoteAccess)"
            )
            $y = 60
            foreach ($ln in $lines) {
                $sp.Controls.Add((New-Label $ln 18 $y 700 24 $fg 10)); $y += 28
            }
            $sp.Controls.Add((New-Label "请确认以上配置，点击「生成并开始部署」或「仅生成配置」。" 18 ($y + 10) 600 24 $yelCol 10))
        }
    }

    # 还原控件值到 state（仅当前步已渲染的）
    Restore-Values

    # 导航高亮
    for ($k = 0; $k -lt $navLabels.Count; $k++) {
        if ($k -eq ($script:currentStep - 1)) { $navLabels[$k].ForeColor = $accentFg; $navLabels[$k].Font = New-Object Drawing.Font("Microsoft YaHei UI", 10, [Drawing.FontStyle]::Bold) }
        else { $navLabels[$k].ForeColor = $dim; $navLabels[$k].Font = New-Object Drawing.Font("Microsoft YaHei UI", 10) }
    }

    # 按钮状态
    $btnBack.Enabled = ($script:currentStep -gt 1)
    if ($script:currentStep -eq $total) {
        $btnNext.Visible = $false; $btnGen.Visible = $true; $btnGenOnly.Visible = $true
    } else {
        $btnNext.Visible = $true; $btnGen.Visible = $false; $btnGenOnly.Visible = $false
    }

    Set-Visibility
}

function Restore-Values {
    $i = $script:inputs; $s = $script:state
    switch ($script:currentStep) {
        1 {
            if ($s.UseDomain) { $i.rbDOM.Checked = $true; $i.rbWG.Checked = $false }
            else { $i.rbWG.Checked = $true; $i.rbDOM.Checked = $false }
        }
        3 {
            if ($s.FileServer -eq "AUTO") { $i.rbFS_AUTO.Checked = $true }
            elseif ($s.FileServer -eq $env:COMPUTERNAME) { $i.rbFS_THIS.Checked = $true }
            else { $i.rbFS_NAMED.Checked = $true; $i.txtFSName.Text = $s.FileServer }
        }
        4 {
            if ($s.AutoRename) { $i.rbRN_ON.Checked = $true } else { $i.rbRN_OFF.Checked = $true }
        }
        5 {
            if ($s.InstallRustDesk) { $i.rbRD_ON.Checked = $true } else { $i.rbRD_OFF.Checked = $true }
            if ($s.RustDeskSetPw) { $i.rbRD_PW_YES.Checked = $true } else { $i.rbRD_PW_NO.Checked = $true }
        }
        6 {
            if ($s.Discover -eq "auto") { $i.rbDisc_AUTO.Checked = $true } else { $i.rbDisc_MANUAL.Checked = $true; $i.txtRange.Text = $s.Discover }
        }
        7 {
            $i.rbBlock_YES.Checked = $s.BlockRdpPublic; $i.rbBlock_NO.Checked = (-not $s.BlockRdpPublic)
            $i.rbTH_disc.Checked = ($s.TrustedHosts -eq "discovered"); $i.rbTH_all.Checked = ($s.TrustedHosts -eq "*"); $i.rbTH_off.Checked = ($s.TrustedHosts -eq "off")
            $i.rbRA_none.Checked = ($s.RemoteAccess -eq "none"); $i.rbRA_ts.Checked = ($s.RemoteAccess -eq "tailscale"); $i.rbRA_zt.Checked = ($s.RemoteAccess -eq "zerotier")
        }
    }
}

function Set-Visibility {
    $i = $script:inputs; $s = $script:currentStep
    if ($s -eq 1) {
        $wg = $i.rbWG.Checked
        $i.lblWG.Visible = $wg; $i.txtWG.Visible = $wg
        $i.lblDomain.Visible = (-not $wg); $i.txtDomain.Visible = (-not $wg)
        $i.lblDC.Visible = (-not $wg); $i.txtDC.Visible = (-not $wg)
    }
    if ($s -eq 3) { $i.txtFSName.Visible = $i.rbFS_NAMED.Checked }
    if ($s -eq 4) {
        $on = $i.rbRN_ON.Checked
        $i.lblPrefix.Visible = $on; $i.txtPrefix.Visible = $on
    }
    if ($s -eq 5) { $i.gbRDpw.Visible = $i.rbRD_ON.Checked }
    if ($s -eq 6) { $i.lblRange.Visible = $i.rbDisc_MANUAL.Checked; $i.txtRange.Visible = $i.rbDisc_MANUAL.Checked }
}

function CaptureCurrent {
    $i = $script:inputs
    switch ($script:currentStep) {
        1 {
            if ($i.rbWG.Checked) {
                $script:state.UseDomain = $false
                $script:state.WorkgroupName = $i.txtWG.Text.Trim()
            } else {
                $script:state.UseDomain = $true
                $script:state.DomainName = $i.txtDomain.Text.Trim()
                $script:state.DomainController = $i.txtDC.Text.Trim()
            }
        }
        2 { $script:state.MgmtUser = $i.txtMgmt.Text.Trim() }
        3 {
            if ($i.rbFS_AUTO.Checked) { $script:state.FileServer = "AUTO" }
            elseif ($i.rbFS_NAMED.Checked) { $script:state.FileServer = $i.txtFSName.Text.Trim() }
            else { $script:state.FileServer = $env:COMPUTERNAME }
            $script:state.ShareRoot = $i.txtShareRoot.Text.Trim()
            $script:state.MapDriveLetter = $i.txtMapDrive.Text.Trim()
        }
        4 {
            if ($i.rbRN_ON.Checked) { $script:state.AutoRename = $true; $script:state.RenamePrefix = $i.txtPrefix.Text.Trim() }
            else { $script:state.AutoRename = $false }
        }
        5 {
            if ($i.rbRD_ON.Checked) {
                $script:state.InstallRustDesk = $true
                $script:state.RustDeskSetPw = $i.rbRD_PW_YES.Checked
            } else { $script:state.InstallRustDesk = $false }
        }
        6 {
            if ($i.rbDisc_AUTO.Checked) { $script:state.Discover = "auto" }
            else { $script:state.Discover = $i.txtRange.Text.Trim() }
        }
        7 {
            $script:state.BlockRdpPublic = $i.rbBlock_YES.Checked
            if ($i.rbTH_all.Checked) { $script:state.TrustedHosts = "*" }
            elseif ($i.rbTH_off.Checked) { $script:state.TrustedHosts = "off" }
            else { $script:state.TrustedHosts = "discovered" }
            if ($i.rbRA_ts.Checked) { $script:state.RemoteAccess = "tailscale" }
            elseif ($i.rbRA_zt.Checked) { $script:state.RemoteAccess = "zerotier" }
            else { $script:state.RemoteAccess = "none" }
        }
        8 { }
    }
}

function Save-Config {
    $s = $script:state
    $out = [ordered]@{
        WorkgroupName    = $s.WorkgroupName
        UseDomain        = $s.UseDomain
        DomainName       = $s.DomainName
        DomainController = $s.DomainController
        MgmtUser         = $s.MgmtUser
        FileServer       = $s.FileServer
        ShareRoot        = $s.ShareRoot
        MapDriveLetter   = $s.MapDriveLetter
        AutoRename       = $s.AutoRename
        RenamePrefix     = $s.RenamePrefix
        InstallRustDesk  = $s.InstallRustDesk
        RustDeskSetPw    = $s.RustDeskSetPw
        Discover         = $s.Discover
        BlockRdpPublic   = $s.BlockRdpPublic
        TrustedHosts     = $s.TrustedHosts
        RemoteAccess     = $s.RemoteAccess
    }
    $out | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigFile
    Write-Host "配置已写入 $ConfigFile" -ForegroundColor Green
}

# ---------- 启动 ----------
Render-Step
[Windows.Forms.Application]::EnableVisualStyles() | Out-Null
$form.ShowDialog() | Out-Null
