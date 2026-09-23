# 远程低延迟模型对照

2026-09-09，基线 clean b0ea90a。用户要求尝试更快的远程模型。现场设置为 gpt-5.6-terra，既有服务 models 列表返回 200，列有 gpt-5.6-luna 与 4.1-mini。仅使用原服务与原凭据，不打印凭据、不改开关、不重启服务。

## 方法

复用现有 CompletionQualityBenchmark，在临时 main 增加 CPA_PROBE_MODEL 覆盖局部 model 变量；未写生产设置。生产协议、完整 system、过滤、流式客户端和 13 秒截止保持。四条公开合成用例 context-01/context-10/context-23/core-10，每模型两轮，随机种子 90902 混排，24 次尝试全保留。没有新增 reasoning 参数：比较的是当前兼容请求载荷，不是每模型最优调参。接口别名的实际后端映射未独立核实。

| 请求模型 | 决策耗时中位数 | 结果 |
| --- | --- | --- |
| gpt-5.6-terra | 1951 ms | 4 次准确名称续接；2 次缺对象输出被过滤；2 次翻译续接被过滤 |
| gpt-5.6-luna | 2553 ms | 2 次缺对象主动停笔；3 次展示名称续接；1 次名称被过滤；2 次翻译续接被过滤 |
| 4.1-mini | 1525 ms | 8 次均展示；人工检查均存在无依据扩展、冗余约束或不自然续接 |

Mini 决策中位数约减少 22%，但质量不满足当前需求，**不切换**。Luna 本组没有更快，也不切换。未观察到系统失败。这里的耗时包括拒绝决策，不能称为浮层可见延迟或正式 P95；四条公开开发例、每条两轮不能代表整体质量与持续性能。人工检查来自当前代理，非独立盲评。

原始合成数据见 [results.jsonl](../evaluation/results/remote-speed-2026-09-09/results.jsonl)。官方 [GPT-4.1 Mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini)定位低延迟非思考模型；[Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna)定位成本敏感任务，支持 none 思考档，但本轮生产载荷未显式设置，不能当作 none 档测试。

后续可隔离评测 Terra/Luna 的显式 none 档，并拆分防抖、本地等待、网络和生成耗时；未经兼容与质量验证，不直接加入生产载荷。生产设置仍为 Terra；未安装或重载任何应用。本轮仅保存评测证据，未改变生产代码。
