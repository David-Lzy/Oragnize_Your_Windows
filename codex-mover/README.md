# Codex Mover

> [返回项目总览](../README.md) · [共享安全指南](../docs/SAFETY.md) · [测试指南](../docs/TESTING.md)

本目录包含两类边界不同的 Codex 迁移工具：

- **Windows 整体搬盘**：将 Codex Desktop 占用的主要磁盘空间迁移到其他 NTFS 磁盘，同时保留 Codex 仍然期望存在的原始 C 盘路径。
- **Linux 单 task 迁移**：在两个 `CODEX_HOME` 之间复制一个 task 的 rollout、SQLite row 和 session index，保留原 ID 与完整历史。

本项目来源于一次真实迁移：活跃 Codex 对话不能中断或丢失；`.codex`、运行时缓存和 Local OpenAI 数据可以迁移，但 AppX 程序包必须留在系统盘；Windows 和磁盘分析工具还会把 Junction 的目标误显示在 C 盘下面。

## 平台入口

| 场景 | 使用入口 | 风险边界 |
| --- | --- | --- |
| Windows C 盘空间不足，需要整体迁移当前用户 Codex 数据 | 继续阅读本页 | UAC 收尾、Junction、AppX 固定留在系统盘 |
| Linux/SSH 下只迁移一个 task 到另一套 `CODEX_HOME`/API Key | [Linux Codex 单任务迁移](./linux-session-mover/) | Codex 停止后复制 rollout、SQLite row、索引；源端保留 |

不要把两套命令混用。Linux 工具不会搬 Windows AppX、运行时缓存或整套认证；Windows 工具也不会把一个 task 合并进另一个 `CODEX_HOME`。

## Windows：会迁移什么

| 逻辑路径 | 默认物理目标 |
| --- | --- |
| `%USERPROFILE%\.codex` | `<目标>\home` |
| `%USERPROFILE%\.cache\codex-runtimes` | `<目标>\cache\codex-runtimes` |
| `%LOCALAPPDATA%\OpenAI\Codex` | `<目标>\local\OpenAI\Codex` |
| Codex AppX/MSIX 包 | **保留 Windows 系统盘，不迁移** |
| MSIX 用户数据 | 继续由 Windows 在系统盘管理 |

前三个可迁移路径会变成 Junction。AppX 程序包不会创建跨盘 Junction；这是为了避免 bundled plugin 资源复制失败并导致 Chrome 扩展缺少 app-server `nodePath`。完整事故原因见 [AppX 插件故障记录](./docs/APPX-PLUGIN-INCIDENT.md)。

## Windows：推荐流程

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
3. 等管理员窗口完成最终同步和原子切换；AppX 程序包会留在系统盘。
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

## Windows：活跃任务保护

`-CurrentThreadId` 用于锁定当前 JSONL 会话文件。收尾脚本会在 Codex 完全退出后，对 C 源文件和 E 目标文件做 SHA-256 校验；切换后，验证脚本还会比较 C/E 逻辑路径的文件 ID，确认它们是同一个 E 盘文件。

如果不提供任务 ID，脚本会使用 `.codex\sessions` 中最后修改的 JSONL。自动选择适合普通迁移，但从正在进行的 Codex 对话内迁移时，显式任务 ID更可靠。

## SSH 远程 Session 的 Windows 兼容

把单个 task 从一个 SSH 连接的 `CODEX_HOME` 移到另一个后，Linux 端 rollout/SQLite 迁移和 Windows Desktop 路由是两个独立步骤。典型失败表现是：侧栏已经显示目标 Host，但点击后变成“新任务”，并提示 `no rollout found for thread id ...`。先确保目标 SQLite 使用 `$CODEX_HOME/sessions/...` 逻辑路径而不是软链接解析后的磁盘 realpath；再处理 Windows 路由。

先完成远端复制、数据库索引和真实 `thread/read` 验证；再完全退出所有 Windows Session 中的 Codex Desktop，使用默认只预览的路由脚本：

```powershell
.\scripts\Repair-CodexRemoteThreadRoute.ps1 `
    -ThreadId '<task UUID>' `
    -TargetHost '<目标 SSH alias>' `
    -TargetRemotePath '/srv/projects/personal' `
    -TargetCwd '/srv/projects/personal/site'
```

`-TargetRemotePath` 是已保存的 remote project 根；任务实际 cwd 位于其子目录时，用 `-TargetCwd` 单独指定。确认 host、project ID 与两个 path 后，追加 `-Apply`。脚本会备份 `.codex-global-state.json` 及其 `.bak`，并统一创建或更新 assignment、workspace、sidebar 与 writable roots；这也覆盖任务可见但打开时报 `AbsolutePathBuf deserialized without a base path` 的缺路由情况。完整根因、远端迁移顺序、恢复方法和实测代码见 [SSH 远程 Session 迁移后的 Windows Desktop 兼容](./docs/SSH-REMOTE-SESSION-WINDOWS-COMPATIBILITY.md)。

## Windows：Sidecar 用户

有些机器还存在名为 `codex` 的独立 Windows 用户配置文件，例如 `C:\Users\codex`。它不是当前用户 `.codex` 目录，也不会随当前用户迁移自动消失。

先确认该配置文件未加载，并盘点其中的 `.codex\sessions`、插件、凭据和缓存。即使当前账户已迁移，这个独立账户也可能含有目标盘中不存在的历史会话；应先单独归档或迁移，不能按“重复备份”直接删除。确实确认该用户和独有数据都不再需要时，才在管理员 PowerShell 中使用独立的高风险脚本：

```powershell
.\scripts\Remove-CodexSidecarUser.ps1 `
    -AccountName 'codex' `
    -ExpectedSid 'S-1-5-21-...' `
    -RemoveUserTasks `
    -IUnderstandThisDeletesTheAccount `
    -Confirm:$false
```

该操作永久删除用户、配置文件、对应 AppX 注册和明确属于该 SID 的计划任务，不会创建备份。

## Windows：安全设计

- 最终路径切换必须在 UAC 管理员窗口中执行。
- 收尾脚本等待 Codex 核心进程完全退出；若同步期间进程重新出现，会再次等待并重新同步。
- UAC 收尾器会再次校验状态文件中的源/目标路径，并拒绝经过 ReparsePoint 的路径组件。
- 开始、收尾和验收都会确认 OpenAI.Codex AppX 包直接位于系统盘；检测到跨盘 AppX 或包根 ReparsePoint 时会停止。
- C 盘源目录使用 Win32 `MoveFileEx` 同卷原子改名，随后才创建 Junction；临时文件锁会触发有限次数重试，日志保留 Win32 错误码和系统消息。
- 切换失败时会尝试按逆序恢复原目录。
- 清理脚本只接受状态文件记录的精确备份路径。
- 清理备份前会再次确认迁移状态采用 `keep_system_volume`，且 AppX 仍直接位于系统盘。
- 长路径清理由 Win32 枚举实现，遇到 ReparsePoint 只删除联接本身，不递归进入目标。
- 迁移会把 `auth.json` 作为不透明状态文件复制到目标盘，但不会读取、打印或提交其中的凭据。

更多已知问题见 [故障排查](./docs/TROUBLESHOOTING.md)；迁移器为何不再移动 AppX 见 [事故记录与设计决策](./docs/APPX-PLUGIN-INCIDENT.md)；SSH 任务迁移后 Windows 客户端为何仍访问旧 Host 见 [远程 Session 兼容说明](./docs/SSH-REMOTE-SESSION-WINDOWS-COMPATIBILITY.md)。

## Windows：要求

- Windows 10/11
- Windows PowerShell 5.1 或 PowerShell 7
- 目标盘为 NTFS
- 目标盘有足够空间
- 当前账户可以弹出 UAC

启动脚本优先用 `pwsh.exe` 打开 UAC 收尾器；未安装 PowerShell 7 时自动回退到 `powershell.exe`。

## 测试

```powershell
.\tests\Invoke-StaticChecks.ps1
```

静态测试会解析全部 PowerShell 文件、编译 Win32 辅助代码，并检查是否意外写入机器专用用户名或任务 ID。

Linux 单 task 迁移测试使用 Python 临时目录，不会读取真实 `CODEX_HOME`：

```bash
python3 -m unittest discover \
  -s codex-mover/linux-session-mover/tests \
  -v
```
