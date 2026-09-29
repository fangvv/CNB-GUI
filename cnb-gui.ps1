<#
CNB 云原生开发环境 · Windows 图形管理面板

零安装：只用 Windows 自带的 PowerShell + .NET（WinForms），不需要 Node / Python / 浏览器。
直连 CNB OpenAPI（https://api.cnb.cool），令牌用 Windows DPAPI 加密存在本机。

启动：双击 CNB-Workspace.bat（或 powershell -STA -File cnb-gui.ps1）
首次运行会弹出设置窗口，填入访问令牌即可：https://cnb.cool/profile/token
#>

# 需要 Windows PowerShell 5.1+（WinForms + DPAPI）。
# 不用文件顶部的 #Requires：bat 走 Invoke-Expression 拉起时它不在「脚本文件」上下文里，
# 行为不确定（可能整段不执行），所以改成运行时检查。
if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show(
        "需要 Windows PowerShell 5.1 或更高版本，当前是 $($PSVersionTable.PSVersion)。",
        'CNB 开发环境', 'OK', 'Error') | Out-Null
    exit
}

# WinForms 必须在 STA 线程；不是就自己重启一个 STA 进程。
# 注意 $PSCommandPath 在「bat 用 Invoke-Expression 拉起」时是空的（见 CNB-Workspace.bat），
# 所以依次退回环境变量 CNB_GUI_SELF（bat 传进来的）、$MyInvocation，
# 保证不管怎么启动都能找到自己、重启自己。
$script:SelfPath = $PSCommandPath
if (-not $script:SelfPath) { $script:SelfPath = $env:CNB_GUI_SELF }
if (-not $script:SelfPath) { $script:SelfPath = $MyInvocation.MyCommand.Path }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA' -and $script:SelfPath) {
    Start-Process -FilePath powershell -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -File `"$($script:SelfPath)`"" -WindowStyle Hidden | Out-Null
    exit
}

# 单例判重要靠 try/catch，所以先把「出错即中断」打开（原来在下面几行，行为不变）
$ErrorActionPreference = 'Stop'

# ---------------- 配置（令牌加密存本机） ----------------
$ConfigDir  = Join-Path $env:APPDATA 'cnb-ws'
$ConfigFile = Join-Path $ConfigDir 'config.json'

# ---------------- 单例：只跑一个实例 ----------------
# 判重用内核级「命名 Mutex」：进程被强杀时句柄随进程一起消失，不会留下「假占用」
# （拿锁文件或进程名去判断，崩一次就再也起不来了）。
# 检测到已经有一个在跑时，本实例不自己开窗口 —— 往「唤醒文件」里戳一下就退出，
# 真正在跑的那个每 0.6 秒扫一次这个文件，看见就把自己弹到前台（见下面 $wakeTimer）。
# 想临时开第二个（比如调试脚本）：先 set CNB_GUI_MULTI=1 再启动。
$script:WakeFile = Join-Path $ConfigDir 'wake'
$script:lastWake = [datetime]::MinValue
$script:mutex    = $null
$createdNew = $false
if ($env:CNB_GUI_MULTI) {
    $createdNew = $true
} else {
    try {
        $script:mutex = New-Object Threading.Mutex -ArgumentList @($true, 'CNB-Workspace-GUI-SingleInstance', ([ref]$createdNew))
    } catch [System.Threading.AbandonedMutexException] {
        $createdNew = $true          # 上一个实例崩了：锁已经归本线程，照样算第一个
    } catch {
        $createdNew = $false         # 打不开（权限 / 完整性级别不同）就当成「已经有一个在跑」
    }
}
if (-not $createdNew) {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        [IO.File]::WriteAllText($script:WakeFile, [datetime]::UtcNow.ToString('o'))
    } catch { }
    # 用 [Environment]::Exit 而不是 exit：本脚本被 bat 用 Invoke-Expression 拉起时，
    # exit 未必能终止整个进程；这里必须干净利落地走人，绝不能再往下开第二个窗口。
    [Environment]::Exit(0)            # 交给已经在跑的那个弹窗，自己安静退出
}
# 记住启动时刻：上一次运行留下的唤醒文件，不该让面板一上来就自己弹出来
if (Test-Path $script:WakeFile) {
    try { $script:lastWake = (Get-Item $script:WakeFile).LastWriteTimeUtc } catch { }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$ApiBase = 'https://api.cnb.cool'

# 这里刻意不改 [Console]::OutputEncoding：Windows PowerShell 5.1 在代码页 936 的 conhost 下
# 强行设成 UTF-8，反而会把中文打成乱码（CNB-Workspace.bat 里也相应去掉了 chcp 65001）。
# 本文件是 UTF-8 带 BOM，解析环节不会乱码；输出交给系统默认代码页最匹配。

$script:cfg = @{ repo = ''; branch = 'main'; ide = 'vscode'; token = '' }

function Load-Config {
    if (Test-Path $ConfigFile) {
        try {
            $j = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in 'repo', 'branch', 'ide', 'token') { if ($j.$k) { $script:cfg[$k] = $j.$k } }
        } catch { }
    }
    if ($script:cfg.ide -notin @('vscode', 'vscode-insiders', 'cursor', 'codebuddy', 'codebuddycn', 'windsurf', 'zed')) {
        $script:cfg.ide = 'vscode'
    }
}

function Save-Config {
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    ($script:cfg | ConvertTo-Json) | Set-Content $ConfigFile -Encoding UTF8
}

function Protect-Token {
    param([string]$Plain)
    if (-not $Plain) { return '' }
    ($Plain | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString)
}

function Get-Token {
    if ($env:CNB_TOKEN) { return $env:CNB_TOKEN }
    if (-not $script:cfg.token) { return '' }
    try {
        $ss = $script:cfg.token | ConvertTo-SecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { return '' }
}

# ---------------- OpenAPI ----------------
function Invoke-CnbApi {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{},
        [hashtable]$Body
    )
    $token = Get-Token
    if (-not $token) { throw '还没有配置访问令牌，请先点「设置」填入' }

    $uri = "$ApiBase/$($Path.TrimStart('/'))"
    if ($Query.Count -gt 0) {
        # 用 EscapeUriString：保留 slug 里的 "/"，只转义空格等真正会破坏 URL 的字符
        $qs = ($Query.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeUriString([string]$_.Value))" }) -join '&'
        $uri = $uri + '?' + $qs
    }
    $p = @{
        Method  = $Method
        Uri     = $uri
        Headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
    }
    if ($Body) { $p.Body = ($Body | ConvertTo-Json -Compress); $p.ContentType = 'application/json' }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    try {
        Invoke-RestMethod @p
    } catch {
        $msg = $_.Exception.Message
        try {
            $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
            $msg = $sr.ReadToEnd(); $sr.Close()
        } catch { }
        throw $msg
    }
}

function Get-Workspaces {
    param([string]$Status)
    $q = @{ page_size = '100' }
    if ($script:cfg.repo) { $q.slug = $script:cfg.repo }
    if ($Status) { $q.status = $Status }
    $r = Invoke-CnbApi -Method Get -Path '/workspace/list' -Query $q
    # 接口给的 list 不一定规整：没有环境时可能是 $null、整个返回本身也可能是个数组、
    # 里面还可能夹着空项。这里统一成「真·数组」并剔掉 $null / 字符串 ——
    # 直接 @($null) 的话 Count 是 1，列表里会凭空多出一行空白环境。
    $raw = if ($r -is [array]) { $r } else { $r.list }
    return @($raw | Where-Object { $null -ne $_ -and $_ -isnot [string] })
}

function Get-Detail {
    param([string]$Sn, [string]$Slug)
    # 详情地址要用「环境自己所在的仓库」拼，而不是全局默认仓库：
    # 默认仓库留空（开源版不内置任何个人仓库）时列表会跨仓库显示，混用会 404。
    if (-not $Slug) { $Slug = $script:cfg.repo }
    Invoke-CnbApi -Method Get -Path "/$Slug/-/workspace/detail/$Sn"
}

# ---------------- 界面 ----------------
Load-Config

# 界面统一用「微软雅黑 UI」：它比「微软雅黑」行距更紧，放在按钮/列表/状态栏上更清爽。
# 系统里没这个字体时 .NET 会静默回退到默认字体，不会报错（非中文 Windows 上就这样）。
# 想换字体只改这里一处。
$UIFontName = 'Microsoft YaHei UI'
function UI-Font {
    param([float]$Size = 10, [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular)
    New-Object Drawing.Font($UIFontName, $Size, $Style)
}

$form = New-Object Windows.Forms.Form
$form.Text = 'CNB 云原生开发环境'
$form.Size = New-Object Drawing.Size(1060, 620)
$form.MinimumSize = New-Object Drawing.Size(880, 540)
$form.StartPosition = 'CenterScreen'
$form.Font = UI-Font            # 子控件会继承，所以只需要在各个「顶层容器」上设

# 列表
$lv = New-Object Windows.Forms.ListView
$lv.Dock = 'Fill'
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $true
$lv.HideSelection = $false
$lv.Font = UI-Font
# 注意：不能用 @(@(..),@(..))，PowerShell 会把嵌套数组平铺
$colNames  = @('状态', '仓库', '分支', '构建号', '创建时间', '备份')
$colWidths = @(90, 250, 100, 200, 185, 115)
for ($i = 0; $i -lt $colNames.Count; $i++) {
    $ch = New-Object Windows.Forms.ColumnHeader
    $ch.Text = $colNames[$i]; $ch.Width = $colWidths[$i]
    $lv.Columns.Add($ch) | Out-Null
}

# 顶部：仓库 / 分支 / 设置 / 刷新
$top = New-Object Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 46

$lblRepo = New-Object Windows.Forms.Label
$lblRepo.Text = '仓库'; $lblRepo.Location = New-Object Drawing.Point(10, 14); $lblRepo.AutoSize = $true
$txtRepo = New-Object Windows.Forms.TextBox
$txtRepo.Location = New-Object Drawing.Point(48, 10); $txtRepo.Width = 280; $txtRepo.Text = $script:cfg.repo
$lblBr = New-Object Windows.Forms.Label
$lblBr.Text = '分支'; $lblBr.Location = New-Object Drawing.Point(338, 14); $lblBr.AutoSize = $true
$txtBr = New-Object Windows.Forms.TextBox
$txtBr.Location = New-Object Drawing.Point(376, 10); $txtBr.Width = 130; $txtBr.Text = $script:cfg.branch
$btnSet = New-Object Windows.Forms.Button
$btnSet.Text = '设置'; $btnSet.Location = New-Object Drawing.Point(518, 8); $btnSet.Size = New-Object Drawing.Size(86, 31)
$btnRefresh = New-Object Windows.Forms.Button
$btnRefresh.Text = '刷新'; $btnRefresh.Location = New-Object Drawing.Point(612, 8); $btnRefresh.Size = New-Object Drawing.Size(86, 31)
$top.Controls.AddRange(@($lblRepo, $txtRepo, $lblBr, $txtBr, $btnSet, $btnRefresh))

# 底部：按钮 + 状态栏
$bottom = New-Object Windows.Forms.Panel
$bottom.Dock = 'Bottom'; $bottom.Height = 92

$statusBar = New-Object Windows.Forms.StatusStrip
$statusBar.Dock = 'Bottom'
$statusBar.Font = UI-Font
$statusLabel = New-Object Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = '准备就绪'
$statusLabel.Spring = $true
$statusLabel.TextAlign = 'MiddleLeft'
$statusBar.Items.Add($statusLabel) | Out-Null

$quotaLabel = New-Object Windows.Forms.ToolStripStatusLabel
$quotaLabel.Text = '额度读取中 ...'
$quotaLabel.TextAlign = 'MiddleRight'
$quotaLabel.AutoSize = $true
$quotaLabel.ForeColor = [Drawing.Color]::DimGray
$quotaLabel.Add_Click({ Refresh-Quota })
$statusBar.Items.Add($quotaLabel) | Out-Null

$flow = New-Object Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Fill'
$flow.FlowDirection = 'LeftToRight'
$flow.Padding = New-Object Windows.Forms.Padding(8, 8, 8, 6)

function New-Button {
    param([string]$Text, [string]$Name)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.Name = $Name
    $b.Size = New-Object Drawing.Size(116, 35)
    $b.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
    $b
}
$btnStart   = New-Button '启动并连接' 'start'
$btnStop    = New-Button '停止' 'stop'
$btnDel     = New-Button '删除' 'del'
$btnClean   = New-Button '全部收工' 'clean'
$btnOpen    = New-Button '打开 VSCode' 'open'
$btnSsh     = New-Button 'SSH 地址' 'ssh'
$btnCopySsh = New-Button '复制 SSH' 'copyssh'
$btnQuit    = New-Button '退出程序' 'quit'
$btnStart.Font = UI-Font 10 Bold          # 主操作加粗，其余按钮继承窗体的常规字重
$flow.Controls.AddRange(@($btnStart, $btnStop, $btnDel, $btnClean, $btnOpen, $btnSsh, $btnCopySsh, $btnQuit))

$toolTip = New-Object Windows.Forms.ToolTip
$toolTip.SetToolTip($btnStart, '没有环境就新建一个，已有就直接连上；就绪后自动拉起 VSCode')
$toolTip.SetToolTip($btnStop,  '未选中时，停止所有运行中的环境')
$toolTip.SetToolTip($btnDel,   '未选中时，删除所有已关闭的环境（最常用）')
$toolTip.SetToolTip($btnClean, '停止 + 删除全部环境，收工用')
$toolTip.SetToolTip($btnOpen,  '用 VSCode 远程连接选中的环境')
$toolTip.SetToolTip($btnSsh,   '弹出连接信息，可选中复制（含接口原始返回，便于排查）')
$toolTip.SetToolTip($btnCopySsh, '不弹窗，把 SSH 登录命令直接复制到剪贴板')
$toolTip.SetToolTip($btnQuit,  '真正退出程序；点窗口右上角 X 只是缩到托盘')

# 添加顺序决定 Dock 布局：Fill 的要先加
$form.Controls.Add($lv)
$form.Controls.Add($bottom)
$bottom.Controls.Add($flow)
$bottom.Controls.Add($statusBar)
$form.Controls.Add($top)

# ---------------- 界面辅助 ----------------
function Set-Status($msg) { $statusLabel.Text = $msg; [Windows.Forms.Application]::DoEvents() }
function Sync-Input { $script:cfg.repo = $txtRepo.Text.Trim(); $script:cfg.branch = $txtBr.Text.Trim() }
# 「打开 VSCode / SSH 地址 / 复制 SSH / 停止」只在有运行中的目标时才可点，否则置灰
$script:runCount = 0
function Update-Actions {
    $sel = @($lv.SelectedItems)
    if ($sel.Count -gt 0) {
        $hasRunning = (@($sel | Where-Object { $_.Tag.status -eq 'running' }).Count -gt 0)
    } else {
        $hasRunning = $script:runCount -gt 0
    }
    foreach ($b in @($btnOpen, $btnSsh, $btnCopySsh, $btnStop)) { $b.Enabled = $hasRunning }
}

function Busy($on) {
    $form.Cursor = if ($on) { [Windows.Forms.Cursors]::WaitCursor } else { [Windows.Forms.Cursors]::Default }
    foreach ($b in @($btnStart, $btnStop, $btnDel, $btnClean, $btnOpen, $btnSsh, $btnCopySsh, $btnRefresh, $btnSet)) { $b.Enabled = -not $on }
    if (-not $on) { Update-Actions }
    [Windows.Forms.Application]::DoEvents()
}
function Alert($msg) { [Windows.Forms.MessageBox]::Show($form, $msg, 'CNB 开发环境', 'OK', 'Error') | Out-Null }
function Confirm($msg) { return ([Windows.Forms.MessageBox]::Show($form, $msg, '请确认', 'YesNo', 'Question') -eq 'Yes') }
function Selected-Items { return @($lv.SelectedItems | ForEach-Object { $_.Tag }) }

# 可复制的信息框。
# MessageBox 是 Win32 原生窗口，文字选不中（Win10 之后只有 Ctrl+C 复制整段这个隐藏操作，
# 且复制出来的格式很脏），所以凡是要给人复制的内容，一律走这个：
# 只读 TextBox 能选中、能 Ctrl+C，再加一个「全部复制」按钮。
function Show-Copyable {
    param([string]$Title, [string]$Text)
    $f = New-Object Windows.Forms.Form
    $f.Text = $Title
    $f.StartPosition = 'CenterParent'
    $f.ClientSize = New-Object Drawing.Size(760, 340)
    $f.MinimumSize = New-Object Drawing.Size(420, 240)
    $f.Font = UI-Font

    $tb = New-Object Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'
    $tb.Location = New-Object Drawing.Point(12, 12)
    $tb.Size = New-Object Drawing.Size(736, 268)
    $tb.Anchor = 'Top, Bottom, Left, Right'
    $tb.Font = UI-Font               # 跟着界面走；地址都是 ASCII，雅黑下一样清楚
    $tb.Text = $Text            # TextBox 认的是 `r`n，只给 `n 不会换行
    $tb.Select(0, 0)

    $bCopy = New-Object Windows.Forms.Button
    $bCopy.Text = '全部复制'; $bCopy.Size = New-Object Drawing.Size(104, 32)
    $bCopy.Location = New-Object Drawing.Point(644, 292)
    $bCopy.Anchor = 'Bottom, Right'
    $bCopy.Add_Click({ [Windows.Forms.Clipboard]::SetText($tb.Text); Set-Status '已复制到剪贴板' })

    $bClose = New-Object Windows.Forms.Button
    $bClose.Text = '关闭'; $bClose.Size = New-Object Drawing.Size(104, 32)
    $bClose.Location = New-Object Drawing.Point(534, 292)
    $bClose.Anchor = 'Bottom, Right'
    $bClose.Add_Click({ $f.Close() })

    $f.Controls.AddRange(@($tb, $bCopy, $bClose))
    $f.AcceptButton = $bClose
    $f.ShowDialog($form) | Out-Null
}

# ---------------- 业务 ----------------
function Refresh-List {
    Busy $true
    Set-Status '正在读取环境列表 ...'
    try {
        Sync-Input
        $list = Get-Workspaces
        $lv.Items.Clear()
        $run = 0
        foreach ($w in $list) {
            $it = New-Object Windows.Forms.ListViewItem
            $it.Text = [string]$w.status
            $it.SubItems.Add([string]$w.slug) | Out-Null
            $it.SubItems.Add([string]$w.branch) | Out-Null
            $it.SubItems.Add([string]$w.sn) | Out-Null
            $it.SubItems.Add([string]$w.create_time) | Out-Null
            $it.SubItems.Add($(if ($w.file_count) { "$($w.file_count) 个文件" } else { '-' })) | Out-Null
            $it.Tag = $w
            if ($w.status -eq 'running') { $run++; $it.ForeColor = [Drawing.Color]::DarkGreen } else { $it.ForeColor = [Drawing.Color]::Gray }
            $lv.Items.Add($it) | Out-Null
        }
        # 三个数字全部从同一个（已规整过的）数组里算出来，已关闭就不可能为负。
        # 旧写法直接拿 $list.Count 当总数：接口把 list 给成 $null / 单个对象 /
        # 自带 count 字段的对象时，$list.Count 不等于真实行数，「总数 − 运行中」
        # 就会被算歪，最离谱的一次是已关闭显示 -1。
        $total  = $list.Count
        $closed = [math]::Max(0, $total - $run)
        $script:runCount = $run
        Set-Status "共 $total 个环境 · 运行中 $run · 已关闭 $closed   （双击运行中的行直接连接；双击已关闭的行按它的仓库/分支重开）"
        $notify.Text = "CNB 开发环境 · 运行中 $run · 已关闭 $closed"
    } catch { Alert $_.Exception.Message; Set-Status '读取失败' } finally { Busy $false }
}

function Get-OrgSlug {
    Sync-Input
    $r = $script:cfg.repo
    if ($r -match '/') { return $r.Split('/')[0] }
    return $r
}

function Refresh-Quota {
    $slug = Get-OrgSlug
    if (-not $slug) { $quotaLabel.Text = '未配置组织（点设置）'; return }
    try {
        $q = Invoke-CnbApi -Method Get -Path "/$slug/-/charge/quota"
        $v = Invoke-CnbApi -Method Get -Path "/$slug/-/charge/volume"

        $devT = [math]::Round($q.dev_in_sec.total / 3600, 1)
        $devU = [math]::Round($v.dev_in_sec / 3600, 1)
        $devF = [math]::Round($v.freeze_dev_in_sec / 3600, 1)
        $devL = [math]::Round($devT - $devU - $devF, 1)

        $crT = [math]::Round($q.credit_in_milli.total / 1000, 1)
        $crU = [math]::Round($v.credit_in_milli / 1000, 1)
        $crF = [math]::Round($v.freeze_credit_in_milli / 1000, 1)
        $crL = [math]::Round($crT - $crU - $crF, 1)

        $gitT = [math]::Round($q.git_in_byte.total / 1073741824, 2)
        $gitU = [math]::Round($v.git_in_byte / 1073741824, 2)
        $objU = [math]::Round($v.object_in_byte / 1073741824, 2)

        $quotaLabel.Text = "开发 $devL/$devT 核时 · AI $crL/$crT 点 · 存储 $gitU/${gitT} GiB   ↻"
        $quotaLabel.ToolTipText = "组织 $slug · $(Get-Date -Format 'yyyy-MM')（点击立即刷新）`n" +
                                  "开发核时   总额 $devT   已用 $devU   冻结 $devF   剩余 $devL`n" +
                                  "AI 点数    总额 $crT   已用 $crU   冻结 $crF   剩余 $crL`n" +
                                  "仓库存储   $gitU / $gitT GiB`n" +
                                  "对象存储   $objU GiB"

        $low = ($devT -gt 0 -and ($devL / $devT) -lt 0.1) -or ($crT -gt 0 -and ($crL / $crT) -lt 0.1)
        $quotaLabel.ForeColor = if ($low) { [Drawing.Color]::Red } else { [Drawing.Color]::Black }
        if ($low) { Set-TrayIcon 'OrangeRed' } else { Set-TrayIcon 'ForestGreen' }
        if ($low -and -not $script:quotaWarned) {
            $script:quotaWarned = $true
            $notify.ShowBalloonTip(8000, 'CNB 额度告急', "开发核时剩 $devL，AI 点数剩 $crL，见底会直接终止任务", 'Warning')
        }
        if (-not $low) { $script:quotaWarned = $false }
    } catch {
        $quotaLabel.Text = '额度读取失败（点击重试）'
        $quotaLabel.ForeColor = [Drawing.Color]::DimGray
    }
}

# 打开 vscode:// / https:// 这类地址。
# 必须经过 explorer.exe 中转：它本来就常驻，不属于本进程的控制台和进程树，
# 否则关掉面板时，随本进程控制台一起退出的 VSCode / 浏览器会被一起带走。
function Start-Url {
    param([string]$Url)
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Url`"" | Out-Null
    } catch {
        Start-Process -FilePath $Url | Out-Null
    }
}

function Open-Client {
    param($Detail)
    $key = $script:cfg.ide
    $url = $Detail.$key
    if (-not $url) { $url = $Detail.vscode }
    if (-not $url) { Alert '这个环境还不支持远程连接（可能尚未就绪）'; return }
    Start-Url $url
    Set-Status "已拉起 $key"
}

function Connect-Sn {
    param([string]$Sn, [string]$Slug)
    Busy $true
    try {
        Set-Status "连接 $Sn ..."
        Open-Client (Get-Detail -Sn $Sn -Slug $Slug)
    } catch { Alert $_.Exception.Message } finally { Busy $false }
}

$waitTimer = New-Object Windows.Forms.Timer
$waitTimer.Interval = 3000
$script:waitSn = ''
$script:waitTicks = 0
$waitTimer.Add_Tick({
    $script:waitTicks++
    try {
        $d = Get-Detail -Sn $script:waitSn
        if ($d.remoteSsh) {
            $waitTimer.Stop()
            Set-Status "环境就绪：$($d.remoteSsh)"
            Refresh-List
            Open-Client $d
            return
        }
    } catch { }
    Set-Status "环境启动中 ... 已等待 $($script:waitTicks * 3) 秒"
    if ($script:waitTicks -gt 60) {
        $waitTimer.Stop()
        Refresh-List
        Alert '等待超时了，可能配额不足或镜像较大。点「SSH 地址」能看到 WebIDE 地址，贴到浏览器里看进度。'
    }
})

function Do-Start {
    Sync-Input
    if (-not $script:cfg.repo) {
        Alert '还没有默认仓库，请先点「设置」填入（格式：组织/仓库）'
        Show-Settings | Out-Null
        return
    }
    Busy $true
    try {
        Set-Status "启动 $($script:cfg.repo) ($($script:cfg.branch)) ..."
        $r = Invoke-CnbApi -Method Post -Path "/$($script:cfg.repo)/-/workspace/start" -Body @{ branch = $script:cfg.branch }
        if ($r.sn) {
            $script:waitSn = $r.sn; $script:waitTicks = 0
            Set-Status "新建环境 $($r.sn)，等待就绪 ..."
            $waitTimer.Start()
            return
        }
        # 已存在：直接连
        $running = @(Get-Workspaces -Status 'running')
        if ($running.Count -eq 0) { Alert '启动返回里没有构建号，列表里也没有运行中的环境'; return }
        Refresh-List
        Open-Client (Get-Detail -Sn $running[0].sn -Slug $running[0].slug)
    } catch { Alert $_.Exception.Message; Set-Status '启动失败' } finally { Busy $false }
}

function Do-Stop {
    Sync-Input
    $items = Selected-Items
    if ($items.Count -eq 0) { $items = @(Get-Workspaces -Status 'running') }
    if ($items.Count -eq 0) { Set-Status '没有运行中的环境'; return }
    if (-not (Confirm "停止这 $($items.Count) 个环境？")) { return }
    Busy $true
    try {
        foreach ($w in $items) {
            Set-Status "停止 $($w.sn) ..."
            Invoke-CnbApi -Method Post -Path '/workspace/stop' -Body @{ sn = $w.sn } | Out-Null
        }
        Refresh-List
        Set-Status "已停止 $($items.Count) 个环境"
    } catch { Alert $_.Exception.Message } finally { Busy $false }
}

function Remove-Many {
    param($Items, [string]$Title)
    if ($Items.Count -eq 0) { Set-Status '没有需要删除的环境'; return }
    $preview = ($Items | ForEach-Object { "  · $($_.sn)  ($($_.slug))" }) -join "`n"
    if (-not (Confirm "$Title $($Items.Count) 个环境？`n`n$preview`n`n未提交的代码会按平台备份机制保存。")) { return }
    Busy $true
    $ok = 0
    try {
        foreach ($w in $Items) {
            Set-Status "删除 $($w.sn) ..."
            Invoke-CnbApi -Method Post -Path '/workspace/delete' -Body @{ sn = $w.sn } | Out-Null
            $ok++
        }
        Refresh-List
        Set-Status "已删除 $ok 个环境"
    } catch { Alert $_.Exception.Message; Refresh-List } finally { Busy $false }
}

function Do-Delete {
    Sync-Input
    $items = Selected-Items
    if ($items.Count -eq 0) {
        $items = @(Get-Workspaces -Status 'closed')
        Remove-Many $items '删除所有已关闭的环境，共'
    } else {
        Remove-Many $items '删除选中的'
    }
}

function Do-Clean {
    Sync-Input
    $all = @(Get-Workspaces)
    if ($all.Count -eq 0) { Set-Status '当前没有任何环境'; return }
    if (-not (Confirm "停止并删除全部 $($all.Count) 个环境？（收工用，未提交代码会自动备份）")) { return }
    Busy $true
    try {
        foreach ($w in $all) {
            if ($w.status -eq 'running') {
                Set-Status "停止 $($w.sn) ..."
                Invoke-CnbApi -Method Post -Path '/workspace/stop' -Body @{ sn = $w.sn } | Out-Null
                Start-Sleep -Seconds 2
            }
        }
        foreach ($w in $all) {
            Set-Status "删除 $($w.sn) ..."
            Invoke-CnbApi -Method Post -Path '/workspace/delete' -Body @{ sn = $w.sn } | Out-Null
        }
        Refresh-List
        Set-Status "已清空 $($all.Count) 个环境"
    } catch { Alert $_.Exception.Message; Refresh-List } finally { Busy $false }
}

function Do-Ssh {
    Sync-Input
    $items = Selected-Items
    if ($items.Count -eq 0) { $items = @(Get-Workspaces -Status 'running') }
    if ($items.Count -eq 0) { Set-Status '没有运行中的环境'; return }
    try {
        $d = Get-Detail -Sn $items[0].sn -Slug $items[0].slug
        # 末尾附上接口原始返回：万一哪天字段名改了（ssh / remoteSsh 取不到值），
        # 看这段就知道真实字段叫什么，改脚本时不用去抓包。
        $txt = @(
            "环境        $($items[0].sn)   （$($items[0].slug) / $($items[0].branch)）"
            ""
            "SSH 登录    $($d.ssh)"
            "远程地址    $($d.remoteSsh)"
            "VSCode      $($d.vscode)"
            "WebIDE      $($d.webide)"
            ""
            "—— 以下为接口原始返回，字段名对不上时用它排查 ——"
            ($d | ConvertTo-Json -Depth 4)
        ) -join "`r`n"
        Show-Copyable '连接信息（可直接选中复制）' $txt
    } catch { Alert $_.Exception.Message }
}

# 不弹窗，直接把 SSH 登录命令塞进剪贴板 —— 这才是「我要用这个地址」时最快的路径
function Do-CopySsh {
    Sync-Input
    $items = Selected-Items
    if ($items.Count -eq 0) { $items = @(Get-Workspaces -Status 'running') }
    if ($items.Count -eq 0) { Set-Status '没有运行中的环境'; return }
    try {
        $d = Get-Detail -Sn $items[0].sn -Slug $items[0].slug
        $s = $d.ssh
        if (-not $s) { $s = $d.remoteSsh }
        if (-not $s) { Alert "这个环境还没给出 SSH 地址。点「SSH 地址」看接口原始返回里到底有哪些字段。"; return }
        [Windows.Forms.Clipboard]::SetText($s)
        Set-Status "已复制 SSH：$s"
    } catch { Alert $_.Exception.Message }
}

function Show-Settings {
    $f = New-Object Windows.Forms.Form
    $f.Text = '设置'
    # 用 ClientSize 而不是 Size：坐标就是工作区坐标，不会被标题栏/边框吃掉高度
    $f.ClientSize = New-Object Drawing.Size(600, 382)
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.Font = UI-Font

    $xLab = 16; $xVal = 110; $wRight = 600 - 16          # 右边距线 = 584

    function Lab($t, $y) {
        $l = New-Object Windows.Forms.Label
        $l.Text = $t; $l.Location = New-Object Drawing.Point($xLab, $y); $l.AutoSize = $true; $l
    }
    $f.Controls.Add((Lab '访问令牌' 22))
    $tToken = New-Object Windows.Forms.TextBox
    $tToken.Location = New-Object Drawing.Point($xVal, 18); $tToken.Width = 380; $tToken.UseSystemPasswordChar = $true
    $tToken.Text = Get-Token
    $bToken = New-Object Windows.Forms.Button
    $bToken.Text = '去申请'; $bToken.Location = New-Object Drawing.Point(498, 16); $bToken.Size = New-Object Drawing.Size(86, 30)
    $bToken.Add_Click({ Start-Url 'https://cnb.cool/profile/token' })

    $f.Controls.Add((Lab '默认仓库' 66))
    $tRepo = New-Object Windows.Forms.TextBox
    $tRepo.Location = New-Object Drawing.Point($xVal, 62); $tRepo.Width = $wRight - $xVal; $tRepo.Text = $script:cfg.repo

    $f.Controls.Add((Lab '默认分支' 110))
    $tBranch = New-Object Windows.Forms.TextBox
    $tBranch.Location = New-Object Drawing.Point($xVal, 106); $tBranch.Width = 210; $tBranch.Text = $script:cfg.branch

    $f.Controls.Add((Lab '客户端' 154))
    $cbIde = New-Object Windows.Forms.ComboBox
    $cbIde.Location = New-Object Drawing.Point($xVal, 150); $cbIde.Width = 240; $cbIde.DropDownStyle = 'DropDownList'
    $cbIde.Items.AddRange(@('vscode', 'vscode-insiders', 'cursor', 'codebuddy', 'codebuddycn', 'windsurf', 'zed'))
    $cbIde.SelectedItem = $script:cfg.ide

    # 说明文字独占一块区域（路径长会自动折行），按钮排在它下面，不会再被压住
    $tip = New-Object Windows.Forms.Label
    # New-Object 的 Type(a, b) 简写走的是「参数模式」：括号里写算术式会被拆坏 ——
    # $wRight - $xLab, 108 会被当成 $wRight - ($xLab, 108)，报 op_Subtraction。
    # 所以先算好再传（下面 $tRepo.Width 那种直接赋值不受影响）。
    $tipW = $wRight - $xLab
    $tip.Location = New-Object Drawing.Point($xLab, 196); $tip.Size = New-Object Drawing.Size($tipW, 108)
    $tip.ForeColor = [Drawing.Color]::DimGray
    $tip.Text = "令牌保存在：`n  $ConfigFile`n用 Windows 本机加密保存，换电脑或换 Windows 用户后需重新填写。`n授权范围需要勾：account-engage:rw、repo-cnb-trigger:rw、repo-cnb-detail:r"

    $bOk = New-Object Windows.Forms.Button
    $bOk.Text = '保存'; $bOk.Location = New-Object Drawing.Point(398, 316); $bOk.Size = New-Object Drawing.Size(88, 32)
    $bCancel = New-Object Windows.Forms.Button
    $bCancel.Text = '取消'; $bCancel.Location = New-Object Drawing.Point(494, 316); $bCancel.Size = New-Object Drawing.Size(88, 32)
    $f.AcceptButton = $bOk; $f.CancelButton = $bCancel
    $bCancel.Add_Click({ $f.DialogResult = 'Cancel'; $f.Close() })
    $bOk.Add_Click({
        $script:cfg.token  = Protect-Token $tToken.Text.Trim()
        $script:cfg.repo   = $tRepo.Text.Trim()
        $script:cfg.branch = $tBranch.Text.Trim()
        $script:cfg.ide    = $cbIde.SelectedItem
        Save-Config
        $txtRepo.Text = $script:cfg.repo
        $txtBr.Text = $script:cfg.branch
        $f.DialogResult = 'OK'
        $f.Close()
    })

    $f.Controls.AddRange(@($tToken, $bToken, $tRepo, $tBranch, $cbIde, $tip, $bOk, $bCancel))
    return ($f.ShowDialog($form))
}

# ---------------- 托盘常驻 ----------------
function New-TrayIcon {
    param([string]$ColorName)
    $bmp = New-Object Drawing.Bitmap(16, 16)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $br = New-Object Drawing.SolidBrush([Drawing.Color]::$ColorName)
    $g.FillEllipse($br, 1, 1, 14, 14)
    $g.Dispose(); $br.Dispose()
    $script:trayBmp = $bmp          # 位图必须留住，否则图标会变空白
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Set-TrayIcon {
    param([string]$ColorName)
    if ($script:iconColor -eq $ColorName) { return }
    $old = $notify.Icon
    $notify.Icon = New-TrayIcon $ColorName
    $script:iconColor = $ColorName
    if ($old) { $old.Dispose() }
}

$notify = New-Object Windows.Forms.NotifyIcon
$notify.Icon = New-TrayIcon 'ForestGreen'
$script:iconColor = 'ForestGreen'
$notify.Text = 'CNB 云原生开发环境'
$notify.Visible = $true

function Show-Panel {
    $form.Show()
    Pop-Front
    Refresh-List
    Refresh-Quota
}

$mOpen  = New-Object Windows.Forms.ToolStripMenuItem('打开面板')
$mStart = New-Object Windows.Forms.ToolStripMenuItem('启动并连接')
$mClean = New-Object Windows.Forms.ToolStripMenuItem('全部收工')
$mQuota = New-Object Windows.Forms.ToolStripMenuItem('刷新额度')
$mSep   = New-Object Windows.Forms.ToolStripSeparator
$mExit  = New-Object Windows.Forms.ToolStripMenuItem('退出')
$mOpen.Font = UI-Font 10 Bold
$trayMenu = New-Object Windows.Forms.ContextMenuStrip
$trayMenu.Items.AddRange(@($mOpen, $mStart, $mClean, $mSep, $mQuota, $mExit))
$notify.ContextMenuStrip = $trayMenu

$mOpen.Add_Click({ Show-Panel })
$mStart.Add_Click({ Show-Panel; Do-Start })
$mClean.Add_Click({ Show-Panel; Do-Clean })
$mQuota.Add_Click({ Refresh-Quota })
$mExit.Add_Click({ $script:exitNow = $true; $form.Close() })
$notify.Add_DoubleClick({ Show-Panel })
$notify.Add_BalloonTipClicked({ Show-Panel })

# 额度每 10 分钟自动刷新
$quotaTimer = New-Object Windows.Forms.Timer
$quotaTimer.Interval = 600000
$quotaTimer.Add_Tick({ Refresh-Quota })
$quotaTimer.Start()

# 第二个实例启动时只在唤醒文件里戳一下就退出，这里扫到就把面板叫到前台。
# 走文件而不是 FindWindow：缩在托盘时主窗口是隐藏的，压根没有窗口可找。
$wakeTimer = New-Object Windows.Forms.Timer
$wakeTimer.Interval = 600
$wakeTimer.Add_Tick({
    try {
        if (Test-Path $script:WakeFile) {
            $t = (Get-Item $script:WakeFile).LastWriteTimeUtc
            if ($t -gt $script:lastWake) { $script:lastWake = $t; Show-Panel }
        }
    } catch { }
})
$wakeTimer.Start()

# ---------------- 事件 ----------------
$btnRefresh.Add_Click({ Refresh-List; Refresh-Quota })
$btnSet.Add_Click({ if ((Show-Settings) -eq 'OK') { Refresh-List } })
$btnStart.Add_Click({ Do-Start })
$btnStop.Add_Click({ Do-Stop })
$btnDel.Add_Click({ Do-Delete })
$btnClean.Add_Click({ Do-Clean })
$btnOpen.Add_Click({
    Sync-Input
    $items = Selected-Items
    if ($items.Count -eq 0) { $items = @(Get-Workspaces -Status 'running') }
    if ($items.Count -eq 0) { Alert '没有运行中的环境，先点「启动并连接」' ; return }
    Connect-Sn $items[0].sn $items[0].slug
})
$btnSsh.Add_Click({ Do-Ssh })
$btnCopySsh.Add_Click({ Do-CopySsh })
$btnQuit.Add_Click({ $script:exitNow = $true; $form.Close() })
$lv.Add_SelectedIndexChanged({ Update-Actions })
$lv.Add_DoubleClick({
    if ($lv.SelectedItems.Count -eq 0) { return }
    $w = $lv.SelectedItems[0].Tag
    if ($w.status -eq 'running') { Connect-Sn $w.sn $w.slug; return }
    # 已关闭的环境：不能默默按顶部输入框的仓库/分支去「新建」—— 那是原来的行为，
    # 跟双击的这一行毫无关系。先把这一行自己的仓库 / 分支回填到顶部，再问一次。
    $txtRepo.Text = $w.slug
    if ($w.branch) { $txtBr.Text = $w.branch }
    Sync-Input
    if (Confirm "这个环境已关闭：$($w.slug) / $($w.branch)`n`n按它自己的仓库和分支重新开一个？") { Do-Start }
})
# 点窗口右上角 X = 最小化到托盘；真退出走「退出程序」或托盘菜单
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:exitNow) { return }
    $e.Cancel = $true
    $form.Hide()
    $notify.ShowBalloonTip(2500, 'CNB 开发环境', '已缩到托盘，双击图标重新打开', 'Info')
})

# ---------- 把窗口抢回前台 ----------
# 从「隐藏」方式启动（bat 里 mshta 的 Run(...,0) = SW_HIDE）时，STARTUPINFO 里带着
# wShowWindow = SW_HIDE 且 STARTF_USESHOWWINDOW 置位。Windows 的规定是：进程首次调用
# ShowWindow 时要沿用这个值 —— 而 WinForms 的 Application.Run 显示主窗体用的正是
# SW_SHOW，于是窗口一出来就是隐藏的，看着就像「最小化 / 没反应」。
# 只有用 SW_SHOWNORMAL 显式调一次 ShowWindow 才能把它顶回来，光设 WindowState 没用。
Add-Type -Namespace Win32 -Name Show -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
function Pop-Front {
    $form.WindowState = 'Normal'
    [Win32.Show]::ShowWindow($form.Handle, 1) | Out-Null      # 1 = SW_SHOWNORMAL
    [Win32.Show]::SetForegroundWindow($form.Handle) | Out-Null
}

$form.Add_Shown({
    Pop-Front
    if (-not (Get-Token)) {
        Set-Status '首次使用：请先填入访问令牌'
        if ((Show-Settings) -eq 'OK') { Refresh-List; Refresh-Quota }
    } else {
        Refresh-List
        Refresh-Quota
    }
})

Update-Actions
[Windows.Forms.Application]::Run($form)

# 收尾：这里出错只会往控制台喷一堆东西，吞掉即可
$ErrorActionPreference = 'SilentlyContinue'
try { $quotaTimer.Stop() } catch { }
try { $wakeTimer.Stop() } catch { }
try { $notify.Visible = $false; $notify.Dispose() } catch { }
try { if ($script:mutex) { $script:mutex.Dispose() } } catch { }
