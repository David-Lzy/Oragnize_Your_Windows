# Windows Cache Mover

面向 Windows 10/11 的缓存审计、清理与迁移工具。它用于解决一种很常见的情况：程序主体已经装在其他磁盘，但浏览器模型、网页缓存、开发工具包缓存和游戏运行数据仍不断写入 C 盘。

本项目只处理明确可重建的缓存。它不会把整个 `AppData`、Windows 系统目录或用户资料粗暴搬走。

## 能做什么

- 审计 Chrome、Brave、Edge 的缓存目录、占用、运行状态和既有目录联接。
- 迁移浏览器普通缓存、代码缓存、GPU 缓存、Service Worker 缓存和 Chrome 本地优化模型。
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

目标盘如果离线，已迁移缓存的软件可能无法正常使用缓存。机械硬盘还可能降低首次加载速度。

少量 Chromium 根级着色器缓存没有列入迁移：浏览器启动时可能删除并重建这些目录，联接不耐久，而且通常占用很小。配置档案内的 GPU 缓存仍在支持范围内。

## 快速开始

以下示例以 F 盘为目标，生成 `F:\BrowserCache` 和 `F:\DevCache`。

### 1. 只读审计

```powershell
.\scripts\Get-CacheReport.ps1 -DestinationRoot 'F:\' |
    Format-Table Name, Status, GB, RunningProcesses, Source, ActualTarget -AutoSize
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

默认先复制现有缓存，再创建目录联接：

```powershell
.\scripts\Move-Cache.ps1 -DestinationRoot 'F:\' -Apply
```

如果确定不需要现有缓存，可清空后建立联接：

```powershell
.\scripts\Move-Cache.ps1 -DestinationRoot 'F:\' -DiscardExisting -Apply
```

浏览器仍在运行时，脚本会直接中止，不会自动结束进程。

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
.\scripts\Find-LargeFiles.ps1 -Path $HOME -MinimumGB 1 -Top 50
```

扫描整个 C 盘需要更长时间，部分系统目录可能因权限被跳过：

```powershell
.\scripts\Find-LargeFiles.ps1 -Path 'C:\' -MinimumGB 2 -Top 100
```

## “程序不在 C 盘，为什么 C 盘仍然很大？”

安装目录和运行数据目录是两回事。例如某些游戏主程序可能位于 `E:\Games`，但 Unity 补丁、资源副本、聊天数据仍保存在：

```text
%USERPROFILE%\AppData\LocalLow\<Publisher>\<Game>
```

这类目录可能包含有效游戏资源或账号数据，不属于通用缓存。本工具会让你通过大文件报告发现它们，但不会自动删除或迁移；应先确认软件支持方式，或在软件退出后单独制定迁移方案。

## 安全设计

- 迁移目标必须位于指定目标根目录内。
- 已存在的其他目录联接不会被覆盖。
- 回滚只接受与清单目标完全一致的目录联接。
- 递归统计和大文件扫描不会跟随重解析点。
- 不把目标盘上的缓存重复计入 C 盘占用。
- 迁移清单只记录路径和大小，不收集浏览器资料或凭据。

## 测试

烟雾测试在 `%TEMP%` 下创建隔离目录，覆盖“复制现有缓存 → 建立联接 → 验证 → 复制回滚”，最后清理测试数据：

```powershell
.\tests\Invoke-SmokeTest.ps1
```

测试不会操作真实浏览器目录，也不会修改用户环境变量。
