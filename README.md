# Organize Your Windows

一组面向 Windows 10/11 的安全型整理与迁移工具，覆盖下载目录整理、应用缓存搬家，以及 Codex Desktop 数据迁移。

这些工具会处理真实文件。默认流程强调“先盘点、再预览、显式执行、立即验证、保留回滚”，但不同子项目的风险边界并不相同。运行任何写操作前，请先阅读对应 README 和[共享安全指南](./docs/SAFETY.md)。

## 项目一览

| 子项目 | 适用场景 | 默认行为 | 写操作与恢复 |
| --- | --- | --- | --- |
| [Folder Organizer](./folder-organizer/) | 下载目录杂乱、重复文件、旧安装包、文档分类和本地检索 | 生成只读计划 | `apply --confirm APPLY` 才移动文件；写入 rollback 清单，可 `undo` |
| [Windows Cache Mover](./windows-cache-mover/) | Chrome（含 Beta）、Brave、Edge 与开发工具缓存持续占用 C 盘 | 审计或预览 | `-Apply` 后复制/建立 Junction；JSON 清单支持验证与恢复 |
| [Codex Mover](./codex-mover/) | Windows Codex 的 `.codex`、运行时缓存和本地数据占用 C 盘 | 只读盘点与预复制；AppX 留在系统盘 | UAC 收尾器等待 Codex 退出后切换；保留 C 盘备份，验收后再清理 |

### 应该选择哪个？

- 整理 `Downloads` 或其他普通文件夹：使用 **Folder Organizer**。
- 搬走可重建的浏览器/开发工具缓存：使用 **Windows Cache Mover**。
- 搬走 Codex Desktop 的会话、配置、运行时和本地数据：使用 **Codex Mover**；Windows 管理的 AppX 应用包不会迁移。
- 清理 `WinSxS`、`DriverStore`、Windows Installer、Defender、Windows Update、整份 `AppData`：这些不属于本仓库支持范围，请使用 Windows 或软件自身的维护方式。

## 共同设计原则

1. **只读优先**：盘点、计划和验证与真正写操作分离。
2. **显式授权**：高风险操作需要 `-Apply`、确认令牌或 UAC。
3. **范围固定**：目标必须位于声明的根目录；不跟随未知 Junction/ReparsePoint。
4. **可验证**：使用哈希、文件 ID、清单或状态文件确认结果。
5. **可恢复**：能回滚的操作会保留源数据、备份或 rollback manifest。
6. **秘密最小化**：报告不收集浏览器凭据；Codex 凭据只作为不透明文件迁移，不会写入日志或仓库。

更完整的操作前检查、风险分级与恢复顺序见 [docs/SAFETY.md](./docs/SAFETY.md)。

## 快速开始

```powershell
git clone https://github.com/David-Lzy/Oragnize_Your_Windows.git
Set-Location .\Oragnize_Your_Windows
```

### Folder Organizer：先生成计划

需要 Python 3.11 或更新版本。

```powershell
Push-Location .\folder-organizer
Copy-Item .\config.example.toml .\config.toml
python -m pip install -e .

# 编辑 config.toml 后，仅生成计划，不移动文件。
download-curator --config .\config.toml plan
Pop-Location
```

正式应用、文档分类、索引和撤销说明见 [folder-organizer/README.md](./folder-organizer/README.md)。

### Windows Cache Mover：先审计和预览

```powershell
Push-Location .\windows-cache-mover

# 只读审计。
.\scripts\Get-CacheReport.ps1 -DestinationRoot 'F:\'

# 不带 -Apply 时仍然只是预览。
.\scripts\Move-Cache.ps1 -DestinationRoot 'F:\'
Pop-Location
```

支持的缓存、正式迁移和回滚方式见 [windows-cache-mover/README.md](./windows-cache-mover/README.md)。

### Codex Mover：先盘点

```powershell
Push-Location .\codex-mover

# 只读，不关闭 Codex，也不修改路径。
.\scripts\Get-CodexStorageReport.ps1 -DestinationRoot 'E:\CodexData'
Pop-Location
```

迁移当前活跃任务时，需要仔细遵循 UAC 收尾和重启验收流程，详见 [codex-mover/README.md](./codex-mover/README.md)。

## 环境要求

| 项目 | Windows | PowerShell | 其他要求 |
| --- | --- | --- | --- |
| Folder Organizer | Windows 10/11 | 用于示例命令 | Python 3.11+；安装 `pypdf` 依赖 |
| Windows Cache Mover | Windows 10/11 | 5.1 或 7+ | 本机健康 NTFS 目标卷；迁移前退出相关应用 |
| Codex Mover | Windows 10/11 | 5.1 或 7+ | 本机 NTFS 目标卷、足够空间、可确认 UAC |

管理员权限并非所有命令都需要。Codex 的最终目录切换和 sidecar 用户删除必须在提升权限后完成；普通盘点和大多数预览命令应在普通用户权限下运行。Codex AppX 固定保留在系统盘。

## 仓库结构

```text
Oragnize_Your_Windows/
├── README.md
├── docs/                         共享安全与测试文档
├── folder-organizer/             Python 文件整理与本地索引
├── windows-cache-mover/          PowerShell 缓存审计与 Junction 迁移
└── codex-mover/                  PowerShell/C# Codex 数据迁移与 AppX 位置保护
```

## 测试

三个子项目的测试都使用临时或隔离数据，不会操作真实下载目录、浏览器缓存或 Codex 数据。

```powershell
# Folder Organizer
Push-Location .\folder-organizer
python -m pip install -e .
python -m unittest discover -s tests -v
Pop-Location

# Windows Cache Mover
.\windows-cache-mover\tests\Invoke-SmokeTest.ps1

# Codex Mover
.\codex-mover\tests\Invoke-StaticChecks.ps1
```

Windows PowerShell 5.1 的兼容性命令和预期结果见 [docs/TESTING.md](./docs/TESTING.md)。

## 文档

- [文档索引](./docs/README.md)
- [共享安全指南](./docs/SAFETY.md)
- [开发与测试指南](./docs/TESTING.md)
- [Codex Mover 故障排查](./codex-mover/docs/TROUBLESHOOTING.md)
- [Codex AppX 迁盘导致插件失效的事故记录](./codex-mover/docs/APPX-PLUGIN-INCIDENT.md)

## 非目标

- 不提供“一键清空 C 盘”或系统目录删除功能。
- 不把未知目录一律视为缓存。
- 不在缺少清单、状态文件或目标验证时执行恢复/清理。
- 不允许外部 LLM 直接获得文件系统写权限；Folder Organizer 的模型输出只能作为受约束的分类决策输入。

如果不确定某条命令是否会修改文件，请先停在盘点/预览步骤，并检查对应 README 中的写操作开关。
