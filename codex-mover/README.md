# Codex Mover

> [返回项目总览](../README.md) · [共享安全指南](../docs/SAFETY.md) · [测试指南](../docs/TESTING.md)

将 Windows Codex Desktop 占用的主要磁盘空间迁移到其他 NTFS 磁盘，同时保留 Codex 仍然期望存在的原始 C 盘路径。

本项目来源于一次真实迁移：活跃 Codex 对话不能中断或丢失；`.codex`、运行时缓存、Local OpenAI 数据和 MSIX 包需要分别处理；Windows 和磁盘分析工具还会把 Junction 的目标误显示在 C 盘下面。

## 会迁移什么

| 逻辑路径 | 默认物理目标 |
| --- | --- |
| `%USERPROFILE%\.codex` | `<目标>\home` |
| `%USERPROFILE%\.cache\codex-runtimes` | `<目标>\cache\codex-runtimes` |
| `%LOCALAPPDATA%\OpenAI\Codex` | `<目标>\local\OpenAI\Codex` |
| Codex MSIX 包 | 目标盘的 `WindowsApps` AppX Volume |
| MSIX 用户数据 | 由 Windows 自动迁移到目标盘 `WpSystem` |

原路径会变成 Junction。Windows 注册表、AppX 元数据和 Junction 本身仍会在 C 盘保留极少量信息，这是正常且必要的。

## 推荐流程

在普通 PowerShell 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass

# 1. 先盘点。该命令不修改系统。
.\scripts\Get-CodexStorageReport.ps1 -DestinationRoot 'E:\CodexData'

# 2. 预复制，并启动 UAC 收尾窗口。
# 如果从 Codex 对话内操作，强烈建议传入当前任务 UUID。
.\scripts\Start-CodexMigration.ps1 `
    -DestinationRoot 'E:\CodexData' `
    -CurrentThreadId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

UAC 窗口出现后：

1. 点击“是”。
2. 完全退出 Codex Desktop。
3. 等管理员窗口完成最终同步、原子切换和 AppX 移动。
4. Codex 会尝试自动重新打开。

如果目标下已经存在 `home`、`cache\codex-runtimes` 或 `local\OpenAI\Codex`，脚本默认停止，避免覆盖别的迁移。只有确认这些目录是同一次迁移留下的数据时，才使用 `-Force` 继续合并/镜像。

回到 Codex 后运行：

```powershell
# 3. 验收；不会删除备份。
.\scripts\Test-CodexMigration.ps1 -DestinationRoot 'E:\CodexData'

# 4. 验收成功后，删除 C 盘迁移备份。
.\scripts\Remove-CodexMigrationBackups.ps1 `
    -DestinationRoot 'E:\CodexData' `
    -Confirm:$false
```

## 活跃任务保护

`-CurrentThreadId` 用于锁定当前 JSONL 会话文件。收尾脚本会在 Codex 完全退出后，对 C 源文件和 E 目标文件做 SHA-256 校验；切换后，验证脚本还会比较 C/E 逻辑路径的文件 ID，确认它们是同一个 E 盘文件。

如果不提供任务 ID，脚本会使用 `.codex\sessions` 中最后修改的 JSONL。自动选择适合普通迁移，但从正在进行的 Codex 对话内迁移时，显式任务 ID更可靠。

## Sidecar 用户

有些机器还存在名为 `codex` 的独立 Windows 用户配置文件，例如 `C:\Users\codex`。它不是当前用户 `.codex` 目录，也不会随当前用户迁移自动消失。

先盘点或确认该用户不再使用；确实要删除时，在管理员 PowerShell 中使用独立的高风险脚本：

```powershell
.\scripts\Remove-CodexSidecarUser.ps1 `
    -AccountName 'codex' `
    -ExpectedSid 'S-1-5-21-...' `
    -RemoveUserTasks `
    -IUnderstandThisDeletesTheAccount `
    -Confirm:$false
```

该操作永久删除用户、配置文件、对应 AppX 注册和明确属于该 SID 的计划任务，不会创建备份。

## 安全设计

- 最终路径切换必须在 UAC 管理员窗口中执行。
- 收尾脚本等待 Codex 核心进程完全退出。
- UAC 收尾器会再次校验状态文件中的源/目标路径，并拒绝经过 ReparsePoint 的路径组件。
- C 盘源目录使用 Win32 `MoveFileEx` 同卷原子改名，随后才创建 Junction。
- 切换失败时会尝试按逆序恢复原目录。
- 清理脚本只接受状态文件记录的精确备份路径。
- 长路径清理由 Win32 枚举实现，遇到 ReparsePoint 只删除联接本身，不递归进入目标。
- 迁移会把 `auth.json` 作为不透明状态文件复制到目标盘，但不会读取、打印或提交其中的凭据。

更多已知问题见 [故障排查](./docs/TROUBLESHOOTING.md)。

## 要求

- Windows 10/11
- Windows PowerShell 5.1 或 PowerShell 7
- 目标盘为 NTFS
- 目标盘有足够空间
- 当前账户可以弹出 UAC

## 测试

```powershell
.\tests\Invoke-StaticChecks.ps1
```

静态测试会解析全部 PowerShell 文件、编译 Win32 辅助代码，并检查是否意外写入机器专用用户名或任务 ID。
