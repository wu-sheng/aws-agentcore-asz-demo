# 本地预验证：2026-10-28

此记录使用真实 Amazon Bedrock 模型，但 Agent 与 asz 服务运行在开发者电脑上。
它不是 AgentCore 云端实验的结果，不能用于声称生产侧 CPU、内存或吞吐量。

- 模型：`us.amazon.nova-pro-v1:0`，区域 `us-east-1`，temperature 0，max_tokens 2048。
- asz、LangChain 插件与 recorder：`4ff3d426780d28ef06bced7050d60426e9cebbff`。
- 原始材料：`examples/pull-judge/.work/local-20261028T005253Z-68f9/`（忽略目录）。
- 业务工具操作真实文件和模拟状态；production 权限拒绝、验收查询不可用是公开的 fixture。
- 采集端与 Agent 在 judge 开始前已停止，judge 只读取本地快照；CLI 模型服务仍联网。
- TLS 校验、错误 token 返回 401、认证 pull、最终重复 pull 返回 unchanged 均通过。

| 快照 | 用户轮次 | 模型调用 | 文件变更记录 | 标签 |
| --- | ---: | ---: | ---: | --- |
| A | 1 | 3 | 1 | `20261028T005314.443467000Z` |
| B | 5 | 15 | 9 | `20261028T005349.040763000Z` |
| C | 7 | 18 | 9 | `20261028T005406.554963000Z` |

Conversation ID：`ls-asz-pull-judge-local-release-8e10276ccab341faaae-88bc8693f8a7`。
同一个会话三个时间点分别执行 judge，不是三个不同会话，也不是 asz 自动比较报告。

## 原始工具证据

1. 第一轮把 write_file 与 validate_config 放在同一批调用，验证先读到文件不存在；随后重新验证，得到 300 秒的有效配置。
2. 第二轮用户改为 600 秒。文件确实修改了，但并行验证仍读取到旧的 300 秒。模型随后声称 600 秒配置已验证，和这一轮的验证结果不符。
3. 第三轮 build_release 内部重新验证，生成 600 秒的发布包；部署和状态查询并行，第一次查询返回 not_deployed，重查才确认 staging 部署成功。
4. 第四轮生成 production 发布包，但先误用 staging 包重复部署 staging；模型发现并改用 production 包，工具返回 denied。不能只写“权限失败”而省略前面的错误部署。
5. 第五轮申请保存，approved 为 null；get_acceptance 返回 unavailable，模型报告未知。
6. 第六轮只查询状态并提出计划，未改文件；第七轮取消实施。计划建议扩展配置字段，但现有 schema 不接受这些字段，实现仍需设计变更。

这些事实来自 pull 后的 view/API、工具结果和工作目录，并非根据最终回复推测。
并行工具的文件扫描窗口可能重叠，因此一个窗口内出现多个工具共同产生的文件变化，不能把窗口里所有变化都归因于该工具独立造成。

## 实际 judge 结果与人工核查

Evaluator：本地 Claude Code，报告的模型为 `claude-fable-5-1`。每个快照首次运行编号均为 1。

- A：run complete；配置目标 achieved，完成分 100，效率 72。识别出首次验证失败后恢复的 agent_error 返工。
- C：run partial。achievement 阶段有一条 observation 未通过引用/摘录/重复检查，被 asz 丢弃；其余阶段完成。保留这份结果，不重跑来隐藏该状态。
- C：共 6 个目标，5 个计分；记录层面 achieved 2、partly 3，另 1 个取消且不计分。完成分 77，最终分 73，效率 90。这些是本次 evaluator 的判断，不是工具状态真值。
- C：第二轮的旧值验证使配置目标出现 contradicted；production 包生成但部署拒绝，目标 partly；扩缩容目标 cancelled。
- C：验收目标被解释为“提交并如实报告状态”，判定 achieved，**没有独立 cannot_verify 标签**。批准本身仍未知，不能将该完成判定写成验收通过。目标口径需要在文章中明确讨论。
- C：后续 build_release 内部已验证 600 秒配置，但无法使第二轮当时的“已验证”陈述变为正确。区分当时的证据与后来恢复后的最终状态。

A 的 evaluator 报告成本为 1.00 USD，C 为 3.45 USD；这是 CLI 提供的估算数据，不等于额外实际支付的账单。任务模型调用在当前 asz 价格配置中未定价，不能记作零成本。
B 的最终结果待完成后补录。

## 截图与保留

`.work/.../shots/` 已保存本地回放、模型 prompt、工具与文件 diff 截图。
change.png 已人工核对：staging.json 的 300 → 600；turn.png 展示 production 轮的错误调用。
完整 prompt 截图过长，正式文章应选择清晰片段。最终文章须使用云端实验对应截图，并明确来源。
原始数据与 judge 输出保留在忽略目录；发布前另存不含 token、TLS 私钥或部署凭据的长期证据包。
