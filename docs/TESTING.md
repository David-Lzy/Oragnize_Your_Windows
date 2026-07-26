# 开发与测试指南

> [返回项目首页](../README.md) · [文档索引](./README.md)

测试应从仓库根目录运行。所有测试套件均使用临时或隔离数据，不会修改真实下载目录、浏览器缓存或 Codex 数据。

## 前置条件

- Windows 10/11 用于三个 Windows 子项目的完整验证。
- PowerShell 7 用于日常开发；Windows PowerShell 5.1 用于兼容性验证。
- Python 3.11+ 用于 Folder Organizer。
- Linux 与 Python 3.10+ 用于 Linux Codex 单任务迁移。
- Git 工作区应在测试前后保持干净。

## Folder Organizer

```powershell
Push-Location .\folder-organizer
python -m pip install -e .
python -m unittest discover -s tests -v
Pop-Location
```

该项目使用 `src` 布局；全新 checkout 若未先做 editable install，直接运行 `unittest` 会因找不到 `download_curator` 而失败。

当前测试覆盖计划/应用/撤销、过期计划拒绝、哈希缓存、重复文件、文档隐私计划以及增量 FTS 索引。

## Windows Cache Mover

PowerShell 7：

```powershell
.\windows-cache-mover\tests\Invoke-SmokeTest.ps1
```

Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\windows-cache-mover\tests\Invoke-SmokeTest.ps1
```

成功结果应包含 `Passed = True`，并覆盖目录复制、Junction 建立、验证和复制回滚。

## Codex Mover

PowerShell 7：

```powershell
.\codex-mover\tests\Invoke-StaticChecks.ps1
```

Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\codex-mover\tests\Invoke-StaticChecks.ps1
```

测试会解析 PowerShell 文件、编译 Win32 C# 辅助器、检查机器专用标识、验证 Robocopy union/mirror 行为，并确认删除逻辑不会跟随 Junction。测试还会强制 AppX `keep_system_volume` 策略，禁止 AppX 迁移命令重新进入 Codex Mover，并检查 SSH task 的 Windows 路由修复器是否覆盖 assignment、workspace、sidebar、备份与 Desktop 进程保护。PowerShell 7 还覆盖超长路径场景。

## Linux Codex 单任务迁移

在 Linux 上运行：

```bash
python3 -m unittest discover \
  -s codex-mover/linux-session-mover/tests \
  -v
```

测试覆盖：

- dry run 不建立 lock、备份、目标 rollout、SQLite row 或索引。
- active 与 archived 两种 rollout 布局。
- 目标 `sessions` 为外置数据盘 symlink 时，SQLite 仍保存逻辑 `CODEX_HOME` 路径。
- 同时更新 SQLite cwd 和 rollout 结构化 cwd，但不替换历史消息中的旧路径文本。
- 支持同一大型 rollout 中的多条 `session_meta`，并可同时对齐 SQLite 与全部结构化 `model_provider`，不替换历史文本。
- 目标冲突默认拒绝、源 rollout 保留、失败后回滚、备份 manifest 和 SQLite schema 差异处理。

测试只创建临时 home、SQLite 和伪造 JSONL，不读取当前用户的 `~/.codex`。

## 提交前检查

```powershell
# 确认没有空白错误。
git diff --check

# 确认测试没有留下运行时文件。
git status --short

# 列出 Markdown，供链接检查。
rg --files -g '*.md'
```

文档中的相对链接应在 GitHub 上从所在文件位置正确解析。示例路径应使用占位盘符或明确说明的演示目录，不应包含真实凭据、SID、任务 UUID 或私有 token。
