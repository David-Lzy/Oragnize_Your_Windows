# 文档索引

> [返回项目首页](../README.md)

## 共享文档

| 文档 | 内容 |
| --- | --- |
| [安全指南](./SAFETY.md) | 风险分级、操作前检查、Junction、备份、恢复与秘密边界 |
| [测试指南](./TESTING.md) | 三个子项目的测试命令、兼容性宿主和预期结果 |

## 子项目文档

- [Folder Organizer](../folder-organizer/README.md)：配置、计划、应用、文档分类、索引和撤销。
- [Windows Cache Mover](../windows-cache-mover/README.md)：支持的缓存、审计、迁移、验证和恢复。
- [Codex Mover](../codex-mover/README.md)：Codex 活跃任务保护、UAC 收尾、数据迁移、AppX 位置保护和备份清理。
- [Codex Mover 故障排查](../codex-mover/docs/TROUBLESHOOTING.md)：SpaceSniffer、Robocopy、UAC、AppX 和长路径问题。
- [Codex AppX 插件事故记录](../codex-mover/docs/APPX-PLUGIN-INCIDENT.md)：跨盘 AppX 如何导致 bundled plugin staging 与 Chrome app-server 清单失效，以及项目采用的防复发规则。

## 阅读顺序

1. 从根 [README](../README.md) 选择正确的子项目。
2. 阅读 [安全指南](./SAFETY.md)，确认目标目录、运行进程、空间和恢复条件。
3. 阅读子项目 README，先执行盘点或预览。
4. 按 [测试指南](./TESTING.md) 验证当前 checkout。
5. 只有在预览和恢复路径明确后才执行写操作。
