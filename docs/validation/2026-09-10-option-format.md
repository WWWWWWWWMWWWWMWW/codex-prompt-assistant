# 2026-09-10 编号列表格式兼容

## 结果与边界

先完成 [用户授权的 .2 安装](2026-09-10-explicit-option.md#1102-用户授权安装)，再按 [局部方案](../plans/2026-09-10-option-format-design.md)开发 .3。发现旧解析只删除整份列表末尾句号，每项汉字匹配导致常见逐项句号、空行、加粗失配。

候选只做格式解析：CRLF 归一、忽略纯空白行，每项允许一个中文句号及完整动作的成对 ** 加粗。仍完整校验所有非空内容、连续编号、有限动作、明确单选和相邻消息；不跳过附注、不跨新回复检索旧选择。动作内容逐字保留，继续经过共同门、原有发布/Tab 保护。模型提示词和 provider 选择未改，契约更新 .3。其余输入沿用原生成，通用原意保持缺口尚未解决。

## 验证

- 修改前新增协议阳性断言先失败，`make remote-completion-test` 退出 2，见 `/tmp/cpa-option-format-baseline.log`；69 例固定回放中新增 16 例全部未命中，基线退出 1，见 `/tmp/cpa-option-format-replay-baseline.log`。
- 修改后 `make remote-completion-test`、`make test` 均退出 0；日志 `/tmp/cpa-option-format-core.log`、`/tmp/cpa-option-format-app-tests.log`，C1 replay failures: 0。两路客户端新增格式命中/选项正文修订均无需 HTTP，保留故障冷却及连续失败计数。
- [69 条禁网协议回放](../evaluation/results/option-format-2026-09-10/README.md)全部符合期望：新增 16 条、原有 12 条逐字续写；新增 26 条及原有 15 条不提取。阴性结果只说明不走字面路径，不等于系统整体拒绝。
- 实际生产客户端禁网验证新增 16 条全部逐字一致、请求数 0；是本地配置分支、无模型/远程实测。脚本初次及诊断复跑因测试夹具缺少 family_id 而 SIGABRT，补齐夹具后通过，原失败保留。
- `make app build/CompletionQualityBenchmark` 退出 0（`/tmp/cpa-option-format-build.log`），严格签名及固定 identifier requirement 通过，包内/可执行身份一致。2026-09-10.3 / 230411e dirty，SHA256 `45f0d58a360c4c5c8f54a059e44498326ff631a533f09d11f0c68e1b937eca49`，完整信息见 [构建身份](../evaluation/results/option-format-2026-09-10/build-identity.json)。

## 交付状态

.3 为已构建候选，未再次安装/重载；运行仍为本轮先安装的 .2 / PID48551，Codex13565/模型2353 PID 与启动时间保持，四项补全偏好回读保持双开/Terra、表达库暂停。未操作真实草稿或重测实机浮层/Tab；原用户体验确认不充当 .3 自动验收。保留已有工作区改动，本轮未提交或推送。

## 11:20 用户授权安装

用户明确要求“安装后继续优化”。安装此前已测 .3 候选，不重建换包；助手从 PID48551（9/10 11:02:21）更新为 PID50062（9/10 11:20:06）。安装 SHA256 `45f0d58a360c4c5c8f54a059e44498326ff631a533f09d11f0c68e1b937eca49`；严格签名、固定 designated requirement、生命周期保护标记、启动 .3/协议散列、事件监听和映射 path/inode/device 均通过。

旧 .2 原包与独立副本保存在 `/Users/hcm-b0263/Applications/.cpa-option-format-qkiuufa8/`，旁附白名单 evidence.json。仅 bootout/bootstrap 既有助手 label，原 guarded-helper.plist 及 preserve-resident-model 参数保持。全量偏好在内存比较一致；本地/远程双开、Terra、表达库暂停。Codex13565（9/9 17:43:10）和模型2353（9/9 15:23:05）PID/启动时间保持，未重启。

未执行真实草稿输入、发送或实机补全复测；限定更新成功不证明一般运行失败回滚已验收。随后开始范围/否定约束优化实验，运行包固定为本次 .3。
