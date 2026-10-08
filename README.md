# Windows 磁盘清理工具（DiskTempCleaner）

一个不用安装、不写注册表、不碰个人文件的 Windows 临时文件清理工具。
全部逻辑集中在**一个 PowerShell 脚本**里，随手拷走就能用。

- 只删除**已知的临时文件 / 缓存目录内容**，目录本身保留
- 正在被占用的文件**自动跳过**并计入统计，不会报错中断
- 支持**预览模式**，先看清楚要删什么再动手
- 有**分项统计**：释放了多少、删了多少、跳过多少、失败多少
- 自动写日志，方便事后核对

## 使用方法

### 方式一：双击运行（推荐）

双击 **`一键清理.bat`** → 脚本会询问是否以管理员身份重新运行（选 Y，UAC 点“是”）→ 出现菜单：

```
  [1] 快速清理      临时文件、错误报告、着色器缓存（安全）
  [2] 深度清理      快速清理 + 更新缓存、日志、缩略图、浏览器缓存
  [3] 彻底清理      深度清理 + 回收站、Windows.old、内存转储、开发缓存
  [4] 预览模式      只列出可清理内容，不删除任何文件
  [5] 自定义        逐组选择要清理的内容
  [0] 退出
```

第一次用建议先选 **[4] 预览模式**。

### 方式二：命令行 / 定时任务

在**管理员 PowerShell** 里执行：

```powershell
# 看看到底能清多少，什么都不删
powershell -ExecutionPolicy Bypass -File CleanTemp.ps1 -DryRun -Deep

# 快速清理（安全项），不再询问
powershell -ExecutionPolicy Bypass -File CleanTemp.ps1 -Safe -Yes

# 深度清理
powershell -ExecutionPolicy Bypass -File CleanTemp.ps1 -Deep -Yes

# 彻底清理，含回收站
powershell -ExecutionPolicy Bypass -File CleanTemp.ps1 -All -IncludeRecycleBin -Yes

# 只删 7 天以前的临时文件，更保守
powershell -ExecutionPolicy Bypass -File CleanTemp.ps1 -Deep -OlderThanDays 7 -Yes
```

> 如果提示“禁止运行脚本”，说明执行策略被限制，用上面的 `-ExecutionPolicy Bypass`
> 参数即可（只对本次运行生效，不修改系统设置）。

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `-Safe` | 只清理安全项（不带参数时的默认值） |
| `-Deep` | 安全项 + 深度项 |
| `-All` | 安全项 + 深度项 + 额外项 |
| `-DryRun` | 只预览、不删除任何文件 |
| `-Yes` | 不询问，直接执行（适合脚本/计划任务） |
| `-OlderThanDays N` | 只处理 N 天以前的文件，`0`（默认）表示全部 |
| `-IncludeRecycleBin` | 单独清空回收站 |
| `-IncludeWindowsOld` | 单独删除 `Windows.old`、`$Windows.~BT`、`$Windows.~WS` |
| `-IncludeMemoryDump` | 单独删除 `MEMORY.DMP` 与 `Minidump` |
| `-IncludeDevCache` | 单独清理 pip / npm / NuGet / Yarn 缓存 |
| `-RestartExplorer` | 清理缩略图缓存后自动重启资源管理器 |
| `-NoLog` | 不写日志 |
| `-LogDir <路径>` | 指定日志目录（默认 `%LOCALAPPDATA%\DiskTempCleaner\logs`） |

## 清理项清单

### 安全项（Safe，随时可清）

| 项目 | 位置 |
| --- | --- |
| 用户临时文件 | `%TEMP%`、`%TMP%` |
| 应用崩溃转储 | `%LOCALAPPDATA%\CrashDumps` |
| 用户体验报告缓存 | `%LOCALAPPDATA%\Microsoft\Windows\WER\*` |
| DirectX 着色器缓存 | `%LOCALAPPDATA%\D3DSCache` |
| 系统网络缓存 | `%LOCALAPPDATA%\Microsoft\Windows\INetCache`（不含 Cookie） |
| 系统临时文件 | `%SystemRoot%\Temp`（需管理员） |
| 系统级临时目录 | `%SystemRoot%\SystemTemp`（Win11 24H2+，需管理员） |

### 深度项（Deep，系统缓存与日志）

| 项目 | 位置 |
| --- | --- |
| 缩略图 / 图标缓存 | `thumbcache_*.db`、`iconcache_*.db` |
| Windows 更新下载缓存 | `%SystemRoot%\SoftwareDistribution\Download`（清理前暂停 wuauserv / bits） |
| 传递优化缓存 | `Delete-DeliveryOptimizationCache` |
| 预读取文件 | `%SystemRoot%\Prefetch\*.pf` |
| 组件安装日志 | `%SystemRoot%\Logs\CBS` |
| DISM / 更新日志 | `%SystemRoot%\Logs\DISM`、`WindowsUpdate` |
| 内核实时报告 | `%SystemRoot%\LiveKernelReports` |
| 系统级错误报告 | `%ProgramData%\Microsoft\Windows\WER\*` |
| 所有用户的临时文件 | `C:\Users\*\AppData\Local\Temp` |
| 字体缓存 | `FontCache`（清理前暂停 FontCache 服务） |
| 远程桌面缓存 | `%LOCALAPPDATA%\Microsoft\Terminal Server Client\Cache` |
| Chrome / Edge / Firefox 缓存 | 各浏览器 Cache、Code Cache、GPUCache 等 |

### 额外项（Extra，按需选择）

| 项目 | 说明 |
| --- | --- |
| 回收站 | 清空后无法通过回收站恢复 |
| 内存转储 | `MEMORY.DMP`、`Minidump\*` |
| `Windows.old` | 旧系统备份，删除后无法回退；脚本会先 takeown/icacls 取所有权 |
| 升级残留 | `$Windows.~BT`、`$Windows.~WS` |
| 开发工具缓存 | pip、npm、NuGet、Yarn、TypeScript（下次装依赖需重新下载） |

## 安全说明

- **不做的事**：不改注册表、不卸载软件、不动 `Windows\Installer`、不动
  文档/图片/桌面等个人文件、不删 Cookie 和登录态、不删已安装的更新。
- **默认只清空目录内容**，不删除目录本身，避免某些程序因为找不到目录而报错。
- 被占用（正在使用）的文件会删除失败并被计入“失败/跳过”，属于正常现象；
  重启后再清理一次通常会更干净。
- `Windows.old` 的体积统计包含硬链接，**报告值可能大于实际释放量**。
- 清理预读取（Prefetch）与着色器缓存后，首次开机或首次启动程序会稍慢，属正常。
- 需要管理员权限的项目在普通权限下会被直接标记为“跳过”，不会报错中断。

## 常见问题

**Q：为什么“跳过”这么多文件？**
A：临时目录里不少文件正被运行中的程序占用，Windows 不允许删除。关闭相关程序
（尤其是浏览器）或重启后再运行一次即可。

**Q：能清出多少空间？**
A：看系统状况。一般来说 Windows 更新缓存和 `Windows.old` 是大头，常常能清出
几 GB 到几十 GB；日常使用每次运行通常能清出几百 MB。

**Q：日志在哪？**
A：`%LOCALAPPDATA%\DiskTempCleaner\logs\clean_时间戳.log`。

**Q：能不能放到计划任务里定期跑？**
A：可以。操作填 `powershell.exe`，参数填
`-NoProfile -ExecutionPolicy Bypass -File "路径\CleanTemp.ps1" -Safe -Yes`，
并勾选“使用最高权限运行”。

## 自动化测试（可选，日常使用不需要）

仓库里带了一套零依赖测试，用来验证清理引擎和参数解析是否正确。它**只依赖 Windows 自带的
PowerShell 5.1**，不需要 Pester、不需要联网，所有删除都发生在临时沙箱目录里，不会碰系统文件。

在 Windows 上手动跑：

```powershell
powershell -ExecutionPolicy Bypass -File tests\CleanTemp.Tests.ps1
```

输出 53 项断言结果，全部通过则退出码为 0。

如果把这个文件夹推到 GitHub，`.github/workflows/windows-test.yml` 会自动在
**Windows PowerShell 5.1** 和 **PowerShell 7** 两个环境上分别执行：

1. 打印环境信息（系统版本、是否管理员、关键命令与目录是否存在）
2. 解析 `CleanTemp.ps1`（语法检查）
3. 运行 `tests\CleanTemp.Tests.ps1`
4. 执行 `-DryRun -Deep` 预览（不删任何文件）
5. 仅当在 Actions 页面手动触发并勾选 `real_cleanup` 时，才真正清理一次（runner 是一次性的）

> 不用 GitHub 的话，直接删掉 `.github` 和 `tests` 两个文件夹，工具本身完全不受影响。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `CleanTemp.ps1` | 主程序（全部清理逻辑，可单独使用） |
| `一键清理.bat` | 双击启动器，调用主程序并保留窗口 |
| `README.md` | 本文档 |
| `tests/CleanTemp.Tests.ps1` | 零依赖测试套件（53 项断言），可选 |
| `.github/workflows/windows-test.yml` | GitHub Actions 自动测试流水线，可选 |
