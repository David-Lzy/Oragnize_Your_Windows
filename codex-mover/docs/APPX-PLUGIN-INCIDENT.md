# Codex AppX 迁盘导致 Chrome 插件失效：事故记录与设计决策

> [返回 Codex Mover](../README.md) · [故障排查](./TROUBLESHOOTING.md) · [共享安全指南](../../docs/SAFETY.md)

## 决策

Codex Mover **不再迁移 OpenAI.Codex AppX/MSIX 程序包**。程序包必须直接保留在 Windows 系统盘的 `WindowsApps` 中；工具只迁移 `CODEX_HOME`、Codex 运行时缓存和 `%LOCALAPPDATA%\OpenAI\Codex`。

这是故障修复，不是单纯的保守偏好。目标盘仍可承载主要可迁移数据，但 AppX 程序本体和由 Windows 管理的 packaged data 会继续占用系统盘。

## 用户可见症状

Chrome 扩展已经安装、启用并显示已连接，但侧边栏无法启动，典型错误为：

```text
Unable to start ChatGPT
Codex app-server manifest entry is missing required path nodePath
```

重新启动 Chrome、重新安装扩展或重新授予网站权限都不能解决问题。

## 根因链

1. 旧版迁移器默认创建目标盘 AppX Volume，并调用 `Move-AppxPackage` 把 OpenAI.Codex 程序包迁出系统盘。
2. Windows 仍可能返回系统盘上的逻辑 `InstallLocation`，但包根目录实际是指向另一个 `WindowsApps` 卷的 Junction/ReparsePoint。
3. Codex 启动时需要把程序包中的 bundled plugin 资源复制到 `CODEX_HOME` 下的 marketplace staging/cache。
4. 跨卷 AppX 中受 Windows 保护的文件在该复制路径上返回 `EPERM`/`UNKNOWN`，staging 只生成空目录或不完整目录。
5. Chrome Native Messaging 需要的 app-server 清单因此缺少 `nodePath`。扩展显示的是下游清单错误，并不是扩展包本身损坏。

Chrome 浏览器缓存位于其他磁盘与这条故障链无关。缓存迁移若出错，通常影响浏览器 profile、缓存读取或扩展加载；它不会生成 Codex app-server 清单中的缺失字段。

## 为什么不能只增加一次迁移后检查

AppX 移动本身可以成功，目标盘包目录、逻辑 Junction 和可执行文件 ID 也可以全部匹配；故障发生在 Codex 随后的插件资源物化阶段。因此，“包已移动且文件存在”不足以证明 Codex 功能正常。

项目采用更强的不变量：

- 开始预复制前确认 OpenAI.Codex 包直接位于系统盘，包根目录不是 ReparsePoint。
- UAC 收尾器在修改任何 Codex 目录前再次检查同一条件。
- 收尾完成后再次检查；若条件变化，目录切换会回滚。
- 验收脚本把 AppX 系统卷位置作为关键结果。
- 备份清理脚本再次检查策略和实际 AppX 位置，不满足时拒绝删除恢复材料。
- 测试禁止 `Move-AppxPackage` 和 `Add-AppxVolume` 再次进入 Codex Mover 代码。

## 已经迁盘的机器

先停止新的迁移和备份清理，保留 migration 状态、日志以及 C/E 两侧数据。完全退出 Codex Desktop 和 Chrome 后，将 OpenAI.Codex 包移回 Windows 的 system AppX volume，再重新启动 Codex，让 bundled marketplace 和 Native Messaging 清单重新生成。

管理员 PowerShell 中可先只读确认：

```powershell
Get-AppxPackage -Name OpenAI.Codex |
    Select-Object PackageFullName, InstallLocation, Status

Get-AppxVolume |
    Select-Object PackageStorePath, IsSystemVolume, IsOffline
```

若包根目录是指向非系统盘 `WindowsApps` 的 ReparsePoint，不要手工复制或删除受保护的包目录。使用 Windows 设置中的应用移动功能或管理员 PowerShell 的 AppX 管理命令把包移回 `IsSystemVolume = True` 的卷。恢复后运行：

```powershell
.\scripts\Get-CodexStorageReport.ps1
.\scripts\Test-CodexMigration.ps1 -DestinationRoot '<目标 CodexData 目录>'
```

只有 AppX 位置、Codex 启动以及依赖 Chrome 插件的实际标签页操作都验证成功后，才能清理旧备份。
