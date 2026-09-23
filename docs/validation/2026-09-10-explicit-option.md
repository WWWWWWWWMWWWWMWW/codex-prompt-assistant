# 2026-09-10 明确选项字面续写

## 结果与范围

用户要求继续优化选项引用和范围控制。本轮实现 [窄格式方案](../plans/2026-09-10-explicit-option-design.md)：清晰编号动作列表后，用户明确单选某项，当前草稿为泛化“我希望先了解如何”等受支持句首时，直接续写该动作原文并加句号。

例如，助手列表为“第一项是修改颜色，第二项是保留草稿。”，用户选择“只做你提到的第二项。”，草稿“我希望先了解如何”得到“保留草稿。”。完整句子仍在提问，未回答如何保留，也未加入实现步骤或额外要求。此前模型两轮把该引用误解为“保留原文完整结构”等内容，此命中场景现在使用确定性字面结果，不称模型语义能力提升。

支持两至三项连续编号、有限中文动作格式、最新相邻 assistant→user 消息和明确单项选择。列表全文必须匹配；多选、否定、条件、附加文字、缺项、重复、引号、截断、旧选择、具体草稿等不做提取。其他场景沿用原生成，因此已知普通范围扩展和通用指代缺口仍保留。

## 接入与保护

`CPAExplicitOptionContinuation` 位于协议核心，只提取用户明确选中的助手动作原文，不总结来源、不构造事实确认。客户端在配置、输入边界和最低上下文检查之后调用；结果仍经 normalizedCompletion 和长度门，再由既有委托执行显示/代次/签名和 Tab 焦点/UUID 核验。

命中结果标记 `phase=explicit_option`、HTTP status=0；没有模型请求、模型缓存命中或调用成功记录。字面成功不改变模型连续失败计数和限流/故障冷却。工具的 generation_source 明确标记 literal_option，原始模型输出为空不可伪填。模型/开关不变，契约更新 2026-09-10.2。

## 验证与失败记录

- 协议新增阳性断言在恒等空实现先失败（`/tmp/cpa-option-baseline.log`），实现后通过。
- 客户端新增无 HTTP 和选择改变断言在未接入时先失败（`/tmp/cpa-option-client-baseline.log`），接入后两路通过；附加条件走原请求路径。
- 新增故障冷却断言发现字面成功错误清空原状态（`/tmp/cpa-option-circuit-baseline.log`），修复后保留冷却和计数。
- 最终 `make remote-completion-test`（`/tmp/cpa-option-core-final.log`）与 `make test`（`/tmp/cpa-option-app-tests.log`）通过，C1 failures=0。新增 literal 候选显示、Tab 字面一致及接受时换字段拒绝；既有任务 ID/上下文/键盘保护回归仍通过。
- [27 条独立协议回放](../evaluation/results/explicit-option-2026-09-10/README.md)通过：12 条精确续写、15 条拒绝提取，sandbox 禁网，模型请求 0。不是实机插入或通用语义验收。
- 实际生产客户端在禁网 benchmark 中执行 13 条合成命中（12 条独立阳性＋此前 reference 失败场景），全部 `explicit_option`、request_count=0、status_code=0、raw=null，显示候选逐字匹配；见 [客户端记录](../evaluation/results/explicit-option-2026-09-10/client-results.jsonl)。两路 API 路径另由核心 HTTP 替身测试覆盖，这 13 条是本地配置路径，不计远程实测。
- `make app build/CompletionQualityBenchmark` 通过（`/tmp/cpa-option-build.log`）；严格签名、包内/可执行身份一致：2026-09-10.2、230411e dirty，散列见 [构建身份](../evaluation/results/explicit-option-2026-09-10/build-identity.json)。文档链接、脚本语法与 git diff --check 通过。
- 新版本未安装或实机复测，当前运行 2026-09-10.1 / PID45095；Codex13565、模型2353 的 PID/启动时间保持。安装文件散列保持 .1，偏好回读仍双开/Terra、表达库暂停；没有重启服务或修改设置。

本轮保留所有原工作区修改，未提交或推送。此前失败的消息裁剪实验仍仅存在于工具，不随本次接入生产。

## 11:02 用户授权安装

用户明确要求“先安装再继续优化”。先安装此前已验证的 .2 候选，没有重建替换测试对象。助手从 PID45095（9/10 10:22:23）更新为 PID48551（9/10 11:02:21）；安装 SHA256 `691fb3c622905f61415fba07e963cbdbb8f597e9247223e3cf23ec6e975283a0`。严格签名、固定 identifier requirement、保护生命周期标记、启动日志 .2/协议散列、事件监听及 lsof 路径/inode/device 全部核对通过。

旧 .1 原包和独立回退副本位于 `/Users/hcm-b0263/Applications/.cpa-explicit-option-z2qinolb/`，旁附不含正文或凭据的 evidence.json。本次仅对既有助手 label 执行 bootout/bootstrap，沿用原 guarded-helper.plist 及 preserve-resident-model 参数，服务文件散列保持。Codex13565（9/9 17:43:10）、模型2353（9/9 15:23:05）前后 PID/启动时间一致；全部偏好以内存比较保持，本地/远程双开、Terra、表达库暂停。没有写设置、重启 Codex/模型、操作真实草稿或发送。

这是限定更新成功记录；没有故障注入或实际回滚，不代表一般部署回滚已验收。新版浮层/Tab 与真实语义体验本轮未复测。安装后继续开发格式兼容候选，运行包仍固定为本次 .2。
