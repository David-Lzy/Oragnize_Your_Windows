# Windows Cache Mover

> [返回项目总览](../README.md) · [共享安全指南](../docs/SAFETY.md) · [测试指南](../docs/TESTING.md)

面向 Windows 10/11 的缓存审计、清理与迁移工具。它用于解决一种很常见的情况：程序主体已经装在其他磁盘，但浏览器模型、网页缓存和开发工具包缓存仍不断写入 C 盘。

本项目只处理明确可重建的缓存。它不会把整个 `AppData`、Windows 系统目录或用户资料粗暴搬走。

## 能做什么

- 审计 Chrome、Chrome Beta、Brave、Edge 的缓存目录、占用、运行状态和既有目录联接。
- 只读扫描 Chromium 扩展中的“标签更新事件 → 查询全部标签 → 批量换图标/注入脚本”放大模式。
- 监控浏览器主进程在冷启动和会话恢复时的句柄、私有内存与进程数，识别资源风暴并保存 JSON 证据。
- 默认只迁移 Chrome / Chrome Beta 的本地优化模型；浏览器普通缓存、代码缓存、GPU 缓存、Service Worker 缓存和扩展包缓存默认留在系统盘。
- 浏览器运行时缓存必须显式选择，并且目标必须能确认是单块 SSD；HDD、RAID、Storage Spaces、虚拟盘和无法识别的介质默认拒绝。
- 迁移 pip、npm、Conda 包、Hugging Face、PyTorch、uv 缓存，并固化相应用户环境变量。
- 查找指定目录下的大文件，自动跳过目录联接，避免重复统计目标盘内容。
- 每次正式迁移生成 JSON 清单，支持验证和回滚。
- 默认只预览；只有显式使用 `-Apply` 才会修改文件系统。

## 明确不会处理

以下目录不应通过普通目录联接强制迁移，本工具也不会操作它们：

- `C:\Windows\WinSxS`
- `C:\Windows\System32\DriverStore`
- `C:\Windows\Installer`
- Windows Update、Defender、Microsoft Store 数据
- 整个用户 `AppData`、`TEMP/TMP`、页面文件
- 浏览器书签、密码、Cookie、扩展和普通网站持久数据

这些内容应使用 Windows 官方维护方式或对应软件自身的设置。

## 环境要求

- Windows 10/11
- Windows PowerShell 5.1 或 PowerShell 7+
- 目标必须是本机健康的 NTFS 卷
- 正式迁移前必须退出所选浏览器

目标盘如果离线，已迁移缓存的软件可能无法正常使用缓存。浏览器在冷启动和会话恢复时会并发读取大量运行时缓存；把这些高频路径联接到慢盘或介质类型不明的卷，可能造成启动资源异常、崩溃及扩展被错误标记为损坏，因此它们不再属于默认迁移范围。

少量 Chromium 根级着色器缓存没有列入迁移：浏览器启动时可能删除并重建这些目录，联接不耐久，而且通常占用很小。配置档案内的 GPU 缓存仍可审计，但属于需要显式选择的浏览器运行时缓存。

## Chrome 会话恢复崩溃防复发

浏览器只打开一个崩溃提示页时正常、点击“恢复”后才崩溃，不足以证明迁移过的缓存损坏。大量标签同时恢复也可能把扩展中的全局标签遍历缺陷放大成主进程句柄和内存风暴。

先运行只读扩展风险扫描。它不会加载、修改、禁用或删除扩展：

```powershell
.\scripts\Get-ChromiumExtensionRiskReport.ps1 `
    -Browser Chrome `
    -JsonPath '.\extension-risk.json'
```

`TabUpdateGlobalFanOut` 表示扫描器在同一脚本不超过 4,096 个字符的局部窗口内发现了 `tabs.onUpdated`、查询全部标签，以及 `setIcon` 或 `executeScript`。报告的风险级别为 `Review`、置信度为 `Heuristic`：它是需要复核的事件放大线索，不是对扩展恶意性或因果关系的自动判决。局部窗口限制用于避免大型打包脚本仅因不同模块分别使用这些 API 而误报。

关闭 Chrome 后先启动监控，再重新打开浏览器并恢复原会话：

```powershell
.\scripts\Test-BrowserStartupHealth.ps1 `
    -Browser Chrome `
    -MonitorSeconds 120 `
    -JsonPath '.\chrome-startup-health.json'
```

默认在主进程连续 3 个样本达到 12,000 个句柄或 2,048 MB 私有内存时报告 `ResourceStorm`，但不会结束浏览器。若 Chrome 同时把扩展标成“可能已损坏”，先保留现场并检查风险报告；不要直接点击“修复”，因为修复会重新安装并重新启用同一份问题代码。应先手动禁用嫌疑扩展，重复同样的会话恢复测试并比较报告。

如何进一步用句柄来源区分“迁移路径问题”和“扩展事件放大”，见 [Chromium 启动资源风暴排查](./docs/CHROMIUM-STARTUP-RESOURCE-STORM.md)。

## 缓存迁移分级

| 类别 | 示例 | 默认迁移 |
| --- | --- | --- |
| `BrowserColdModel` | Chrome 本地优化模型 | 是 |
| `BrowserRestoreHotPath` | `Cache`、`Code Cache`、`GPUCache`、Service Worker 缓存 | 否 |
| `BrowserPackageCache` | `extensions_crx_cache`、`component_crx_cache` | 否 |
| `DeveloperCache` | pip、npm、Conda、Hugging Face、PyTorch、uv | `IncludeDeveloper` 开启时 |

审计结果中的 `MigrationClass`、`SelectedForMigration`、`DestinationMediaType` 和 `DestinationConfirmedSSD` 会显示当前选择与介质判断。

## 快速开始

以下示例以 F 盘为目标，生成 `F:\BrowserCache` 和 `F:\DevCache`。

### 1. 只读审计

```powershell
.\scripts\Get-CacheReport.ps1 -DestinationRoot 'F:\' |
    Format-Table Name, MigrationClass, SelectedForMigration, Status, GB, DestinationMediaType -AutoSize
```

快速模式不递归计算大小：

```powershell
.\scripts\Get-CacheReport.ps1 -DestinationRoot 'F:\' -Fast
```

### 2. 预览迁移

不加 `-Apply` 不会产生改动：

```powershell
.\scripts\Move-Cache.ps1 -DestinationRoot 'F:\'
```

### 3. 正式迁移

默认先复制现有缓存，再创建目录联接。下面的命令只会选择浏览器冷模型和开发工具缓存，不会选择浏览器运行时或扩展包缓存：

```powershell
.\scripts\Move-Cache.ps1 -DestinationRoot 'F:\' -Apply
```

只有在确实需要、且目标被识别为单块 SSD 时，才显式包含浏览器运行时缓存：

```powershell
.\scripts\Move-Cache.ps1 `
    -DestinationRoot 'E:\' `
    -IncludeBrowserRuntimeCaches `
    -Apply
```

对 HDD、RAID、Storage Spaces、虚拟盘或无法确认介质类型的目标，即使使用上面的开关也会中止。存在双重显式覆盖开关 `-AllowSlowOrUnknownBrowserDestination`，但它会重新引入浏览器冷启动和会话恢复风险，不建议用于日常迁移：

```powershell
.\scripts\Move-Cache.ps1 `
    -DestinationRoot 'F:\' `
    -IncludeBrowserRuntimeCaches `
    -AllowSlowOrUnknownBrowserDestination `
    -Apply
```

如果确定不需要现有缓存，可清空后建立联接：

```powershell
.\scripts\Move-Cache.ps1 -DestinationRoot 'F:\' -DiscardExisting -Apply
```

浏览器仍在运行时，脚本会直接中止，不会自动结束进程。

Chrome Beta 在参数中使用名称 `ChromeBeta`，迁移到 `F:\BrowserCache\ChromeBeta`。Chrome 稳定版和 Beta 共用 `chrome.exe` 进程名；迁移其中任一版本前，都应退出所有 Chrome 窗口和后台进程。例如只迁移 Beta：

```powershell
.\scripts\Move-Cache.ps1 -DestinationRoot 'F:\' -Browser ChromeBeta -Apply
```

开发工具缓存路径会写入当前用户环境变量，并广播 Windows 环境变更。已经运行的终端或 IDE 仍应重新打开。

### 4. 验证

迁移清单保存在目标盘的 `.cache-mover` 目录：

```powershell
.\scripts\Test-CacheMove.ps1 -DestinationRoot 'F:\'
```

也可以指定某次清单：

```powershell
.\scripts\Test-CacheMove.ps1 -ManifestPath 'F:\.cache-mover\manifest-20260721-220000.json'
```

### 5. 回滚

先验证，不修改：

```powershell
.\scripts\Restore-CacheMove.ps1 -ManifestPath 'F:\.cache-mover\manifest-20260721-220000.json'
```

恢复原路径但不复制缓存内容：

```powershell
.\scripts\Restore-CacheMove.ps1 -ManifestPath 'F:\.cache-mover\manifest-20260721-220000.json' -Apply
```

把目标盘缓存复制回原路径：

```powershell
.\scripts\Restore-CacheMove.ps1 -ManifestPath 'F:\.cache-mover\manifest-20260721-220000.json' -CopyBack -Apply
```

## 查找大文件

默认扫描当前用户目录，只报告不删除：

```powershell
.\scripts\Find-LargeFiles.ps1 -Path $HOME -MinimumGB 1 -Top 50 |
    Format-Table GB, AllocatedGB, Sparse, LastWriteTime, Path -AutoSize
```

扫描整个 C 盘需要更长时间，部分系统目录可能因权限被跳过：

```powershell
.\scripts\Find-LargeFiles.ps1 -Path 'C:\' -MinimumGB 2 -Top 100
```

`GB` 是文件逻辑长度，`AllocatedGB` 是 NTFS 实际分配大小。虚拟磁盘等稀疏文件可能显示很大的 `GB`，但 `Sparse = True` 且 `AllocatedGB` 很小；判断能释放多少空间时应以后者为准。

## “程序不在 C 盘，为什么 C 盘仍然很大？”

安装目录和运行数据目录是两回事。例如某些游戏主程序可能位于 `E:\Games`，但 Unity 补丁、资源副本、聊天数据仍保存在：

```text
%USERPROFILE%\AppData\LocalLow\<Publisher>\<Game>
```

这类目录可能包含有效游戏资源或账号数据，不属于通用缓存。本工具会让你通过大文件报告发现它们，但不会自动删除或迁移；应先确认软件支持方式，或在软件退出后单独制定迁移方案。

## 安全设计

- 迁移目标必须位于指定目标根目录内。
- 已存在的其他目录联接不会被覆盖。
- 浏览器会话恢复热路径和扩展包缓存默认不进入迁移选择。
- 高风险浏览器缓存只允许迁往已确认的单块 SSD；介质判断失败时默认拒绝。
- 回滚只接受与清单目标完全一致的目录联接。
- 递归统计和大文件扫描不会跟随重解析点。
- 不把目标盘上的缓存重复计入 C 盘占用。
- 迁移清单只记录路径和大小，不收集浏览器资料或凭据。

## 测试

烟雾测试在 `%TEMP%` 下创建隔离目录，覆盖扩展风险规则、浏览器进程健康采样，以及“复制现有缓存 → 建立联接 → 验证 → 复制回滚”，最后清理测试数据：

```powershell
.\tests\Invoke-SmokeTest.ps1
```

测试不会操作真实浏览器目录，也不会修改用户环境变量。
