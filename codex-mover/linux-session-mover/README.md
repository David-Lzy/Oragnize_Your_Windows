# Linux Codex 单任务迁移

> [返回 Codex Mover](../README.md) · [共享安全指南](../../docs/SAFETY.md) · [测试指南](../../docs/TESTING.md)

在 Linux 主机上，把一个 Codex task 从一个 `CODEX_HOME` 复制到另一个 `CODEX_HOME`，保留原 task ID、完整 JSONL 历史、标题/预览和项目路径。典型用途包括：

- 同一台服务器上，从默认 `~/.codex` 迁到某个独立 API Key 使用的 `CODEX_HOME`。
- SSH 连接改用另一套 `CODEX_HOME` 后，让旧 task 在该远程连接中继续可见。
- `sessions` 已放在项目盘或大容量磁盘时，修复“侧栏能看到，但打开后提示 `no rollout found`”的问题。

脚本只迁移 task，不复制 `auth.json`、`config.toml`、API Key、插件或日志。迁移后继续 task 时，实际使用的是**目标 `CODEX_HOME` 当前配置的认证和模型提供方**。

## 支持边界

OpenAI 当前文档明确说明，`CODEX_HOME` 是 Codex 配置、认证、日志、sessions、skills 等状态的根目录；`CODEX_SQLITE_HOME` 可以单独指定 SQLite 状态位置。参见 [Codex 环境变量](https://learn.chatgpt.com/docs/config-file/environment-variables) 和 [配置及状态位置](https://learn.chatgpt.com/docs/config-file/config-advanced#config-and-state-locations)。

但官方文档没有承诺 `state_5.sqlite`、`threads` 表、rollout JSONL 或 `session_index.jsonl` 是稳定的迁移 API。本工具基于当前 Linux Codex 的实测布局，属于**带防护的兼容性迁移**：

- 默认只生成计划，不写入。
- 写入前验证 SQLite、task ID、rollout 首记录和目标冲突。
- 流式校验每一条 JSONL，不把大型 rollout 整体载入内存。
- 写入前备份目标 SQLite、索引和将被替换的 rollout。
- 失败时自动尝试恢复目标。
- 如果未来 Codex 改变文件名或必要字段，脚本优先停止，而不是猜测新格式。

当前实机 dry run 和 schema 对照使用 `codex-cli 0.145.0`（2026-07-26）；隔离测试不依赖真实用户数据。

升级 Codex 后，先在测试 `CODEX_HOME` 上运行本项目测试和 dry run，再迁移重要 task。

## 为什么不能只复制 JSONL

当前一个可继续的本地 task 至少涉及三层状态：

| 层 | 当前作用 | 漏迁时的常见表现 |
| --- | --- | --- |
| `sessions/.../rollout-...-<task-id>.jsonl` | 完整消息、工具调用、`session_meta` 和每轮 `turn_context` | 打开时报 `no rollout found` |
| `state_5.sqlite` 的 `threads` 行 | task 发现、目标 rollout、cwd、标题、预览、归档状态和排序信息 | 文件存在，但侧栏不出现或无法 resume |
| `session_index.jsonl` | task 名称索引及旧版本兼容状态 | 名称丢失、旧客户端列表不一致 |

Desktop 显示在哪个 SSH 主机下，最终由它连接的远程 app-server 和该进程的 `CODEX_HOME` 决定；它不是单靠 JSONL 内一个“host 名称”字段决定的。

本工具采用“**先复制，后验证，源端保留**”的方法：

1. 从源 SQLite 读取指定 task 的完整 `threads` 行。
2. 找到并逐行验证对应 rollout。
3. 将 rollout 放入目标 `CODEX_HOME` 的 active 或 archived 布局。
4. 动态复制源/目标 SQLite 共同字段，并保留目标新增字段的默认值。
5. 更新目标 `session_index.jsonl`。
6. 再检查目标 SQLite、逻辑 rollout 路径、首条 `session_meta` 和索引唯一性。

源端不会自动删除。目标稳定继续使用后，再由人工决定是否保留旧副本。

## 最重要的路径规则

假设目标使用：

```text
CODEX_HOME=/home/<user>/.codex-accounts/personal
```

而它的 `sessions` 是指向数据盘的 symlink：

```text
/home/<user>/.codex-accounts/personal/sessions
  -> /mnt/data/codex/personal/sessions
```

SQLite 的 `rollout_path` 必须保存前者下面的**逻辑路径**：

```text
/home/<user>/.codex-accounts/personal/sessions/2026/07/26/rollout-...jsonl
```

不要把 `readlink -f` 得到的物理路径写入 `threads.rollout_path`。我们实测遇到过物理文件存在、task 短暂出现在侧栏、随后 resume 仍报 `no rollout found`；同一目标下由 Codex 原生创建的 task 使用的是逻辑 `CODEX_HOME/sessions/...` 路径。

本项目的脚本会展示逻辑路径与物理路径，但只把逻辑路径写入 SQLite。测试也专门锁定了这一行为。

## 要求

- Linux。
- Python 3.10 或更新版本；只使用标准库。
- 源和目标 `CODEX_HOME` 已存在。
- 源和目标当前使用的 SQLite 数据库可读写；默认名称为 `state_5.sqlite`。
- 目标 rollout 文件系统至少能容纳一份临时副本；backup root 还要能容纳目标 SQLite/index 备份，使用 `--replace-existing` 时还包括旧 rollout。
- apply 时，使用这两个 `CODEX_HOME` 的 Codex CLI、Desktop 远程 app-server 和相关 task 都已停止。

如果配置了 `CODEX_SQLITE_HOME` 或 `sqlite_home`，请用 `--source-database` / `--target-database` 明确传入真实数据库。脚本不会猜测外置 SQLite 位置。

## 推荐流程

以下命令从仓库根目录运行。先设置仅用于本次操作的变量；不要把 task ID、内部路径或认证文件提交到仓库。

```bash
codex_source_home="$HOME/.codex"
codex_target_home="$HOME/.codex-accounts/personal"
codex_thread_id="<task-uuid>"
codex_destination_cwd="/mnt/data/Personal_Project"
codex_backup_root="/mnt/data/Personal_Project/.codex-storage/personal/migration-backups"
```

先确认目标目录权限：

```bash
test -d "$codex_source_home"
test -d "$codex_target_home"
chmod 700 "$codex_target_home"
```

### 1. 只读预览

```bash
python3 codex-mover/linux-session-mover/scripts/migrate_codex_session.py \
  --source-home "$codex_source_home" \
  --target-home "$codex_target_home" \
  --thread-id "$codex_thread_id" \
  --destination-cwd "$codex_destination_cwd" \
  --backup-root "$codex_backup_root"
```

不带 `--apply` 时不会建立 lock、目录、备份或目标索引。请检查输出中的：

- 源、目标 `CODEX_HOME` 和 SQLite 是否正确。
- source rollout 是否正是该 task。
- target logical rollout 是否位于目标 `CODEX_HOME` 下。
- backup root 和脚本估算的各文件系统剩余空间是否合适。
- destination cwd 是否是新项目路径。
- 目标是否已有同 ID 的 row/file。
- 是否仍检测到使用任一 `CODEX_HOME` 的 Codex 进程。
- `sessions` 与 `archived_sessions` 是否位于同一文件系统。

如果项目没有移动，省略 `--destination-cwd`，脚本会保留原 cwd。

### 2. 完全停止两端 Codex

不要从“正被迁移的 task 本身”执行 apply。应使用另一个 SSH/终端窗口：

1. 断开对应的 Desktop SSH 连接并退出相关 CLI。
2. 查看候选进程。
3. 对每个 PID 只检查 `CODEX_HOME`，不要打印整份进程环境。
4. 确认没有活跃 task 后，优先正常停止 app-server 或其 systemd user service。

示例检查：

```bash
pgrep -u "$USER" -f 'codex|app-server'

codex_pid="<exact-pid>"
ps -o pid=,comm= -p "$codex_pid"
tr '\0' '\n' < "/proc/$codex_pid/environ" |
  sed -n '/^CODEX_HOME=/p'
```

如果需要手工停止，只对已经核实的精确 PID 发送 `TERM`：

```bash
kill -TERM "$codex_pid"
```

不要使用宽泛的 `pkill -9 codex`；它可能同时终止其他 `CODEX_HOME` 的活跃任务。若 `TERM` 后进程不退出，先检查它的子进程、服务管理器和仍连接的 Desktop 客户端。

### 3. 显式执行

重新运行同一命令并增加两个写入开关：

```bash
python3 codex-mover/linux-session-mover/scripts/migrate_codex_session.py \
  --source-home "$codex_source_home" \
  --target-home "$codex_target_home" \
  --thread-id "$codex_thread_id" \
  --destination-cwd "$codex_destination_cwd" \
  --backup-root "$codex_backup_root" \
  --apply \
  --confirm-codex-stopped
```

`--backup-root` 可以省略，默认是目标 `CODEX_HOME/migration-backups`。如果 home 分区较小或可能使用 `--replace-existing` 备份大型 rollout，应把它显式放在容量充足的数据盘。

Backup root 必须位于 `sessions` 和 `archived_sessions` 扫描树之外。否则同 ID 的备份 JSONL 可能被当成另一个可恢复 task；脚本会直接拒绝这种布局。

脚本仍会重新检查进程、目标冲突和可用空间。成功后会输出：

```text
BACKUP_ROOT/<UTC>-<task-id>/migration-manifest.json
```

manifest 记录源/目标路径、逻辑与物理 rollout、哈希、改写记录数、SQLite 备份和兼容性信息，不记录 API Key 或 `auth.json` 内容。

### 4. 重启目标 app-server 再打开 task

如果通过 Desktop SSH 连接 Linux，必须让**远程目标 app-server** 重新启动并读取目标数据库。仅重启本地窗口不一定会结束仍由远端进程管理器保留的旧 app-server。

重新连接后，先新建一个无关测试 task，确认它的 `CODEX_HOME` 与认证正确，再打开迁移 task。不要同时从源和目标继续同一个 task；两个副本随后会各自增长，Codex 不会自动合并分叉历史。两套隔离 `CODEX_HOME` 也不应通过 symlink 共用同一个 task rollout；脚本检测到源/目标是同一物理文件时会停止。

## 项目路径也变化时

Task 的 cwd 不只存在于 SQLite，也存在于 rollout 的结构化记录中。只改 `threads.cwd` 可能导致：

- task 被分到错误的项目/文件夹。
- 重启后从侧栏消失。
- 打开时继续使用旧工作目录。

`--destination-cwd` 会同时更新：

- 目标 SQLite 的 `threads.cwd`。
- rollout 第一条 `session_meta.payload.cwd`。
- 所有 `turn_context.payload.cwd`。

它不会在历史用户消息、工具输出或代码片段中做文本替换；测试会确认历史中提到的旧路径保持原样。

大型 rollout 采用逐行流式重写，并在目标目录生成临时文件后原子替换。因此内存占用受单条 JSON 记录大小限制，但磁盘仍需容纳一份临时 rollout。脚本会按文件系统显示保守的额外空间估算并在明显不足时停止。不要直接对 10 GB 级 JSONL 使用编辑器或无备份的全文件替换。

## Sessions 放到项目盘

可以让 `CODEX_HOME` 保留在 home，同时把大文件放到项目盘。为了保证 archive/unarchive 的 rename 不触发 `Invalid cross-device link (EXDEV)`，`sessions` 和 `archived_sessions` 应指向同一文件系统：

```bash
codex_target_home="$HOME/.codex-accounts/personal"
codex_storage_root="/mnt/data/Personal_Project/.codex-storage/personal"

install -d -m 700 \
  "$codex_storage_root/sessions" \
  "$codex_storage_root/archived_sessions" \
  "$codex_storage_root/migration-backups"

# 仅在这两个逻辑路径尚不存在时创建。
test ! -e "$codex_target_home/sessions"
test ! -e "$codex_target_home/archived_sessions"
ln -s "$codex_storage_root/sessions" "$codex_target_home/sessions"
ln -s "$codex_storage_root/archived_sessions" \
  "$codex_target_home/archived_sessions"

stat -c '%d %n' \
  "$codex_target_home/sessions" \
  "$codex_target_home/archived_sessions"
```

如果逻辑目录已经有数据，不要直接删除后换 symlink。先停止 Codex、复制并校验原数据，再做目录切换。

脚本允许 `sessions` / `archived_sessions` 根目录本身是 symlink，但拒绝年月日子目录中的嵌套 symlink，也拒绝 symlink 形式的目标 rollout 或 `session_index.jsonl`，避免写入被悄悄重定向到未知位置。

迁移大 task 时，在 dry run 和 apply 命令中都追加这个参数：

```text
--backup-root "$codex_storage_root/migration-backups"
```

## 多认证与 task 可见性

`CODEX_HOME` 同时决定本地认证状态和 task 状态，所以切换它通常会同时切换“使用哪个 Key”和“能看到哪些 task”。

- 想隔离多个 API Key：为每套认证使用独立 `CODEX_HOME`，并将文件式凭据只保存在对应 home；权限设为 `0700`。
- 想让旧 task 在新 Key 下继续：迁移 task 到新 Key 的 `CODEX_HOME`，不要复制源 `auth.json`。
- 想保持同一批 task、只临时换认证：固定同一个 `CODEX_HOME`，在 Codex 停止时切换该 home 的认证，再重启；这不是本脚本负责的范围。
- 使用 OS keyring 时，凭据位于操作系统凭据存储而非 `CODEX_HOME/auth.json`；不要假设复制目录就完成了认证隔离。

远程 SSH 会话应先验证服务器确实接收到目标 `CODEX_HOME`：

```bash
printf '%s\n' "$CODEX_HOME"
```

如果客户端通过 SSH `SetEnv CODEX_HOME=...` 发送，服务器 OpenSSH 还需要允许 `AcceptEnv CODEX_HOME`。具体 Desktop 路由属于客户端配置层，与本 Linux task 数据迁移分开处理。

## 常见坑

| 表现 | 原因 | 处理 |
| --- | --- | --- |
| 侧栏有 task，打开报 `no rollout found` | 只写了索引；rollout 缺失；或 SQLite 记录了 symlink 的物理路径 | 检查三层状态；确保 `rollout_path` 是目标 `CODEX_HOME` 下的逻辑路径 |
| 重启后 task 消失 | 只复制 JSONL、`preview` 为空、cwd 不属于当前项目，或远端 app-server 仍缓存旧数据库 | 迁移完整 `threads` 行和索引；重启正确的远端 app-server |
| 一开始能看到，过一会被刷新掉 | 客户端初始缓存与远端 app-server 重新加载后的索引不一致 | 以远端目标 SQLite/rollout 为准，停止进程后重新迁移并重启 |
| `Invalid cross-device link` | active 与 archived 根目录在不同文件系统 | 让 `sessions` 与 `archived_sessions` 指向同一数据盘 |
| Task 出现在旧项目下 | 只改 SQLite cwd，或未改 rollout 的结构化 cwd | 使用 `--destination-cwd` |
| 迁移后使用了“错误的 Key” | 认证属于目标 `CODEX_HOME`，不是 rollout | 独立验证目标认证；不要从源复制 `auth.json` |
| SQLite locked / 数据过一会回退 | app-server、CLI 或 WAL 仍在写 | 断开客户端并正常停止两端 Codex，再 apply |
| 目标已有同 ID | 曾经迁移过或两端历史已经分叉 | 默认停止；人工比较后才考虑 `--replace-existing` |
| 升级 Codex 后脚本拒绝 schema | 内部表或布局已变化 | 不要绕过检查；先更新脚本和隔离测试 |

## 冲突与恢复

默认遇到目标同 ID row 或同名 rollout 就停止。`--replace-existing` 会先备份再替换，但它可能覆盖目标端已经增长的分叉历史，只应在人工比较两个 rollout 后使用。

每次 apply 的备份目录至少包含目标 SQLite 快照；如果目标原来有 `session_index.jsonl` 或同名 rollout，也会保留副本。失败时脚本会尝试自动恢复，并把 manifest 标记为：

- `success`
- `failed_rolled_back`
- `failed_rollback_incomplete`

若出现 `failed_rollback_incomplete`：

1. 不要重启 Codex。
2. 保存整个 migration backup 目录。
3. 检查 manifest 的 `rollback_errors`。
4. 在普通文件恢复前，确保目标 app-server 和 CLI 全部停止。
5. 优先用备份 SQLite 做 SQLite backup/restore，不要在 WAL 活跃时直接覆盖主文件。

成功验收前不要删除源 rollout、源 SQLite row 或目标 migration backup。

## 手工验收

脚本成功时已经自动执行这些核心检查。需要独立复核时：

```bash
sqlite3 -readonly "$codex_target_home/state_5.sqlite" 'PRAGMA quick_check;'

sqlite3 -readonly -header "$codex_target_home/state_5.sqlite" \
  "SELECT id, rollout_path, cwd, archived
   FROM threads
   WHERE id = '$codex_thread_id';"
```

确认查询得到的 `rollout_path`：

1. 以目标逻辑 `CODEX_HOME` 开头。
2. 文件确实存在。
3. 首条 JSON 是同 ID 的 `session_meta`。

```bash
codex_rollout="$(
  sqlite3 -readonly "$codex_target_home/state_5.sqlite" \
    "SELECT rollout_path FROM threads WHERE id = '$codex_thread_id';"
)"

test -f "$codex_rollout"
head -n 1 "$codex_rollout" | python3 -m json.tool
```

不要把包含历史消息的 rollout、`auth.json` 或完整 SQLite 上传到公开 issue。

## 代码与测试

- 迁移脚本：[scripts/migrate_codex_session.py](./scripts/migrate_codex_session.py)
- 隔离测试：[tests/test_migrate_codex_session.py](./tests/test_migrate_codex_session.py)

```bash
python3 -m unittest discover \
  -s codex-mover/linux-session-mover/tests \
  -v
```

测试使用临时 `CODEX_HOME`、临时 SQLite 和伪造 rollout，不读取或修改真实 Codex 数据。
