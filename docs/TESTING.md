# 开发与测试指南

> [返回项目首页](../README.md) · [文档索引](./README.md)

测试应从仓库根目录运行。三个测试套件均使用临时或隔离数据，不会修改真实下载目录、浏览器缓存或 Codex 数据。

## 前置条件

- Windows 10/11。
- PowerShell 7 用于日常开发；Windows PowerShell 5.1 用于兼容性验证。
- Python 3.11+ 用于 Folder Organizer。
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
