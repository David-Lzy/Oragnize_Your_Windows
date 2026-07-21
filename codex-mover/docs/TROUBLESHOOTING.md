# 故障排查

> [返回 Codex Mover](../README.md) · [项目总览](../../README.md) · [共享安全指南](../../docs/SAFETY.md)

## SpaceSniffer 仍显示 C 盘有 Codex

先看它显示的是哪一种：

1. `C:\Users\<当前用户>\.codex`、`.cache\codex-runtimes` 或 `AppData\Local\OpenAI\Codex`：迁移后它们应是 Junction。某些磁盘分析工具会跟随 Junction，把 E 盘目标尺寸算到 C 盘树中。
2. `C:\Program Files\WindowsApps\OpenAI.Codex_*`：Windows 可能继续报告逻辑 C 路径，但包目录本身已是指向 E 的 Junction。
3. `C:\Users\codex`：这是另一个 Windows 用户配置文件，与当前用户的 `.codex` 完全不同，必须单独处理。

使用 `Get-Item -Force` 检查 `LinkType` 和 `Target`，并以磁盘可用空间变化作为物理占用判断。

## Robocopy 校验返回退出码 2

Robocopy 的退出码是位标志。退出码 2 表示目标端有额外文件，不等于复制失败。

本项目对 `.codex` 使用“只补充源端较新文件”的 union 模式；目标端可能已经包含第一次预复制的完整集合，因此 dry-run 校验允许退出码 0 或 2。镜像缓存目录的校验仍要求退出码 0。

退出码 4 表示有不匹配，8 及以上表示至少一个复制失败，不能忽略。

## UAC 已确认，但切换仍提示权限不足

不要用 `Move-Item` 搬动可能含 Junction 或特殊 ACL 的 `.codex` 根目录。管理员权限并不能消除 PowerShell 目录移动对 ReparsePoint 的兼容问题。

本项目使用 Win32 `MoveFileEx` 在 C 盘内把源目录原子改名，再创建 Junction。若仍失败，检查：

- Codex Desktop、`codex.exe`、`codex-code-mode-host.exe` 是否完全退出。
- 插件 `extension-host.exe` 是否仍从源目录运行。
- 防病毒软件是否暂时锁定目录。

## Get-AppxPackage 仍报告 C 路径

`Move-AppxPackage` 完成后，`Get-AppxPackage.InstallLocation` 可能仍返回逻辑 C 路径。判断物理位置时应检查：

- C 的包根目录是否为指向目标盘 `WindowsApps` 的 Junction。
- 目标盘包目录是否存在。
- C/E 两条逻辑路径下的 `ChatGPT.exe` 文件 ID 是否一致。

Windows AppX 部署日志中的 `MovePackageOperation` 成功事件也是有效证据。

MSIX 移动失败不会撤销已经验证完成的 `.codex`/缓存 Junction；状态会写成 `success_pending_cleanup_with_warnings`，验收脚本仍会把 MSIX 项标记为失败。在修好 AppX 问题并重新验收前，可以保留 C 盘迁移备份。

## 当前对话文件被占用，无法算 SHA-256

Codex 运行时 JSONL 会话文件通常被独占写入。这是正常现象。最终 SHA-256 校验必须在 Codex 完全退出后执行；迁移完成并重新打开后，改用 `fsutil file queryfileid` 验证 C/E 路径指向同一文件。

## 清理备份遇到超长路径

Windows PowerShell 5.1 的 `Remove-Item -Recurse` 可能在深层 `node_modules` 路径上失败。不要改用会跟随 Junction 的镜像删除命令。

本项目的清理脚本使用 `src/CodexMover.Native.cs`：

- Win32 长路径前缀。
- 遇到目录 ReparsePoint 直接删除联接，不进入目标。
- 普通目录才递归。

## 状态文件

默认位置：

- `<目标>\migration\migration-state.json`：预复制生成的迁移计划。
- `<目标>\migration\migration-status.json`：收尾和清理状态。
- `<目标>\migration\finalize.log`：最终同步和切换日志。

在状态为 `success_pending_cleanup` 或 `completed` 前，不要手工删除 C 盘备份。
