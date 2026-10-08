#Requires -Version 5.1
<#
    CleanTemp.ps1 零依赖测试套件
    ------------------------------------------------------------------
    - 不修改被测脚本：用 AST 取出其中的函数定义，单独加载后再测试
    - 所有删除都发生在沙箱目录（默认 <仓库根>\_lab）里，绝不碰系统目录
    - 只依赖 Windows 自带的 PowerShell 5.1，不需要 Pester、不需要联网
    - 退出码：0 = 全部通过，1 = 有失败（可直接用于 CI 判定）

    运行：
        powershell -ExecutionPolicy Bypass -File tests\CleanTemp.Tests.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [string]$LabPath
)

$ErrorActionPreference = 'Continue'
try {
    if ([Console]::IsOutputRedirected) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
}
catch { }

# 被测脚本可能在 tests\ 的上一级（仓库根），也可能和本文件同处一个目录
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $candidates = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'CleanTemp.ps1'),
        (Join-Path $PSScriptRoot 'CleanTemp.ps1')
    )
    $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ })
    if ($found.Count -gt 0) { $ScriptPath = $found[0] } else { $ScriptPath = $candidates[0] }
}
# 沙箱目录始终建在仓库根下，绝不使用系统临时目录
if ([string]::IsNullOrWhiteSpace($LabPath)) {
    $root = Split-Path -Parent $PSScriptRoot
    if (-not (Test-Path -LiteralPath (Join-Path $root 'CleanTemp.ps1'))) { $root = $PSScriptRoot }
    $LabPath = Join-Path $root '_lab'
}

# =====================================================================
# 断言框架
# =====================================================================

$script:PassCount = 0
$script:FailCount = 0
$script:Results = New-Object System.Collections.ArrayList

function Check {
    param([string]$Name, $Actual, $Expected)
    $ok = ("$Actual" -eq "$Expected")
    if ($ok) { $script:PassCount++ } else { $script:FailCount++ }
    $script:Results.Add([pscustomobject]@{
            Name = $Name; Ok = $ok; Actual = "$Actual"; Expected = "$Expected"
        }) | Out-Null
    if ($ok) {
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    }
    else {
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("        got  [{0}]" -f $Actual) -ForegroundColor Red
        Write-Host ("        want [{0}]" -f $Expected) -ForegroundColor Red
    }
}

function Cnt {
    param($x)
    # 注意：空管道在 PowerShell 5.1 里绑定成 $null，而 @($null).Count 是 1（PS7 是 0），
    # 所以必须显式处理，否则“没有匹配项”会被误判成“有 1 项”。
    if ($null -eq $x) { return 0 }
    return @($x).Count
}

function Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ("[{0}]" -f $Title) -ForegroundColor Cyan
}

# =====================================================================
# 载入被测脚本的函数（不执行其主体）
# =====================================================================

Write-Host ''
Write-Host '=== CleanTemp 测试套件 ===' -ForegroundColor White
Write-Host ("PowerShell  : {0}" -f $PSVersionTable.PSVersion)
Write-Host ("被测脚本    : {0}" -f $ScriptPath)
Write-Host ("沙箱目录    : {0}" -f $LabPath)

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host ("找不到被测脚本：{0}" -f $ScriptPath) -ForegroundColor Red
    exit 1
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)

Section '0 语法解析 + 函数提取'

if ($parseErrors.Count -gt 0) {
    foreach ($err in $parseErrors) {
        Write-Host ("  line {0}: {1}" -f $err.Extent.StartLineNumber, $err.Message) -ForegroundColor Red
    }
}
Check 'parse.noErrors' (Cnt $parseErrors) 0
if ($parseErrors.Count -gt 0) {
    Write-Host ''
    Write-Host '语法未通过，后续测试无意义，中止。' -ForegroundColor Red
    exit 1
}

$funcAsts = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
Check 'parse.hasFunctions' ([bool]($funcAsts.Count -ge 15)) $true
Write-Host ("        提取到 {0} 个函数定义" -f $funcAsts.Count) -ForegroundColor Gray

# 准备沙箱目录
if (Test-Path -LiteralPath $LabPath) { Remove-Item -LiteralPath $LabPath -Recurse -Force }
New-Item -ItemType Directory -Path $LabPath -Force | Out-Null

# 把函数定义片段写成临时文件再 dot-source（等价于直接加载，行为最稳）
$coreFile = Join-Path $LabPath '_core.ps1'
$coreText = (($funcAsts | ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n")
Set-Content -LiteralPath $coreFile -Value $coreText -Encoding UTF8
. $coreFile

# 补上脚本顶部的脚本级变量（被测脚本主体没被执行，这里手动初始化）
$script:IsAdmin = $false
$script:LogLines = New-Object 'System.Collections.Generic.List[string]'
$script:PendingLine = ''
$script:SeenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$OlderThanDays = 0

function New-LabFile {
    param([string]$Path, [int]$Bytes, [int]$AgeDays = 0)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
    if ($AgeDays -gt 0) { (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-1 * $AgeDays) }
}

# =====================================================================
# 删除引擎
# =====================================================================

Section '1 目录清空 / 空目录裁剪'

$d1 = Join-Path $LabPath 't1'
New-LabFile (Join-Path $d1 'a.tmp') 1000
New-LabFile (Join-Path $d1 'sub\b.tmp') 2000
New-LabFile (Join-Path $d1 'sub\deep\c.tmp') 3000
$t = @{ Id = 'T1'; Name = 'dir-all'; Group = 'Safe'; Kind = 'Dir'; Paths = @($d1); Filter = '*'; Admin = $false }
$r = Invoke-CleanTarget -Target $t -WhatIf $false
Check 'T1.freed' $r.Freed 6000
Check 'T1.deleted' $r.Deleted 3
Check 'T1.failed' $r.Failed 0
Check 'T1.rootKept' (Test-Path -LiteralPath $d1) $true
Check 'T1.emptyPruned' (Test-Path -LiteralPath (Join-Path $d1 'sub')) $false

Section '2 扩展名白名单 (Filter)'

$d2 = Join-Path $LabPath 't2'
New-LabFile (Join-Path $d2 'x.pf') 500
New-LabFile (Join-Path $d2 'keep.txt') 700
$t = @{ Id = 'T2'; Name = 'dir-filter'; Group = 'Safe'; Kind = 'Dir'; Paths = @($d2); Filter = '*.pf'; Admin = $false }
$r = Invoke-CleanTarget -Target $t -WhatIf $false
Check 'T2.deleted' $r.Deleted 1
Check 'T2.freed' $r.Freed 500
Check 'T2.txtKept' (Test-Path -LiteralPath (Join-Path $d2 'keep.txt')) $true
Check 'T2.pfGone' (Test-Path -LiteralPath (Join-Path $d2 'x.pf')) $false

Section '3 保留期 OlderThanDays'

$d3 = Join-Path $LabPath 't3'
New-LabFile (Join-Path $d3 'old.tmp') 111 30
New-LabFile (Join-Path $d3 'new.tmp') 222 0
$OlderThanDays = 7
$t = @{ Id = 'T3'; Name = 'age'; Group = 'Safe'; Kind = 'Dir'; Paths = @($d3); Filter = '*'; Admin = $false }
$r = Invoke-CleanTarget -Target $t -WhatIf $false
Check 'T3.deleted' $r.Deleted 1
Check 'T3.skipped' $r.Skipped 1
Check 'T3.newKept' (Test-Path -LiteralPath (Join-Path $d3 'new.tmp')) $true
$OlderThanDays = 0

Section '4 整项删除 (Items / 通配 / 目录)'

$d4 = Join-Path $LabPath 't4'
New-LabFile (Join-Path $d4 'one.dmp') 4000
New-LabFile (Join-Path $d4 'two.dmp') 4000
$d4dir = Join-Path $d4 'subdir'
New-LabFile (Join-Path $d4dir 'x.bin') 1000
$t = @{ Id = 'T4'; Name = 'items'; Group = 'Extra'; Kind = 'Items'; Paths = @((Join-Path $d4 '*.dmp'), $d4dir); Filter = '*'; Admin = $false }
$r = Invoke-CleanTarget -Target $t -WhatIf $false
Check 'T4.deleted' $r.Deleted 3
Check 'T4.freed' $r.Freed 9000
Check 'T4.dirGone' (Test-Path -LiteralPath $d4dir) $false

Section '5 预览模式不落盘'

$d5 = Join-Path $LabPath 't5'
New-LabFile (Join-Path $d5 'a.bin') 1234
$t = @{ Id = 'T5'; Name = 'dry'; Group = 'Safe'; Kind = 'Dir'; Paths = @($d5); Filter = '*'; Admin = $false }
$r = Invoke-CleanTarget -Target $t -WhatIf $true
Check 'T5.dryFreed' $r.Freed 1234
Check 'T5.fileKept' (Test-Path -LiteralPath (Join-Path $d5 'a.bin')) $true

Section '6 路径去重'

$d6 = Join-Path $LabPath 't6'
New-LabFile (Join-Path $d6 'a.bin') 10
$t = @{ Id = 'T6a'; Name = 'dup1'; Group = 'Safe'; Kind = 'Dir'; Paths = @($d6); Filter = '*'; Admin = $false }
$null = Invoke-CleanTarget -Target $t -WhatIf $false
New-LabFile (Join-Path $d6 'b.bin') 20
$t2 = @{ Id = 'T6b'; Name = 'dup2'; Group = 'Safe'; Kind = 'Dir'; Paths = @($d6); Filter = '*'; Admin = $false }
$r = Invoke-CleanTarget -Target $t2 -WhatIf $false
Check 'T6.dedupeStatus' $r.Status '未找到（跳过）'

Section '7 权限不足时跳过'

$t = @{ Id = 'T7'; Name = 'admin'; Group = 'Deep'; Kind = 'Dir'; Paths = @($LabPath); Filter = '*'; Admin = $true }
$r = Invoke-CleanTarget -Target $t -WhatIf $false
Check 'T7.status' $r.Status '跳过（需要管理员权限）'

Section '8 自定义动作 (Exec)'

$script:hit = 0
$t = @{
    Id = 'T8'; Name = 'exec'; Group = 'Extra'; Kind = 'Exec'; Paths = @(); Filter = '*'; Admin = $false
    Action = { param($Target, $WhatIf) $script:hit++; return "动作已执行 whatif=$WhatIf" }
}
$r = Invoke-CleanTarget -Target $t -WhatIf $true
Check 'T8.status' $r.Status '动作已执行 whatif=True'
Check 'T8.hit' $script:hit 1

Section '9 路径不存在'

$t = @{ Id = 'T9'; Name = 'missing'; Group = 'Safe'; Kind = 'Dir'; Paths = @((Join-Path $LabPath 'nope')); Filter = '*'; Admin = $false }
$r = Invoke-CleanTarget -Target $t -WhatIf $false
Check 'T9.status' $r.Status '未找到（跳过）'

Section '10 清理项目清单完整性'

$list = @(Get-CleanTargetList)
Check 'list.count' (Cnt $list) 27
Check 'list.uniqueIds' (Cnt ($list | ForEach-Object { $_.Id } | Select-Object -Unique)) (Cnt $list)
Check 'list.keysComplete' (Cnt ($list | Where-Object {
            -not $_.ContainsKey('Name') -or -not $_.ContainsKey('Kind') -or
            -not $_.ContainsKey('Admin') -or -not $_.ContainsKey('Paths') -or
            -not $_.ContainsKey('Filter') -or -not $_.ContainsKey('Group')
        })) 0
Check 'list.kindsValid' (Cnt ($list | Where-Object { $_.Kind -notin @('Dir', 'Items', 'Exec') })) 0
Check 'list.groupsValid' (Cnt ($list | Where-Object { $_.Group -notin @('Safe', 'Deep', 'Extra') })) 0
$cSafe = Cnt ($list | Where-Object { $_.Group -eq 'Safe' })
$cDeep = Cnt ($list | Where-Object { $_.Group -eq 'Deep' })
$cExtra = Cnt ($list | Where-Object { $_.Group -eq 'Extra' })
Write-Host ("        分组: Safe={0}, Deep={1}, Extra={2}" -f $cSafe, $cDeep, $cExtra) -ForegroundColor Gray

Section '11 清理范围选择'

$s = @(Select-CleanTargets -Groups @('Safe'))
Check 'S1.count' (Cnt $s) 7
Check 'S1.safeOnly' (Cnt ($s | Where-Object { $_.Group -ne 'Safe' })) 0

$s = @(Select-CleanTargets -Groups @('Safe', 'Deep'))
Check 'S2.count' (Cnt $s) 22
Check 'S2.noExtra' (Cnt ($s | Where-Object { $_.Group -eq 'Extra' })) 0

$s = @(Select-CleanTargets -Groups @('Safe', 'Deep') -ExplicitExtra @('RecycleBin'))
Check 'S3.count' (Cnt $s) 23
Check 'S3.extraCount' (Cnt ($s | Where-Object { $_.Group -eq 'Extra' })) 1
Check 'S3.hasRecycle' (Cnt ($s | Where-Object { $_.Id -eq 'RecycleBin' })) 1

$s = @(Select-CleanTargets -Groups @('Safe', 'Deep') -ExplicitExtra @('WindowsOld'))
Check 'S4.onlyWindowsOld' (Cnt ($s | Where-Object { $_.Group -eq 'Extra' })) 1
Check 'S4.id' ($s | Where-Object { $_.Group -eq 'Extra' }).Id 'WindowsOld'

Check 'S5.keepAll' (Cnt @(Select-CleanTargets -Groups @('Safe', 'Deep', 'Extra') -ExplicitExtra @('DevCache') -KeepAllExtras)) 27
Check 'S6.menuSafe' (Cnt @(Select-CleanTargets -Groups @('Safe') -KeepAllExtras)) 7
Check 'S7.menuAll' (Cnt @(Select-CleanTargets -Groups @('Safe', 'Deep', 'Extra') -KeepAllExtras)) 27

Section '12 命令行参数 -> 清理项（真实入口函数）'

function ExtraNames {
    param($x)
    return (@($x | Where-Object { $_.Group -eq 'Extra' } | ForEach-Object { $_.Id } | Sort-Object) -join ',')
}

Check 'R.default' (Cnt @(Resolve-Selection)) 7
Check 'R.deep' (Cnt @(Resolve-Selection -Deep)) 22
Check 'R.deepNoExtra' (ExtraNames @(Resolve-Selection -Deep)) ''
Check 'R.all' (Cnt @(Resolve-Selection -All)) 27
Check 'R.deepRb' (Cnt @(Resolve-Selection -Deep -IncludeRecycleBin)) 23
Check 'R.deepRbExtra' (ExtraNames @(Resolve-Selection -Deep -IncludeRecycleBin)) 'RecycleBin'
Check 'R.deepOldExtra' (ExtraNames @(Resolve-Selection -Deep -IncludeWindowsOld)) 'UpgradeLeftover,WindowsOld'
Check 'R.deepTwoExtra' (ExtraNames @(Resolve-Selection -Deep -IncludeMemoryDump -IncludeDevCache)) 'DevCache,MemoryDump'
Check 'R.allRb' (Cnt @(Resolve-Selection -All -IncludeRecycleBin)) 27
Check 'R.menuAll' (Cnt @(Resolve-Selection -FromMenu -MenuGroups @('Safe', 'Deep', 'Extra'))) 27
Check 'R.menuSafe' (Cnt @(Resolve-Selection -FromMenu -MenuGroups @('Safe'))) 7
Check 'R.menuDeep' (Cnt @(Resolve-Selection -FromMenu -MenuGroups @('Safe', 'Deep'))) 22

Section '13 当前用户目录排除（8.3 短名场景）'

# %TEMP% 可能是 8.3 短名（C:\Users\RUNNER~1\...），而通配符 C:\Users\*\... 解析出长名，
# 两者字符串不相等，所以"所有用户的临时文件"必须按 profile 前缀排除当前用户。
$profileRoot = $null
try { $profileRoot = [Environment]::GetFolderPath('UserProfile') } catch { }
if ([string]::IsNullOrEmpty($profileRoot)) { $profileRoot = $env:USERPROFILE }

Check 'U0.profileAvailable' ([bool](-not [string]::IsNullOrEmpty($profileRoot))) $true
Check 'U1.underProfile' (Test-UnderCurrentProfile -Path (Join-Path $profileRoot 'AppData\Local\Temp')) $true
Check 'U2.profileItself' (Test-UnderCurrentProfile -Path $profileRoot) $true
Check 'U3.systemDir' (Test-UnderCurrentProfile -Path 'C:\Windows\Temp') $false
Check 'U4.empty' (Test-UnderCurrentProfile -Path '') $false
Check 'U5.siblingPrefix' (Test-UnderCurrentProfile -Path ($profileRoot + 'X')) $false

Section '14 当前 Windows 环境能力（仅报告，不判定）'

$isWin = ($env:OS -eq 'Windows_NT')
Write-Host ("        Windows          : {0}" -f $isWin) -ForegroundColor Gray
if ($isWin) {
    Write-Host ("        OSVersion        : {0}" -f [Environment]::OSVersion.VersionString) -ForegroundColor Gray
    $isAdmin = $false
    try {
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal(
                [Security.Principal.WindowsIdentity]::GetCurrent()
            )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { }
    Write-Host ("        管理员权限       : {0}" -f $isAdmin) -ForegroundColor Gray
    foreach ($c in @('Clear-RecycleBin', 'Delete-DeliveryOptimizationCache', 'Get-Service', 'Stop-Service', 'Get-CimInstance')) {
        Write-Host ("        {0,-34}: {1}" -f $c, [bool](Get-Command $c -ErrorAction SilentlyContinue)) -ForegroundColor Gray
    }
    foreach ($p in @('%TEMP%', '%LOCALAPPDATA%\D3DSCache', '%SystemRoot%\SoftwareDistribution\Download', '%SystemRoot%\Prefetch', '%SystemRoot%\Minidump')) {
        $ex = [System.Environment]::ExpandEnvironmentVariables($p)
        Write-Host ("        {0,-50} {1}" -f $p, (Test-Path -LiteralPath $ex)) -ForegroundColor Gray
    }
}

# =====================================================================
# 收尾
# =====================================================================

$total = $script:PassCount + $script:FailCount
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
if ($script:FailCount -eq 0) {
    Write-Host ("  全部通过：{0}/{1}" -f $script:PassCount, $total) -ForegroundColor Green
}
else {
    Write-Host ("  失败 {0} 项 / 共 {1} 项" -f $script:FailCount, $total) -ForegroundColor Red
}
Write-Host '============================================================' -ForegroundColor Cyan

# 沙箱清理
try { Remove-Item -LiteralPath $LabPath -Recurse -Force -ErrorAction SilentlyContinue } catch { }

# GitHub Actions 摘要（在 CI 里会显示在运行页面顶部，便于快速查看）
if ($env:GITHUB_STEP_SUMMARY) {
    try {
        $md = New-Object System.Collections.ArrayList
        $md.Add('## CleanTemp 测试结果') | Out-Null
        $md.Add('') | Out-Null
        $md.Add(('- PowerShell: `{0}`' -f $PSVersionTable.PSVersion)) | Out-Null
        $md.Add(('- 通过/总数: **{0}/{1}**' -f $script:PassCount, $total)) | Out-Null
        $md.Add('') | Out-Null
        if ($script:FailCount -gt 0) {
            $md.Add('| 失败用例 | 实际 | 期望 |') | Out-Null
            $md.Add('| --- | --- | --- |') | Out-Null
            foreach ($item in ($script:Results | Where-Object { -not $_.Ok })) {
                $md.Add(('| {0} | `{1}` | `{2}` |' -f $item.Name, $item.Actual, $item.Expected)) | Out-Null
            }
        }
        else {
            $md.Add('全部用例通过。') | Out-Null
        }
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $md -Encoding UTF8
    }
    catch { }
}

if ($script:FailCount -gt 0) { exit 1 }
exit 0
