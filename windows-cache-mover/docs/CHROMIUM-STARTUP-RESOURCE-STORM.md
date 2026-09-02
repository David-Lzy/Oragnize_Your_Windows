# Chromium 启动资源风暴排查

> [返回 Windows Cache Mover](../README.md) · [共享安全指南](../../docs/SAFETY.md)

本流程用于区分两类表面相似的问题：迁移后的浏览器路径或目标介质异常，以及扩展在大规模会话恢复时触发的事件放大。所有内置检查默认只读。

## 典型信号

- 浏览器崩溃后只打开一个提示页时稳定，点击“恢复”并开始渲染大量标签后才退出。
- Chrome 随后把一个或多个扩展标为“可能已损坏”。这个状态可能是崩溃后的保护性禁用，并不等于磁盘文件已经缺失。
- 浏览器主进程的句柄或私有内存在数秒内持续陡升；普通单页、单扩展进程占用并不能解释总量。

仅凭时间上发生在缓存迁移之后，不能把迁移当作直接原因。应当同时检查主进程资源趋势和句柄实际指向的路径。

## 1. 扫描高风险扩展代码形态

退出浏览器不是扫描的硬性要求，但退出后结果更稳定：

```powershell
.\scripts\Get-ChromiumExtensionRiskReport.ps1 `
    -Browser Chrome `
    -JsonPath '.\extension-risk.json'
```

当前规则 `TabUpdateGlobalFanOut` 只在同一 JavaScript 文件不超过 4,096 个字符的局部窗口中同时发现以下信号时报告：

1. 注册 `tabs.onUpdated` 监听器。
2. 使用空查询 `tabs.query({})` 获取全部标签。
3. 调用 `action.setIcon`、`browserAction.setIcon` 或 `scripting.executeScript`。

当一次标签更新导致遍历全部标签时，大规模恢复会产生事件乘法；每个标签又读图标或注入脚本时，主进程可能快速积累文件和 Section 句柄。局部窗口排除了这些 API 分散在大型打包文件不同模块中的多数误报，但没有完成 JavaScript 数据流证明；报告因此标为 `Review` / `Heuristic`，仍必须与现场指标做对照。

## 2. 监控一次真实会话恢复

先完全退出目标浏览器并运行：

```powershell
.\scripts\Test-BrowserStartupHealth.ps1 `
    -Browser Chrome `
    -WaitForStartSeconds 300 `
    -MonitorSeconds 120 `
    -JsonPath '.\chrome-startup-health.json'
```

随后启动 Chrome 并恢复原会话。脚本监控浏览器主进程，不读取标签内容、Cookie、历史记录或页面数据，也不会自动结束进程。

默认阈值是主进程连续 3 个样本达到以下任一条件：

- 句柄数至少 12,000；
- 私有内存至少 2,048 MB。

阈值用于快速发现数量级异常，而不是通用性能基准。大型会话可以通过参数调整，但比较“启用嫌疑扩展”和“禁用嫌疑扩展”两次完全相同的恢复流程更有诊断价值。

## 3. 捕获句柄来源

进程指标只能证明资源风暴，不能说明资源来自哪里。发生 `ResourceStorm` 时，可使用 Microsoft Sysinternals Handle 对主进程做只读快照：

```powershell
handle64.exe -accepteula -nobanner -a -vt -p <main-browser-pid> > .\chrome-handles.tsv
```

Handle 应从 [Microsoft Sysinternals 官方页面](https://learn.microsoft.com/sysinternals/downloads/handle) 获取；本仓库不捆绑该二进制文件。

重点检查重复出现的完整路径：

- 大量指向 `User Data\<profile>\Extensions\<extension-id>\...` 的图标或脚本文件，支持“扩展事件放大”。
- 大量指向已迁移 `Cache`、`Code Cache`、`GPUCache` 或 `Service Worker` Junction 目标，才支持继续调查迁移路径、介质延迟或目标离线。
- 少量指向迁移目录的句柄不能解释数万句柄风暴，不应仅凭存在关系判定因果。

句柄快照可能包含本机用户名和路径。提交到公开 issue 前先脱敏。

## 4. 做可证伪的对照重启

1. 保留崩溃转储、启动健康 JSON、句柄快照和扩展风险报告。
2. 在 `chrome://extensions` 手动禁用风险报告与句柄来源共同指向的扩展。
3. 如果 Chrome 显示“可能已损坏”，先不要点击“修复”；修复可能重新安装并重新启用同一问题版本。
4. 完全退出 Chrome，使用相同会话和同一套监控参数再次恢复。
5. 只有在主进程峰值明显回落且不再崩溃时，才把该扩展列为直接原因。若仍然异常，继续检查其他扩展、驱动、注入模块和实际迁移路径。

禁用扩展不会修复它的源代码，但可以阻止同一事件放大再次运行。最终可选择移除扩展、等待上游更新，或在隔离测试资料中验证新版本。
