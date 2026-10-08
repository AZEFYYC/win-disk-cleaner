#Requires -Version 5.1
<#
    Windows 磁盘清理工具 (DiskTempCleaner)
    ----------------------------------------
    只删除已知的临时文件 / 缓存目录内容，不改注册表、不卸载软件、不碰个人文件。
    - 默认保留目录本身，只清空内容
    - 正在被占用的文件自动跳过并计入统计
    - 支持预览模式（-DryRun），不删除任何东西
    - 需要管理员权限的项目会自动跳过（或先提权重跑）

    常用示例：
        .\CleanTemp.ps1 -DryRun -Deep                    仅预览（推荐第一次这么用）
        .\CleanTemp.ps1 -Safe                            快速清理
        .\CleanTemp.ps1 -Deep                            深度清理
        .\CleanTemp.ps1 -All -IncludeRecycleBin -Yes     彻底清理，不再询问
        .\CleanTemp.ps1 -OlderThanDays 7                 只删 7 天以前的临时文件
#>
[CmdletBinding()]
param(
    [switch]$DryRun,                 # 只预览不删除
    [switch]$Safe,                   # 安全项（默认）
    [switch]$Deep,                   # 安全项 + 深度项
    [switch]$All,                    # 安全 + 深度 + 额外
    [switch]$Yes,                    # 不询问直接执行
    [switch]$NoLog,                  # 不写日志
    [switch]$RestartExplorer,        # 清理缩略图缓存后重启资源管理器
    [switch]$IncludeRecycleBin,      # 清空回收站
    [switch]$IncludeWindowsOld,      # 删除 Windows.old / 升级残留
    [switch]$IncludeMemoryDump,      # 删除内存转储、小型转储
    [switch]$IncludeDevCache,        # 清理 pip / npm / NuGet / Yarn 缓存
    [ValidateRange(0, 3650)]
    [int]$OlderThanDays = 0,         # 只删除 N 天以前的文件，0 = 全部
    [string]$LogDir
)

# =====================================================================
# 基础环境
# =====================================================================

$script:IsAdmin = $false
$script:LogLines = New-Object 'System.Collections.Generic.List[string]'
$script:PendingLine = ''
$script:SeenPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Write-Log {
    param(
        [string]$Text = '',
        [string]$Color = 'Gray',
        [switch]$NoNewline
    )
    if ($Color -eq 'None') {
        if ($NoNewline) { Write-Host $Text -NoNewline } else { Write-Host $Text }
    }
    else {
        if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
        else { Write-Host $Text -ForegroundColor $Color }
    }
    if ($NoNewline) {
        $script:PendingLine = $script:PendingLine + $Text
    }
    else {
        $script:LogLines.Add($script:PendingLine + $Text) | Out-Null
        $script:PendingLine = ''
    }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Get-SystemDriveFree {
    try {
        $name = $env:SystemDrive.TrimEnd(':')
        $d = Get-PSDrive -Name $name -ErrorAction Stop
        return [long]$d.Free
    }
    catch { return [long](-1) }
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

# =====================================================================
# 删除辅助（长路径 / 占用文件 / 空目录）
# =====================================================================

function ConvertTo-LongPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.Length -lt 240) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function Remove-PathForce {
    param(
        [string]$Path,
        [switch]$Recurse
    )
    try {
        Remove-Item -LiteralPath $Path -Recurse:$Recurse -Force -ErrorAction Stop
        return $true
    }
    catch { }

    $lp = ConvertTo-LongPath $Path
    if ($lp -ne $Path) {
        try {
            Remove-Item -LiteralPath $lp -Recurse:$Recurse -Force -ErrorAction Stop
            return $true
        }
        catch { }
        try {
            if ([System.IO.Directory]::Exists($lp)) { [System.IO.Directory]::Delete($lp, $true) }
            elseif ([System.IO.File]::Exists($lp)) { [System.IO.File]::Delete($lp) }
            else { return $false }
            return $true
        }
        catch { return $false }
    }
    return $false
}

function Get-PathSize {
    param([string]$Path)

    $isDir = $false
    try { $isDir = [System.IO.Directory]::Exists((ConvertTo-LongPath $Path)) } catch { $isDir = $false }

    if (-not $isDir) {
        try {
            $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            return [long]$fi.Length
        }
        catch {
            try {
                $fi = New-Object System.IO.FileInfo((ConvertTo-LongPath $Path))
                return [long]$fi.Length
            }
            catch { return [long]0 }
        }
    }

    $total = [long]0
    try {
        $files = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)
        foreach ($f in $files) { $total = $total + [long]$f.Length }
    }
    catch { }
    return $total
}

function Remove-EmptyDirectories {
    param([string]$Path)
    try {
        $dirs = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue)
        $ordered = @($dirs | Sort-Object -Property @{ Expression = { $_.FullName.Length } } -Descending)
        foreach ($d in $ordered) {
            try {
                $children = @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)
                if ($children.Count -eq 0) {
                    Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
                }
            }
            catch { }
        }
    }
    catch { }
}

function Grant-PathOwnership {
    param([string]$Path)
    try {
        $takeown = Join-Path $env:SystemRoot 'System32\takeown.exe'
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        if (Test-Path -LiteralPath $takeown) {
            & $takeown /F $Path /R /A /D Y 2>$null | Out-Null
        }
        if (Test-Path -LiteralPath $icacls) {
            & $icacls $Path /grant '*S-1-5-32-544:F' /T /C /Q 2>$null | Out-Null
        }
        return $true
    }
    catch { return $false }
}

# =====================================================================
# 目标解析与目录清空
# =====================================================================

function Resolve-TargetDirectories {
    param([string]$Pattern)
    $result = New-Object 'System.Collections.Generic.List[string]'
    if ($Pattern.Contains('*') -or $Pattern.Contains('?')) {
        try {
            $items = @(Get-ChildItem -Path $Pattern -Directory -Force -ErrorAction SilentlyContinue)
            foreach ($i in $items) { $result.Add($i.FullName) | Out-Null }
        }
        catch { }
    }
    else {
        if (Test-Path -LiteralPath $Pattern -PathType Container) { $result.Add($Pattern) | Out-Null }
    }
    return $result
}

function Resolve-TargetItems {
    param([string]$Pattern)
    $result = New-Object 'System.Collections.Generic.List[string]'
    if ($Pattern.Contains('*') -or $Pattern.Contains('?')) {
        try {
            $items = @(Get-ChildItem -Path $Pattern -Force -ErrorAction SilentlyContinue)
            foreach ($i in $items) { $result.Add($i.FullName) | Out-Null }
        }
        catch { }
    }
    else {
        if (Test-Path -LiteralPath $Pattern) { $result.Add($Pattern) | Out-Null }
    }
    return $result
}

function Clear-DirectoryContent {
    param(
        [string]$Path,
        [string]$Filter = '*',
        [int]$Days = 0,
        [bool]$WhatIf = $false
    )

    $out = [pscustomobject]@{
        Freed   = [long]0
        Deleted = 0
        Skipped = 0
        Failed  = 0
        Exists  = $true
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { $out.Exists = $false; return $out }

    $cutoff = $null
    if ($Days -gt 0) { $cutoff = (Get-Date).AddDays(-1 * $Days) }

    $gciArgs = @{
        LiteralPath = $Path
        Recurse     = $true
        Force       = $true
        File        = $true
        ErrorAction = 'SilentlyContinue'
    }
    if ($Filter -and $Filter -ne '*') { $gciArgs['Filter'] = $Filter }

    $files = @()
    try { $files = @(Get-ChildItem @gciArgs) } catch { $files = @() }

    foreach ($f in $files) {
        if ($cutoff -ne $null -and $f.LastWriteTime -gt $cutoff) { $out.Skipped++; continue }
        $len = [long]0
        try { $len = [long]$f.Length } catch { $len = [long]0 }
        if ($WhatIf) {
            $out.Freed = $out.Freed + $len
            $out.Deleted++
            continue
        }
        if (Remove-PathForce -Path $f.FullName) {
            $out.Freed = $out.Freed + $len
            $out.Deleted++
        }
        else {
            $out.Failed++
        }
    }

    if (-not $WhatIf) { Remove-EmptyDirectories -Path $Path }
    return $out
}

# =====================================================================
# 清理项目定义
#   Group: Safe  = 安全，随时可清
#          Deep  = 深度，系统缓存 / 日志 / 浏览器缓存
#          Extra = 额外，回收站 / Windows.old / 内存转储 / 开发缓存
# =====================================================================

function Get-CleanTargetList {
    $list = New-Object System.Collections.ArrayList

    # ---------------- 安全项 ----------------
    $list.Add(@{
            Id = 'UserTemp'; Name = '用户临时文件 (%TEMP%)'; Group = 'Safe'; Kind = 'Dir'
            Paths = @('%TEMP%', '%TMP%'); Filter = '*'; Admin = $false
            Note = '程序运行期间产生的临时文件，占用中的文件会被跳过'
        }) | Out-Null

    $list.Add(@{
            Id = 'CrashDumps'; Name = '应用崩溃转储 (CrashDumps)'; Group = 'Safe'; Kind = 'Dir'
            Paths = @('%LOCALAPPDATA%\CrashDumps'); Filter = '*'; Admin = $false
            Note = ''
        }) | Out-Null

    $list.Add(@{
            Id = 'UserWER'; Name = '用户体验报告缓存 (WER)'; Group = 'Safe'; Kind = 'Dir'
            Paths = @(
                '%LOCALAPPDATA%\Microsoft\Windows\WER\ReportQueue',
                '%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive',
                '%LOCALAPPDATA%\Microsoft\Windows\WER\Temp'
            )
            Filter = '*'; Admin = $false; Note = ''
        }) | Out-Null

    $list.Add(@{
            Id = 'D3DSCache'; Name = 'DirectX 着色器缓存'; Group = 'Safe'; Kind = 'Dir'
            Paths = @('%LOCALAPPDATA%\D3DSCache'); Filter = '*'; Admin = $false
            Note = '游戏首次运行会重新编译着色器'
        }) | Out-Null

    $list.Add(@{
            Id = 'INetCache'; Name = '系统网络缓存 (INetCache)'; Group = 'Safe'; Kind = 'Dir'
            Paths = @('%LOCALAPPDATA%\Microsoft\Windows\INetCache'); Filter = '*'; Admin = $false
            Note = '不含 Cookie，不影响登录状态'
        }) | Out-Null

    $list.Add(@{
            Id = 'WindowsTemp'; Name = '系统临时文件 (Windows\Temp)'; Group = 'Safe'; Kind = 'Dir'
            Paths = @('%SystemRoot%\Temp'); Filter = '*'; Admin = $true
            Note = '部分文件被系统占用，重启后可清理更多'
        }) | Out-Null

    $list.Add(@{
            Id = 'SystemTemp'; Name = '系统级临时目录 (SystemTemp)'; Group = 'Safe'; Kind = 'Dir'
            Paths = @('%SystemRoot%\SystemTemp'); Filter = '*'; Admin = $true
            Note = 'Win11 24H2 及以上才有此目录'
        }) | Out-Null

    # ---------------- 深度项 ----------------
    $list.Add(@{
            Id = 'ThumbnailCache'; Name = '缩略图 / 图标缓存'; Group = 'Deep'; Kind = 'Items'
            Paths = @(
                '%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db',
                '%LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache_*.db'
            )
            Filter = '*'; Admin = $false
            Note = '正在使用的缓存文件会被跳过；重启资源管理器后立即生效'
        }) | Out-Null

    $list.Add(@{
            Id = 'WindowsUpdate'; Name = 'Windows 更新下载缓存'; Group = 'Deep'; Kind = 'Dir'
            Paths = @('%SystemRoot%\SoftwareDistribution\Download'); Filter = '*'; Admin = $true
            Service = @('wuauserv', 'bits')
            Note = '通常释放空间最多；不会删除已安装的更新'
        }) | Out-Null

    $list.Add(@{
            Id = 'DeliveryOptimization'; Name = '传递优化缓存'; Group = 'Deep'; Kind = 'Exec'
            Paths = @(); Filter = '*'; Admin = $true
            Note = '调用系统命令 Delete-DeliveryOptimizationCache'
            Action = {
                param($Target, $WhatIf)
                if ($WhatIf) { return '预览：将删除传递优化缓存' }
                if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                    try {
                        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
                        return '已删除传递优化缓存'
                    }
                    catch { return ('删除失败：' + $_.Exception.Message) }
                }
                return '当前系统不支持该命令，已跳过'
            }
        }) | Out-Null

    $list.Add(@{
            Id = 'Prefetch'; Name = '预读取文件 (Prefetch)'; Group = 'Deep'; Kind = 'Dir'
            Paths = @('%SystemRoot%\Prefetch'); Filter = '*.pf'; Admin = $true
            Note = '下次开机 / 启动程序会略微变慢'
        }) | Out-Null

    $list.Add(@{
            Id = 'CbsLogs'; Name = '组件安装日志 (CBS)'; Group = 'Deep'; Kind = 'Dir'
            Paths = @('%SystemRoot%\Logs\CBS'); Filter = '*'; Admin = $true; Note = ''
        }) | Out-Null

    $list.Add(@{
            Id = 'DismLogs'; Name = 'DISM 日志'; Group = 'Deep'; Kind = 'Dir'
            Paths = @('%SystemRoot%\Logs\DISM'); Filter = '*'; Admin = $true; Note = ''
        }) | Out-Null

    $list.Add(@{
            Id = 'WuLogs'; Name = 'Windows 更新日志'; Group = 'Deep'; Kind = 'Dir'
            Paths = @('%SystemRoot%\Logs\WindowsUpdate'); Filter = '*'; Admin = $true; Note = ''
        }) | Out-Null

    $list.Add(@{
            Id = 'LiveKernelReports'; Name = '内核实时报告 (LiveKernelReports)'; Group = 'Deep'; Kind = 'Dir'
            Paths = @('%SystemRoot%\LiveKernelReports'); Filter = '*'; Admin = $true; Note = ''
        }) | Out-Null

    $list.Add(@{
            Id = 'MachineWER'; Name = '系统级错误报告缓存'; Group = 'Deep'; Kind = 'Dir'
            Paths = @(
                '%ProgramData%\Microsoft\Windows\WER\ReportQueue',
                '%ProgramData%\Microsoft\Windows\WER\ReportArchive',
                '%ProgramData%\Microsoft\Windows\WER\Temp'
            )
            Filter = '*'; Admin = $true; Note = ''
        }) | Out-Null

    $list.Add(@{
            Id = 'AllUsersTemp'; Name = '所有用户的临时文件'; Group = 'Deep'; Kind = 'Dir'
            Paths = @('%SystemDrive%\Users\*\AppData\Local\Temp'); Filter = '*'; Admin = $true
            Note = '当前用户的 %TEMP% 已在安全项中单独清理'
        }) | Out-Null

    $list.Add(@{
            Id = 'FontCache'; Name = '字体缓存'; Group = 'Deep'; Kind = 'Dir'
            Paths = @('%SystemRoot%\ServiceProfiles\LocalService\AppData\Local\FontCache')
            Filter = '*'; Admin = $true; Service = @('FontCache')
            Note = '清理前会临时停止 FontCache 服务'
        }) | Out-Null

    $list.Add(@{
            Id = 'RdpCache'; Name = '远程桌面缓存'; Group = 'Deep'; Kind = 'Dir'
            Paths = @('%LOCALAPPDATA%\Microsoft\Terminal Server Client\Cache'); Filter = '*'
            Admin = $false; Note = ''
        }) | Out-Null

    $list.Add(@{
            Id = 'ChromeCache'; Name = 'Chrome 浏览器缓存'; Group = 'Deep'; Kind = 'Dir'
            Paths = @(
                '%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache\Cache_Data',
                '%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache',
                '%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache',
                '%LOCALAPPDATA%\Google\Chrome\User Data\*\Service Worker\CacheStorage',
                '%LOCALAPPDATA%\Google\Chrome\User Data\*\DawnGraphiteCache',
                '%LOCALAPPDATA%\Google\Chrome\User Data\*\DawnWebGPUCache'
            )
            Filter = '*'; Admin = $false
            Note = '建议先完全退出 Chrome，否则被占用的文件会跳过'
        }) | Out-Null

    $list.Add(@{
            Id = 'EdgeCache'; Name = 'Edge 浏览器缓存'; Group = 'Deep'; Kind = 'Dir'
            Paths = @(
                '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache\Cache_Data',
                '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache',
                '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache',
                '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Service Worker\CacheStorage',
                '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\DawnGraphiteCache',
                '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\DawnWebGPUCache'
            )
            Filter = '*'; Admin = $false
            Note = '建议先完全退出 Edge'
        }) | Out-Null

    $list.Add(@{
            Id = 'FirefoxCache'; Name = 'Firefox 浏览器缓存'; Group = 'Deep'; Kind = 'Dir'
            Paths = @(
                '%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2',
                '%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\startupCache'
            )
            Filter = '*'; Admin = $false
            Note = '建议先完全退出 Firefox'
        }) | Out-Null

    # ---------------- 额外项 ----------------
    $list.Add(@{
            Id = 'RecycleBin'; Name = '回收站'; Group = 'Extra'; Kind = 'Exec'
            Paths = @(); Filter = '*'; Admin = $false
            Note = '清空后无法通过回收站恢复，请先确认没有需要找回的文件'
            Action = {
                param($Target, $WhatIf)
                if ($WhatIf) { return '预览：将清空回收站' }
                if (-not (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue)) {
                    return '当前系统不支持 Clear-RecycleBin，已跳过'
                }
                try {
                    Clear-RecycleBin -Force -ErrorAction Stop
                    return '回收站已清空'
                }
                catch { return ('清空失败：' + $_.Exception.Message) }
            }
        }) | Out-Null

    $list.Add(@{
            Id = 'MemoryDump'; Name = '内存转储 / 小型转储'; Group = 'Extra'; Kind = 'Items'
            Paths = @('%SystemRoot%\MEMORY.DMP', '%SystemRoot%\Minidump\*')
            Filter = '*'; Admin = $true
            Note = '蓝屏排查用的转储文件，一般可以删除'
        }) | Out-Null

    $list.Add(@{
            Id = 'WindowsOld'; Name = 'Windows.old 旧系统文件'; Group = 'Extra'; Kind = 'Items'
            Paths = @('%SystemDrive%\Windows.old'); Filter = '*'; Admin = $true
            Special = 'WindowsOld'
            Note = '通常可释放数 GB；删除后无法回退旧版本，且报告体积可能大于实际释放量（含硬链接）'
        }) | Out-Null

    $list.Add(@{
            Id = 'UpgradeLeftover'; Name = '系统升级残留 ($Windows.~BT / ~WS)'; Group = 'Extra'; Kind = 'Items'
            Paths = @('%SystemDrive%\$Windows.~BT', '%SystemDrive%\$Windows.~WS')
            Filter = '*'; Admin = $true; Special = 'WindowsOld'
            Note = ''
        }) | Out-Null

    $list.Add(@{
            Id = 'DevCache'; Name = '开发工具缓存 (pip / npm / NuGet / Yarn)'; Group = 'Extra'; Kind = 'Dir'
            Paths = @(
                '%LOCALAPPDATA%\pip\Cache',
                '%APPDATA%\npm-cache',
                '%LOCALAPPDATA%\Yarn\Cache',
                '%LOCALAPPDATA%\NuGet\v3-cache',
                '%LOCALAPPDATA%\NuGet\plugins-cache',
                '%LOCALAPPDATA%\Microsoft\TypeScript'
            )
            Filter = '*'; Admin = $false
            Note = '下次安装依赖需要重新下载，按需选择'
        }) | Out-Null

    return $list
}

# =====================================================================
# 执行单个清理项
# =====================================================================

function Invoke-CleanTarget {
    param(
        $Target,
        [bool]$WhatIf
    )

    $res = [pscustomobject]@{
        Id      = $Target.Id
        Name    = $Target.Name
        Group   = $Target.Group
        Freed   = [long]0
        Deleted = 0
        Skipped = 0
        Failed  = 0
        Status  = ''
        Notes   = New-Object 'System.Collections.Generic.List[string]'
    }

    if ($Target.Admin -and -not $script:IsAdmin) {
        $res.Status = '跳过（需要管理员权限）'
        return $res
    }

    $services = @()
    if ($Target['Service']) { $services = @($Target['Service']) }
    $stopped = New-Object 'System.Collections.Generic.List[string]'

    if ($services.Count -gt 0 -and -not $WhatIf) {
        foreach ($svc in $services) {
            try {
                $s = Get-Service -Name $svc -ErrorAction Stop
                if ($s.Status -eq 'Running') {
                    Stop-Service -Name $svc -Force -ErrorAction Stop
                    $stopped.Add($svc) | Out-Null
                }
            }
            catch { }
        }
    }

    try {
        if ($Target.Kind -eq 'Exec') {
            $msg = & $Target.Action $Target $WhatIf
            $res.Status = [string]$msg
            return $res
        }

        $targets = New-Object 'System.Collections.Generic.List[string]'
        foreach ($raw in @($Target.Paths)) {
            $expanded = [System.Environment]::ExpandEnvironmentVariables($raw)
            if ($Target.Kind -eq 'Dir') {
                foreach ($d in (Resolve-TargetDirectories -Pattern $expanded)) {
                    if (-not $script:SeenPaths.Contains($d)) {
                        $script:SeenPaths.Add($d) | Out-Null
                        $targets.Add($d) | Out-Null
                    }
                }
            }
            else {
                foreach ($it in (Resolve-TargetItems -Pattern $expanded)) {
                    if (-not $script:SeenPaths.Contains($it)) {
                        $script:SeenPaths.Add($it) | Out-Null
                        $targets.Add($it) | Out-Null
                    }
                }
            }
        }

        if ($targets.Count -eq 0) {
            $res.Status = '未找到（跳过）'
            return $res
        }

        $cutoff = $null
        if ($OlderThanDays -gt 0) { $cutoff = (Get-Date).AddDays(-1 * $OlderThanDays) }

        foreach ($path in $targets) {
            if ($Target.Kind -eq 'Dir') {
                $r = Clear-DirectoryContent -Path $path -Filter $Target.Filter -Days $OlderThanDays -WhatIf $WhatIf
                $res.Freed = $res.Freed + $r.Freed
                $res.Deleted = $res.Deleted + $r.Deleted
                $res.Skipped = $res.Skipped + $r.Skipped
                $res.Failed = $res.Failed + $r.Failed
            }
            else {
                if ($cutoff -ne $null) {
                    try {
                        $lm = (Get-Item -LiteralPath $path -Force -ErrorAction Stop).LastWriteTime
                        if ($lm -gt $cutoff) { $res.Skipped++; continue }
                    }
                    catch { }
                }

                $size = Get-PathSize -Path $path
                if ($WhatIf) {
                    $res.Freed = $res.Freed + $size
                    $res.Deleted++
                    continue
                }
                if ($Target['Special'] -eq 'WindowsOld') {
                    $res.Notes.Add('正在获取目录所有权：' + $path) | Out-Null
                    Grant-PathOwnership -Path $path | Out-Null
                }
                if (Remove-PathForce -Path $path -Recurse) {
                    $res.Freed = $res.Freed + $size
                    $res.Deleted++
                }
                else {
                    $res.Failed++
                }
            }
        }
    }
    catch {
        $res.Status = '出错：' + $_.Exception.Message
    }
    finally {
        foreach ($svc in $stopped) {
            try { Start-Service -Name $svc -ErrorAction SilentlyContinue } catch { }
        }
    }

    return $res
}

# =====================================================================
# 清理范围选择
# =====================================================================

function Select-CleanTargets {
    param(
        [string[]]$Groups,
        [string[]]$ExplicitExtra = @(),
        [switch]$KeepAllExtras
    )

    $all = Get-CleanTargetList

    # 额外项只有在“被显式点名”时才自动加入；KeepAllExtras 表示按传入的分组原样执行
    $wanted = @($Groups)
    if (-not $KeepAllExtras -and $ExplicitExtra.Count -gt 0) {
        if ($wanted -notcontains 'Extra') { $wanted += 'Extra' }
    }

    $selected = @($all | Where-Object { $wanted -contains $_.Group })

    if ($KeepAllExtras) { return $selected }

    if ($ExplicitExtra.Count -gt 0) {
        # 只跑被显式指定的额外项
        return @($selected | Where-Object { $_.Group -ne 'Extra' -or $ExplicitExtra -contains $_.Id })
    }

    return $selected
}

function Resolve-Selection {
    param(
        [switch]$All,
        [switch]$Deep,
        [switch]$FromMenu,
        [string[]]$MenuGroups = @(),
        [switch]$IncludeRecycleBin,
        [switch]$IncludeWindowsOld,
        [switch]$IncludeMemoryDump,
        [switch]$IncludeDevCache
    )

    # 菜单模式：分组由用户选择，额外项一并在内
    if ($FromMenu) {
        return Select-CleanTargets -Groups $MenuGroups -KeepAllExtras
    }

    if ($All) { $groups = @('Safe', 'Deep', 'Extra') }
    elseif ($Deep) { $groups = @('Safe', 'Deep') }
    else { $groups = @('Safe') }

    $explicit = @()
    if ($IncludeRecycleBin) { $explicit += 'RecycleBin' }
    if ($IncludeWindowsOld) { $explicit += 'WindowsOld'; $explicit += 'UpgradeLeftover' }
    if ($IncludeMemoryDump) { $explicit += 'MemoryDump' }
    if ($IncludeDevCache) { $explicit += 'DevCache' }

    return Select-CleanTargets -Groups $groups -ExplicitExtra $explicit -KeepAllExtras:([bool]$All)
}

# =====================================================================
# 界面
# =====================================================================

function Show-Header {
    $free = Get-SystemDriveFree
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '            Windows 磁盘清理工具  DiskTempCleaner' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    if ($free -ge 0) {
        Write-Host ('  {0} 盘可用空间：{1}' -f $env:SystemDrive, (Format-Size $free)) -ForegroundColor White
    }
    if ($script:IsAdmin) {
        Write-Host '  运行权限：管理员' -ForegroundColor Green
    }
    else {
        Write-Host '  运行权限：普通用户（系统级项目会被跳过）' -ForegroundColor Yellow
    }
    Write-Host ''
}

function Show-TargetList {
    param($Targets)
    foreach ($t in $Targets) {
        $flag = '  '
        if ($t.Admin -and -not $script:IsAdmin) { $flag = '! ' }
        $tag = ''
        if ($t.Group -eq 'Deep') { $tag = '[深度]' }
        if ($t.Group -eq 'Extra') { $tag = '[额外]' }
        Write-Host ('  {0}{1}  {2}' -f $flag, $t.Name, $tag) -ForegroundColor Gray
    }
}

function Read-MenuChoice {
    param([string]$Prompt, [string]$Default)
    $ans = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return $ans.Trim()
}

function Show-InteractiveMenu {
    while ($true) {
        Show-Header
        Write-Host '  [1] 快速清理      临时文件、错误报告、着色器缓存（安全）' -ForegroundColor White
        Write-Host '  [2] 深度清理      快速清理 + 更新缓存、日志、缩略图、浏览器缓存' -ForegroundColor White
        Write-Host '  [3] 彻底清理      深度清理 + 回收站、Windows.old、内存转储、开发缓存' -ForegroundColor White
        Write-Host '  [4] 预览模式      只列出可清理内容，不删除任何文件' -ForegroundColor White
        Write-Host '  [5] 自定义        逐组选择要清理的内容' -ForegroundColor White
        Write-Host '  [0] 退出' -ForegroundColor DarkGray
        Write-Host ''
        $choice = Read-MenuChoice '请输入选项' '1'

        switch ($choice) {
            '1' { return @{ Groups = @('Safe'); DryRun = $false; Name = '快速清理' } }
            '2' { return @{ Groups = @('Safe', 'Deep'); DryRun = $false; Name = '深度清理' } }
            '3' { return @{ Groups = @('Safe', 'Deep', 'Extra'); DryRun = $false; Name = '彻底清理' } }
            '4' { return @{ Groups = @('Safe', 'Deep'); DryRun = $true; Name = '预览模式' } }
            '5' {
                Write-Host ''
                Write-Host '  逐组选择（Y = 清理，直接回车 = 不清理）' -ForegroundColor Cyan
                $groups = @()
                $a1 = Read-MenuChoice '  安全项（临时文件等）        [Y/n]' 'Y'
                if ($a1 -match '^[Yy]') { $groups += 'Safe' }
                $a2 = Read-MenuChoice '  深度项（更新缓存、日志等）  [y/N]' 'N'
                if ($a2 -match '^[Yy]') { $groups += 'Deep' }
                $a3 = Read-MenuChoice '  额外项（回收站、Windows.old，风险高）[y/N]' 'N'
                if ($a3 -match '^[Yy]') { $groups += 'Extra' }
                if ($groups.Count -eq 0) {
                    Write-Host '  没有选择任何项目。' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    continue
                }
                $dry = Read-MenuChoice '  仅预览不删除？              [y/N]' 'N'
                return @{ Groups = $groups; DryRun = ($dry -match '^[Yy]'); Name = '自定义清理' }
            }
            '0' { return $null }
            default { continue }
        }
    }
}

# =====================================================================
# 主流程
# =====================================================================

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-Host '本工具仅支持 Windows 系统。' -ForegroundColor Red
    exit 1
}

$script:IsAdmin = Test-Admin
$interactive = ($PSBoundParameters.Count -eq 0)

if ($interactive -and -not $script:IsAdmin) {
    Show-Header
    Write-Host '  提示：以管理员身份运行可以额外清理系统临时文件、Windows 更新缓存等项目。' -ForegroundColor Yellow
    $elev = Read-MenuChoice '  是否以管理员身份重新运行？[Y/n]' 'Y'
    if ($elev -match '^[Yy]') {
        try {
            $exe = (Get-Process -Id $PID).Path
            Start-Process -FilePath $exe -Verb RunAs -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath
            ) | Out-Null
            # 42 = 已在新的管理员窗口中继续运行
            exit 42
        }
        catch {
            Write-Host '  提权失败，继续以普通权限运行。' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

# ---- 选择清理范围 ----
$dryRunMode = [bool]$DryRun
$selectionName = ''
$menuGroups = @()

if ($interactive) {
    $sel = Show-InteractiveMenu
    if ($null -eq $sel) { exit 0 }
    $menuGroups = $sel.Groups
    $dryRunMode = [bool]$sel.DryRun
    $selectionName = $sel.Name
}
else {
    $selectionName = '命令行清理'
}

$selArgs = @{
    All               = [bool]$All
    Deep              = [bool]$Deep
    FromMenu          = [bool]$interactive
    MenuGroups        = $menuGroups
    IncludeRecycleBin = [bool]$IncludeRecycleBin
    IncludeWindowsOld = [bool]$IncludeWindowsOld
    IncludeMemoryDump = [bool]$IncludeMemoryDump
    IncludeDevCache   = [bool]$IncludeDevCache
}
$targets = @(Resolve-Selection @selArgs)

if ($targets.Count -eq 0) {
    Write-Host '没有可执行的清理项。' -ForegroundColor Yellow
    exit 0
}

Show-Header
Write-Log ('  清理模式：{0}' -f $selectionName) 'Cyan'
if ($dryRunMode) { Write-Log '  预览模式：不会删除任何文件' 'Yellow' }
if ($OlderThanDays -gt 0) { Write-Log ('  只处理 {0} 天以前的文件' -f $OlderThanDays) 'Yellow' }
Write-Log ''
Write-Log '  本次包含以下项目：' 'White'
Show-TargetList -Targets $targets
Write-Log ''
Write-Log '  ! = 需要管理员权限' 'DarkGray'
Write-Log ''

if (-not $Yes -and -not $dryRunMode) {
    $confirm = Read-MenuChoice '  确认开始清理？[Y/N]' 'N'
    if ($confirm -notmatch '^[Yy]') {
        Write-Host '  已取消。' -ForegroundColor Yellow
        exit 0
    }
    Write-Log ''
}

$freeBefore = Get-SystemDriveFree
$startTime = Get-Date
$totalFreed = [long]0
$totalDeleted = 0
$totalSkipped = 0
$totalFailed = 0
$results = New-Object System.Collections.ArrayList
$index = 0

foreach ($t in $targets) {
    $index++
    Write-Log ('  [{0}/{1}] {2} ...' -f $index, $targets.Count, $t.Name) 'Gray' -NoNewline
    $r = Invoke-CleanTarget -Target $t -WhatIf $dryRunMode
    $results.Add($r) | Out-Null
    $totalFreed = $totalFreed + $r.Freed
    $totalDeleted = $totalDeleted + $r.Deleted
    $totalSkipped = $totalSkipped + $r.Skipped
    $totalFailed = $totalFailed + $r.Failed

    if ($r.Status -ne '') {
        Write-Log (' ' + $r.Status) 'DarkYellow'
    }
    elseif ($r.Freed -eq 0 -and $r.Deleted -eq 0 -and $r.Failed -eq 0) {
        if ($r.Skipped -gt 0) { Write-Log (' 无需清理（{0} 个文件在保留期内）' -f $r.Skipped) 'DarkGray' }
        else { Write-Log ' 无需清理' 'DarkGray' }
    }
    else {
        Write-Log (' 释放 {0}（删除 {1}，跳过 {2}，失败 {3}）' -f (Format-Size $r.Freed), $r.Deleted, $r.Skipped, $r.Failed) 'Green'
    }
    foreach ($n in $r.Notes) { Write-Log ('        ' + $n) 'DarkGray' }
}

$freeAfter = Get-SystemDriveFree
$elapsed = (Get-Date) - $startTime

Write-Log ''
Write-Log '------------------------------------------------------------' 'Cyan'
if ($dryRunMode) {
    Write-Log ('  预览结果：可清理约 {0}' -f (Format-Size $totalFreed)) 'Yellow'
}
else {
    Write-Log ('  已释放空间：{0}' -f (Format-Size $totalFreed)) 'Green'
}
Write-Log ('  文件统计：删除 {0}，跳过 {1}，失败 {2}' -f $totalDeleted, $totalSkipped, $totalFailed) 'White'
Write-Log ('  耗时：{0:N1} 秒' -f $elapsed.TotalSeconds) 'DarkGray'
if ($freeBefore -ge 0 -and $freeAfter -ge 0) {
    Write-Log ('  {0} 盘可用空间：{1} -> {2}' -f $env:SystemDrive, (Format-Size $freeBefore), (Format-Size $freeAfter)) 'White'
}
Write-Log ''

# 缩略图缓存清理后可选重启资源管理器
$thumb = @($results | Where-Object { $_.Id -eq 'ThumbnailCache' -and $_.Deleted -gt 0 })
if ($thumb.Count -gt 0 -and -not $dryRunMode) {
    $doRestart = [bool]$RestartExplorer
    if (-not $doRestart) {
        $ans = Read-MenuChoice '  是否重启资源管理器以立即刷新缩略图缓存？[Y/n]' 'Y'
        $doRestart = ($ans -match '^[Yy]')
    }
    if ($doRestart) {
        try {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe')
            }
            Write-Host '  资源管理器已重启。' -ForegroundColor Green
        }
        catch { Write-Host '  重启资源管理器失败，可稍后手动重启或注销。' -ForegroundColor Yellow }
    }
}

# ---- 写日志 ----
if (-not $NoLog) {
    try {
        if ([string]::IsNullOrWhiteSpace($LogDir)) {
            $LogDir = Join-Path $env:LOCALAPPDATA 'DiskTempCleaner\logs'
        }
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $logFile = Join-Path $LogDir ('clean_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

        $body = New-Object 'System.Collections.Generic.List[string]'
        $body.Add('Windows 磁盘清理工具 日志') | Out-Null
        $body.Add(('时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))) | Out-Null
        $body.Add(('模式：{0}{1}' -f $selectionName, $(if ($dryRunMode) { '（预览）' } else { '' }))) | Out-Null
        $body.Add(('管理员权限：{0}' -f $script:IsAdmin)) | Out-Null
        $body.Add(('合计释放：{0}' -f (Format-Size $totalFreed))) | Out-Null
        $body.Add(('删除 {0} / 跳过 {1} / 失败 {2}' -f $totalDeleted, $totalSkipped, $totalFailed)) | Out-Null
        $body.Add(('=' * 60)) | Out-Null
        foreach ($line in $script:LogLines) { $body.Add($line) | Out-Null }
        $body.Add('=' * 60) | Out-Null
        $body.Add('分项明细：') | Out-Null
        foreach ($r in $results) {
            $body.Add(('[{0}] {1}' -f $r.Group, $r.Name)) | Out-Null
            if ($r.Status -ne '') {
                $body.Add(('    结果：{0}' -f $r.Status)) | Out-Null
            }
            else {
                $body.Add(('    释放 {0} / 删除 {1} / 跳过 {2} / 失败 {3}' -f (Format-Size $r.Freed), $r.Deleted, $r.Skipped, $r.Failed)) | Out-Null
            }
            foreach ($n in $r.Notes) { $body.Add(('    ' + $n)) | Out-Null }
        }

        Set-Content -LiteralPath $logFile -Value $body.ToArray() -Encoding UTF8 -ErrorAction Stop
        Write-Host ('  日志已保存：{0}' -f $logFile) -ForegroundColor DarkGray
    }
    catch {
        Write-Host ('  日志写入失败：{0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

Write-Host ''
if ($interactive) {
    Read-Host '  按回车键退出' | Out-Null
}
exit 0
