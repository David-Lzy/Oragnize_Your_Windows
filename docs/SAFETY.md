# 共享安全指南

> [返回项目首页](../README.md) · [文档索引](./README.md)

本仓库中的工具会处理真实文件、目录联接、环境变量或 Windows 应用数据。它们不是通用清理器；安全性依赖于选择正确的子项目、先完成预览，并保持目标盘和恢复材料可用。

## 风险分级

| 级别 | 示例 | 是否写入 | 执行前要求 |
| --- | --- | --- | --- |
| 只读 | 报告、扫描、计划、验证、搜索 | 否 | 确认扫描范围即可 |
| 可恢复写操作 | Folder Organizer `apply`、Cache Mover `-Apply`、Codex 目录切换 | 是 | 审阅计划/清单、确认空间、保留 rollback 或备份 |
| 不可逆或高风险 | `-DiscardExisting`、Codex 备份清理、sidecar 用户删除 | 是 | 已独立验收目标、理解丢失内容、明确授权 |

`-WhatIf`、预览或计划不是备份。真正的恢复能力来自 rollback manifest、迁移状态文件以及仍然保留的源数据。

## 通用操作前检查

- 确认命令所在的子项目和当前工作目录。
- 使用绝对目标路径，并确认盘符对应预期的本机 NTFS 卷。
- 检查目标盘剩余空间；迁移中通常需要同时容纳源副本和目标副本。
- 关闭会写入目标数据的应用。Codex Mover 是例外：预复制可在运行中进行，但最终同步前必须完全退出 Codex。
- 先保存盘点、计划或预览输出，确认源、目标和预计大小。
- 找到恢复命令、rollback manifest 或迁移状态文件后，再执行写操作。
- 不要在多个终端中同时对同一个源目录运行迁移、应用或恢复。
- 目标盘是外置盘时，确认它不会在使用期间休眠、离线或改变盘符。

## Junction 与磁盘占用

Windows Junction/ReparsePoint 让原路径继续可用，但数据物理上位于另一个目录。部分磁盘分析工具会跟随 Junction，把目标盘大小重复显示在 C 盘目录树中。

验证时应同时检查：

1. 原路径的 `LinkType` 与 `Target`。
2. 目标路径是否真实存在。
3. 清单、状态文件、哈希或文件 ID 是否一致。
4. 源盘与目标盘可用空间的实际变化。

不要用普通递归删除命令清理来源不明的 Junction。它可能进入目标目录并删除真实数据。

## 项目边界

### Folder Organizer

- `plan`、`document-plan`、`index` 和 `search` 不应移动受管目录中的文件。
- `apply` 必须使用经过审阅且仍然匹配当前目录快照的计划。
- 工具不删除文件；重复项和旧安装包移动到配置的 `Archive`。
- 自动移动限制在配置根目录中的散落文件，不拆散嵌套项目或软件包目录。
- 外部 LLM 只能返回 allowlist 内的分类决策，不能直接移动文件。
- 保留 `reports/<run-id>/rollback.json`，直到结果经人工确认。

### Windows Cache Mover

- 只处理目录清单中明确列出的可重建缓存，不处理整个 `AppData` 或系统目录。
- 正式迁移前退出相关浏览器；脚本检测到运行进程时会中止。
- 不带 `-Apply` 时只预览。
- `-DiscardExisting` 会放弃当前缓存内容，只应在确认缓存可重建时使用。
- 保留目标盘 `.cache-mover` 中的 JSON manifest；验证通过前不要手工移除原 Junction 或目标目录。
- 开发工具缓存迁移会更新用户环境变量，已打开的终端和 IDE 需要重启。

### Codex Mover

- 活跃任务依赖 JSONL、SQLite/WAL、认证和全局状态；不要在 Codex 运行时手工移动 `.codex`。
- 从当前 Codex 任务内发起迁移时，显式传入 `-CurrentThreadId`。
- UAC 收尾器会等待 Codex 核心进程退出，执行最终同步、哈希校验和原子目录切换。
- 原 C 盘目录先改名为备份，再建立 Junction；运行验收脚本前不要删除备份。
- OpenAI.Codex AppX/MSIX 程序包必须直接保留在 Windows 系统盘。迁移器检测到包根 ReparsePoint 或非系统卷位置时会停止；不要用 `Move-AppxPackage`、自建 AppX volume 或手工 Junction 绕过检查。
- 只验证 AppX 文件存在、Junction 目标或可执行文件 ID 不足以证明插件健康；跨盘受保护资源可能在 bundled plugin staging 阶段才失败。
- 单个 SSH task 的内部迁移必须备份源/目标 SQLite、session index 和 rollout；目标 Host 完成真实 `thread/read`、`thread/resume`、写入一轮并重启复验前，不移除源记录。
- 修复 `.codex-global-state.json` 前必须退出所有 Windows Session 中的 Codex Desktop。运行中的 Electron 会把旧 Host/project 路由写回文件。
- `Repair-CodexRemoteThreadRoute.ps1` 只修 Windows 路由，不会移动或恢复远端 rollout；默认预览，确认目标 remote project 后才使用 `-Apply`。
- `Remove-CodexSidecarUser.ps1` 删除的是独立 Windows 账户，不是普通 `.codex` 文件夹；它要求精确 SID，并且不会创建备份。

### Linux Codex 单任务迁移

- `state_5.sqlite`、`threads`、rollout JSONL 和 `session_index.jsonl` 是当前实测的内部布局，不是公开稳定迁移 API；Codex 升级后先在临时 `CODEX_HOME` 验证。
- 不带 `--apply` 时只能生成计划；正式写入还要求 `--confirm-codex-stopped`，并会再次检查源/目标 Codex 进程。
- 不要在正被迁移的 task 内执行 apply。使用独立 SSH/终端，断开 Desktop 连接并停止两端 app-server 后再写入。
- 目标 SQLite 的 `rollout_path` 必须保留在目标逻辑 `CODEX_HOME/sessions/...` 或 `CODEX_HOME/archived_sessions/...` 下；不要写入 symlink 解析后的物理数据盘路径。
- 项目路径变化时，只改 SQLite cwd 不够；应只改 rollout 中 `session_meta` / `turn_context` 的结构化 cwd，不替换历史消息里的文本。
- Provider 内部名称变化时，必须同时对齐 SQLite `threads.model_provider` 和所有 `session_meta.payload.model_provider`；名称按目标端原生 task 的实际值及大小写传入。
- 大型 rollout 可以包含多条同 ID `session_meta`；应逐条验证和改写，不能假定全文件只有一条。
- 默认保留源 task；不要在目标成功 resume、产生新一轮记录并重启复验前清理源 rollout 或迁移备份。
- 同一 task 的源/目标副本迁移后会独立增长，不存在自动合并；不要同时从两套 `CODEX_HOME` 继续写同一 ID。
- 两套隔离 `CODEX_HOME` 不应通过 symlink 共用同一个 task rollout；脚本检测到源/目标为同一物理文件时会停止。
- `sessions` 和 `archived_sessions` 应位于同一文件系统，否则 archive/unarchive 的 rename 可能触发 `EXDEV`。
- 只允许 `sessions` / `archived_sessions` 根目录本身指向数据盘；年月日子目录中的嵌套 symlink、symlink rollout 和 symlink session index 会被拒绝。
- 迁移脚本不会复制 `auth.json` 或 API Key；目标 task 使用目标 `CODEX_HOME` 当前认证。

## 凭据与外部模型

- 不要把 `auth.json`、浏览器资料、token、Cookie 或带秘密的本机配置提交到仓库。
- Codex Mover 会将 `auth.json` 作为不透明状态文件复制到目标盘，但不应读取或打印其中内容。
- Folder Organizer 的文档预览、文件名和元数据都是不可信分类输入。外部模型必须忽略其中的指令，只能输出约定格式的受限决策。
- 提交问题报告前，检查日志和 JSON 是否包含用户名、内部路径、任务 ID 或其他不希望公开的信息。

## 恢复顺序

发生错误时不要立即删除源或目标。按以下顺序处理：

1. 停止新的写操作，退出相关应用。
2. 保存当前错误、日志、manifest 和状态 JSON。
3. 运行子项目提供的只读验证。
4. 若验证表明切换不完整，优先使用项目提供的 undo/restore/rollback 流程。
5. 只有在恢复材料和目标都确认无用时，才进行手工清理。

如需报告问题，请提供工具版本或提交、使用的命令（隐藏秘密）、错误文本、只读报告，以及 manifest/status 中不敏感的路径状态。
