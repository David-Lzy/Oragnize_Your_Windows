# SSH 远程 Session 迁移后的 Windows Desktop 兼容

> [返回 Codex Mover](../README.md) · [Linux 单 task 迁移](../linux-session-mover/) · [故障排查](./TROUBLESHOOTING.md) · [共享安全指南](../../docs/SAFETY.md)

## 结论

把一个 Codex task/session 从 SSH Host A 的 `CODEX_HOME` 移到 Host B 后，**远端数据迁移成功并不等于 Windows Desktop 已经切换成功**。需要分别处理两层状态：

1. **远端真实状态**：rollout JSONL、`state_5.sqlite` 中的 task 索引、`session_index.jsonl`、provider 和工作目录。
2. **Windows 客户端路由**：`.codex-global-state.json` 中 task 对应的 remote project、SSH host、workspace 和侧栏顺序。

本次已修复事故的关键症状是：任务列表已经显示新 SSH Host，但点击后变成“新任务”，同时提示：

```text
no rollout found for thread id <task UUID>
```

历史并未丢失，但故障先后包含两个独立根因：

1. 初次迁移把 SQLite `rollout_path` 写成了软链接解析后的磁盘真实路径；`thread/read` 可以读取，Desktop 的 `thread/resume` 却可能按目标 `CODEX_HOME/sessions` 做归属校验。第二台全新 Windows 也复现，证明这一阶段是服务端兼容问题。
2. 远端改成目标 `$CODEX_HOME/sessions/...` 逻辑路径并重启对应 app-server 后，原 Windows 的持久 assignment 仍可能把点击请求发给旧 Host。仅重启客户端不会重建这份路由；在客户端仍运行时改 JSON，也会被 Electron 内存中的旧值写回。

这里使用的 [Windows 路由修复脚本](../scripts/Repair-CodexRemoteThreadRoute.ps1) 默认只预览，显式传入 `-Apply` 才会写入，并在写入前拒绝所有仍在运行的 Codex Desktop 进程。

## 适用范围与稳定性边界

本文讨论的是：

- 同一台或不同 Linux 服务器上的两个 SSH 连接。
- 每个连接可以指向不同的 `CODEX_HOME`、认证或 provider。
- 保留原 task UUID、标题和完整历史。
- 迁移后继续从 Windows Codex Desktop 打开原任务。

rollout JSONL、`state_5.sqlite` 和 Windows 全局状态都属于 Codex 内部格式，不是稳定的公开迁移 API。操作前应：

- 让源端和目标端使用相同 Codex 版本。
- 备份两边完整 `CODEX_HOME` 或至少 SQLite、session index 和目标 rollout。
- 先复制和校验；目标 Host 完成真实 `thread/resume`、写入一轮并重启复验前，不移除源索引与源文件。
- 若字段或文件名与本文不同，停止写入并重新检查当前版本。

## 两层状态为什么会分离

远端 app-server 用自己的 `CODEX_HOME` 找任务。迁移记录应保留 app-server 认识的逻辑归属：

```text
threads.rollout_path
  -> <目标 CODEX_HOME>/sessions/<年>/<月>/<日>/rollout-...jsonl
  -> sessions 软链接
  -> 大容量磁盘上的真实文件
```

不要在导入时先调用 `realpath`，再把磁盘真实路径写进 `threads.rollout_path`。两条路径可能指向同一 inode，但内部 `resume` 校验不一定把它们视为同一个 `CODEX_HOME` Session。

Windows Desktop 则先根据本地缓存决定请求应发给哪个 SSH 连接和哪个 remote project。

```text
Windows task card
  -> thread-project-assignments[task UUID]
  -> remote project ID + remote-ssh-discovered:<SSH alias>
  -> 目标 SSH app-server / CODEX_HOME
  -> state_5.sqlite 中的 threads 行
  -> rollout JSONL
```

因此可能出现两类不一致：

- 目标 SQLite 使用物理 realpath：列表/`thread/read` 成功，但 `thread/resume` 认为 rollout 不属于目标 `CODEX_HOME`。
- 全局任务列表从目标 app-server 发现任务，但本地 `thread-project-assignments` 仍指向旧 Host；点击时旧 app-server 返回 `no rollout found`。

这也解释了为什么“任务看得见”不能证明“任务能继续”。

## 推荐迁移顺序

### 1. 先完成 Linux 远端迁移

优先使用仓库内默认 dry-run 的 [Linux Codex 单任务迁移器](../linux-session-mover/)，不要再把现场一次性修复命令散落成无校验脚本。停止会写入该任务的源/目标 app-server 后，再处理下列内容：

1. 用 SQLite backup API 备份源、目标 `state_5.sqlite`，不要只复制正在使用的主文件而漏掉 WAL。
2. 找到 task UUID 对应的 rollout JSONL，复制到目标 `sessions` 存储。
3. 用 SHA-256 校验源、目标文件；超大 JSONL 应流式读取，不能一次性载入内存。
4. 把源 `threads` 行导入目标数据库，并按目标环境修正：
   - `rollout_path`：目标 `$CODEX_HOME/sessions/...` 下的**逻辑绝对路径**，即使 `sessions` 本身是指向大容量磁盘的软链接。
   - `model_provider`：目标配置中的 provider 名称，包含大小写。
   - `cwd`：目标 SSH project 的真实工作目录。
5. 若 rollout 的 session/turn metadata 也保存旧 provider 或旧 `cwd`，只在**目标副本**中逐行解析并修改对应字段；大型 task 可能有多条同 ID `session_meta`，必须处理全部记录。不要对数 GB 文件做无边界全文替换，以免改到用户消息或工具输出。
6. 检查当前数据库中所有以 task UUID 为键的表。`thread_dynamic_tools` 等依赖行可能需要迁移；若 `thread_spawn_edges` 显示父/子 task，则应迁移整棵依赖树或明确拒绝单 task 迁移。
7. 若当前版本使用 `session_index.jsonl`，同步标题索引并避免重复 task UUID；同时检查 rollout 引用的 attachment 是否仍可从目标 `CODEX_HOME` 访问。
8. 执行 `PRAGMA quick_check`，重启**目标 `CODEX_HOME` 对应的** app-server，再从目标 Host 实际执行 `thread/read` 和 `thread/resume`。同机多账户时不要误杀其他 app-server。
9. 暂时保留源数据库行和源 rollout。只有 Windows Desktop 已从目标 Host 完成真实 `thread/resume` 并写入一轮后，才清理源端。

如果 `sessions` 使用软链接承载大文件，`archived_sessions` 也应落在同一文件系统。Codex 归档任务可能使用原子 rename；两者跨文件系统会报 `Cross-device link`。

### 2. 让 Windows 先认识目标 remote project

在 Desktop 中连接目标 SSH alias，并打开一次目标 project 路径。这样 Windows 状态中的 `remote-projects` 会生成真实 project ID。

不要手工编造 project ID。即使两条 SSH 配置最终连接同一台机器、使用同一路径，只要 alias 或 `CODEX_HOME` 不同，它们就是两个不同的 Desktop Host：

```text
remote-ssh-discovered:<SSH alias>
```

### 3. 完全退出所有 Desktop 实例

在外部 `pwsh` 窗口中检查：

```powershell
Get-Process -Name ChatGPT -ErrorAction SilentlyContinue |
    Select-Object Id, ProcessName, SessionId, StartTime
```

必须关闭所有结果，包括其他 RDP/Windows 登录 Session 中的窗口。多个 GUI Session 可以共享同一份 `.codex-global-state.json`；只关闭当前桌面上的窗口，另一个 Electron 进程仍可能把旧路由写回来。

### 4. 先预览，再修复 Windows 路由

默认从 `$env:CODEX_HOME\.codex-global-state.json` 读取；若未设置 `CODEX_HOME`，则使用 `%USERPROFILE%\.codex\.codex-global-state.json`。自定义存储位置应显式传 `-StatePath`。

```powershell
# 只读预览。
.\scripts\Repair-CodexRemoteThreadRoute.ps1 `
    -ThreadId '<task UUID>' `
    -TargetHost '<目标 SSH alias>' `
    -TargetRemotePath '/srv/projects/personal' `
    -StatePath 'E:\CodexData\home\.codex-global-state.json'

# 确认预览中的目标 host/project/path 后才写入。
.\scripts\Repair-CodexRemoteThreadRoute.ps1 `
    -ThreadId '<task UUID>' `
    -TargetHost '<目标 SSH alias>' `
    -TargetRemotePath '/srv/projects/personal' `
    -StatePath 'E:\CodexData\home\.codex-global-state.json' `
    -Apply
```

脚本会根据 host + remote path 查找已有 `remote-projects` 记录，然后一致更新：

- `thread-project-assignments[task UUID]`
- `electron-persisted-atom-state["thread-workspace-state-v1:<task UUID>"]`
- `sidebar-project-thread-orders`
- 已存在的 `thread-writable-roots[task UUID]`
- `projectless-thread-ids`

如果相同 host/path 有多个 project，脚本会停止并列出 ID；人工确认后用 `-TargetProjectId` 消除歧义。

写入前，脚本会把主状态和已有 `.bak` 复制到：

```text
<CODEX_HOME>\.route-fix-backups\<task UUID>-<UTC timestamp>\
```

随后使用临时文件原子替换主状态和 `.bak`，再重新解析并验证目标 assignment、workspace 与 sidebar。

### 5. 启动并做端到端验收

重新启动 Desktop 后，不要只看侧栏位置。至少确认：

1. task 卡片的 Host 是目标 SSH alias。
2. 打开后出现原历史，而不是空白“新任务”。
3. `thread/read` 和 `thread/resume` 都发往目标 app-server。
4. 可以新增一条测试消息，并写入目标 rollout。
5. 目标 `state_5.sqlite` 仍为 `PRAGMA quick_check = ok`。
6. rollout 大小/修改时间只在目标存储增长。
7. 完成以上验收后，备份并移除源 `threads` 行、session index 和 rollout；再次确认目标仍可打开。

若能读取历史但不能继续，重点检查目标 `model_provider`、认证和 `cwd`，而不是再次复制 rollout。

## 这次修复踩到的坑

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 列表属于新 Host，点击却 `no rollout found` | 卡片发现来源与本地点击路由不一致 | 修复 Windows assignment/workspace/sidebar，并验证请求实际到达目标 Host |
| 重启 Desktop 后仍不变 | 错误 assignment 已持久化，重启只会重新加载它 | 完全退出后运行路由脚本 |
| JSON 改完马上恢复旧值 | 仍有 Electron renderer 持有旧状态 | 关闭所有 Windows Session 中的 Desktop 进程后再改 |
| 换一台全新 Windows 电脑也失败 | 优先怀疑服务端；本次是 `rollout_path` 使用磁盘 realpath，未使用目标 `$CODEX_HOME/sessions` 逻辑路径 | 对比同一目标账户的原生 task，修正逻辑路径并重启对应 app-server |
| 历史可见，继续对话走错 Key/API | 只复制了源 `model_provider` | 把目标 `threads.model_provider` 改成目标配置中的精确 provider 名称 |
| `thread/read` 成功但 `thread/resume` 失败 | 最常见是 `rollout_path` 不属于目标 `$CODEX_HOME/sessions`；也可能是 `cwd`、provider 或 app-server 环境不一致 | 先把导入路径改成目标逻辑 Session 路径，再核对进程 `CODEX_HOME`、provider 与 `cwd` |
| SQLite 显示缺行或回滚 | 在 app-server 写入期间直接复制主数据库，漏了 WAL | 停止写入并使用 SQLite backup API |
| 归档时报 `Cross-device link` | `sessions` 与 `archived_sessions` 位于不同文件系统 | 把二者放到同一物理文件系统 |
| 大任务处理时内存暴涨 | 一次性读取数 GB JSONL | 逐行解析/复制，临时文件完成后再原子替换 |
| 任务突然跑到全局顶部 | 它仍处于 pinned 状态 | pin 是全局展示状态，不代表 Host 迁移失败 |
| 同一服务器上请求到了错误账户 | 把多个 app-server/proxy 进程当成同一实例 | 从 `/proc/<pid>/environ` 核对每个进程的 `CODEX_HOME` |

## 只读核对代码

远端没有 `sqlite3` CLI 时，可以通过 SSH 把 Python 代码送入标准输入，避免复杂的多层引号：

```powershell
$remoteAudit = @'
import json
import os
import sqlite3
from pathlib import Path

thread_id = "<task UUID>"
home = Path(os.environ["CODEX_HOME"])
database = home / "state_5.sqlite"
connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
connection.row_factory = sqlite3.Row
row = connection.execute(
    """
    SELECT id, rollout_path, model_provider, cwd, archived
    FROM threads
    WHERE id = ?
    """,
    (thread_id,),
).fetchone()

result = {
    "codex_home": str(home),
    "thread": dict(row) if row else None,
    "rollout_exists": bool(row and Path(row["rollout_path"]).is_file()),
    "rollout_realpath": str(Path(row["rollout_path"]).resolve()) if row else None,
    "quick_check": connection.execute("PRAGMA quick_check").fetchone()[0],
}
print(json.dumps(result, ensure_ascii=False, indent=2))
'@

$remoteAudit |
    ssh -o BatchMode=yes '<目标 SSH alias>' python3 -
```

核对目标 app-server 的进程归属：

```bash
for process in /proc/[0-9]*; do
    if tr '\0' '\n' < "$process/environ" 2>/dev/null |
        grep -q '^CODEX_HOME='; then
        printf 'PID=%s ' "${process##*/}"
        tr '\0' '\n' < "$process/environ" 2>/dev/null |
            grep '^CODEX_HOME='
    fi
done
```

这些命令只读取环境和 SQLite，不打印 `auth.json`，也不应把 API key、内部 endpoint 或真实 task UUID提交到问题报告。

## 恢复

如果路由修复后 Desktop 行为变差：

1. 再次完全退出所有 Desktop 进程。
2. 找到脚本输出的 `.route-fix-backups` 目录。
3. 保存当前失败状态用于比对。
4. 把备份的 `.codex-global-state.json` 和 `.bak` 恢复到原位置。
5. 重新启动 Desktop。

恢复 Windows 路由不会恢复或删除远端 rollout；远端迁移应使用它自己的 SQLite 和 session 备份单独回滚。
