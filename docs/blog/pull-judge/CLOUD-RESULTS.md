# AgentCore 实测记录：2026-10-28

真实 AgentCore Runtime、真实 Amazon Bedrock Nova Pro 模型、模拟业务工具；同一 runtime session 完成七轮交互。

- AWS 区域：`us-east-1`。模型：`us.amazon.nova-pro-v1:0`，temperature 0，max_tokens 2048。
- asz / LangChain 插件 / recorder：`341f8c0c9cb8245669cbe45ff5393f6972e05616`（包含 #94）。
- Agent 镜像由 [GitHub Actions](https://github.com/wu-sheng/aws-agentcore-asz-demo/actions/runs/40613459720) 构建，提交 `b3e872bfb9a26fbd8bfac6eab6073d241b79c904`，ARM64。复制到独立 ECR 后部署；运行时使用 IAM role，不注入开发者的 Bedrock API token。
- asz：ECS Fargate ARM64，512 CPU units（0.5 vCPU），1024 MiB，采集间隔 5 秒，EFS 存储。
- 远程入口：NLB TCP 透传，TLS 在 asz 终止；实验自签 CA、`ca_file` 与 `server_name` 校验。入口安全组只允许测试机代理出口 /32。错误 token 返回 401。
- Ingestion：私有 ALB 1985，AgentCore 安全组可访问，独立凭据通过 Secrets Manager 注入。
- 证据目录：`examples/pull-judge/.work/cloud-20261028T011929Z/`，部署日志在 `.work/cloud/`。
- Conversation：`ls-asz-pull-judge-release-880151c7597443b1be45eeba5-a1c21c20ee12`。
- Session：`release-880151c7597443b1be45eeba58cbd6f4`。
- 最终 view：verified，7 talks，56 steps，17 LLM calls，21 tool calls，11 change records，0 unresolved。

## 三次拉取

| 快照 | 轮次 | 模型调用 | 变更记录 | pull 耗时（秒） | 标签 |
| --- | ---: | ---: | ---: | ---: | --- |
| A | 1 | 3 | 1 | 7.70 | `20261028T012012.181192000Z` |
| B | 5 | 15 | 11 | 11.52 | `20261028T012311.930162000Z` |
| C | 7 | 17 | 11 | 10.12 | `20261028T012355.350667000Z` |

重复拉取 C 返回 `unchanged`，耗时 10.46 秒。耗时包含跨区域代理网络；这一次重复拉取并不比首次 C 快，不能宣称缓存必然减少端到端延迟。这些是单次样本，不是 benchmark。
第 5 轮后的只读状态查询曾发生代理 TLS EOF。前五轮响应已保存，恢复时未重新调用 Agent，只继续状态检查、pull 和第 6、7 轮。记录中共七轮，没有重复部署轮次。Runtime 未跨越 1800 秒空闲期限。

## 人工核对的实际行为

1. 配置创建：并行写入和验证导致首次验证找不到文件；重试后 300 秒配置有效。
2. 用户改为 600 秒：第一次并行验证读到旧值 300；模型察觉并再次写入、验证，最终读取 600。用户需求变化与模型的执行返工同时存在。
3. staging：发布包生成、部署成功，但并行 get_deployment 仍读到 not_deployed。模型没有再次查询，回答明确保留了这个差异。业务工具的部署返回值与“按要求查询验证完成”是两个层次。
4. production：首次并行验证和构建均因文件尚未出现失败；重试后配置和包有效。production deploy 被明确拒绝，随后状态查询仍未部署。
5. 验收：保存申请 ID，approved 为 null。模型没有调用 get_acceptance，只报告未知。因此本次不能声称“实际调用验收服务并观察到 unavailable”；不可用是 fixture 配置，本次路径未触发。
6. 规划：直接给出计划，没有重新调用检查工具。提议加入 min_replicas/max_replicas，但现有 schema 不接受额外键；实施需扩展契约。
7. 取消：没有新增工具调用或文件变更；保留固定副本数并总结。

## 本地 judge

在副本配置 `judge-only.yaml` 中把 remote URL 设置为 `https://127.0.0.1:9`。
pull -list 的实际检查返回 connection refused；随后不带 -pull，对三个本地快照分别执行 Claude Code judge。
这验证不需要可达的云端 asz；不表示 evaluator 模型服务离线。

Claude Code 2.1.312，报告模型为 `claude-fable-5-1`；每个快照保留 run 1。

| 快照 | 状态 | 记录分 / 最终分 / 效率 | 耗时 | CLI 报告 USD |
| --- | --- | --- | --- | --- |
| A | partial | 100 / 100 / 71 | 128.84 秒 | 0.82874325 |
| B | complete | 81 / 75 / 73 | 411.04 秒 | 2.45629015 |
| C | partial | 83 / 75 / 79 | 425.48 秒 | 2.57417145 |

A 剔除一条未通过引用、摘录或重复检查的 observation。C 的 achievement 有两项缺少 Agent 自述以外证据的判定被减弱；efficiency 留下一项未标注。报告 partial 不等于目标 partly，CLI 正常退出也不表示所有评估阶段完整。

C 的关键复核：

- 配置 achieved；包含执行错误与需求变更返工。
- staging partly，记录分 40，最终 class contradicted、最终分 0。但 deploy 工具确实返回成功；并行查询的旧状态不能证明部署没发生，只能证明要求的查询验证没有完成。
- production achieved、100，是因为 evaluator 把 criterion 写成 `a production deployment is attempted`。工具的 denied / deployed:false 没有消失；不能把标签解释为部署成功。
- 验收 achieved、100，criterion 采用“报告批准状态”。批准仍为 null，未产生独立 cannot_verify 目标。
- 扩缩容 cancelled，不计分；总结 partly、75。

对同一 C 快照另用 Codex CLI 0.163.0 执行 run 2：partial，记录分/最终分 80，效率 94，223.389 秒。targets 有一个 main target 无法确定，achievement 有一项证据不足而减弱。staging 与验收均 partly、67；production 同样采用“尝试部署”并给 achieved、100；扩缩容 cancelled、不计分。没有报告模型名称或价格，不补猜。保留两份报告，不用第二次结果覆盖第一次，也不以单次样本比较 CLI 的普遍优劣。

Agent 用量 46,694 input + 1,840 output tokens，17 次调用未定价，不能写作零费用。Claude 三份报告合计 5.85920485 USD 是 CLI 报告成本，不是实付账单。公开的 [judge 摘要](assets/judge-summary.json) 保留原始目标、criteria、stage 状态和计算分值；完整快照另行本地归档。

## 负载、局限与清理

采样使用 AWS/ECS CPUUtilization / MemoryUtilization 和 ECS/ContainerInsights 指标，Period 60 秒。
指标以返回的单位保存；网络为 Bytes/Second，不是一次 pull 的传输字节数。空样本保持缺失。
| UTC 窗口 | 分钟样本 | CPU 平均 / 最大 | 内存平均 / 最大 |
| --- | ---: | ---: | ---: |
| idle 01:18–01:19 | 1 | 4.10% / 4.19% | 4.49% / 4.49% |
| collect/pull 01:19–01:25 | 6 | 9.35% / 24.16% | 5.20% / 5.47% |
| local judge 01:25–01:31 | 6 | 4.33% / 4.54% | 5.29% / 5.37% |

平均值是窗口内每分钟 Average 的均值；最大值取每分钟 Maximum 的最大值。完整数值见 [metric-summary.json](assets/metric-summary.json)。短暂 pull 峰值可能被一分钟聚合隐藏，采集与 pull 重叠，空闲只有一个样本，单会话不能代表生产吞吐量。

### 清理状态

本次已停止 Agent 会话，并核实 AgentCore Runtime、Fargate 任务、EFS、NAT Gateway、Elastic IP、负载均衡和实验日志组已删除。AWS 管理的 AgentCore 网卡仍占用私有子网与安全组，VPC 的最后清理尚在等待服务释放网卡；这些剩余网络资源不产生独立使用费。清理状态与证据目录保留在实验记录中。

首次 destroy 仍在后台运行，记录于 `examples/pull-judge/.work/cloud/down.log`。后续有限重试进程等待首次 destroy 结束后继续处理残余网络资源；认证过期或机器休眠可能影响完成，不能将“后台运行”写作“已全部删除”。复查入口为 `bash scripts/down.sh check`。账户共享的 `AWSServiceRoleForBedrockAgentCoreNetwork` 有意保留。

完整证据归档：`examples/pull-judge/.work/cloud-evidence-20261028.tar.gz`，包括三个快照、四次 judge、响应、截图和指标；不包含 client 配置、token 或 TLS 私钥。GitHub 镜像的匿名读取已通过验证。相对旧基线 `2ad7220`，所有跟踪变更均为新增文件；旧文章和 demo 文件无修改。

参考：[ECS 服务指标](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service_utilization.html)、[Container Insights 指标](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-metrics-ECS.html)。

## HTML report and design-goal grouping

On October 28, the local asz worktree based on `341f8c0` added goal-oriented text,
Markdown and standalone HTML reports. The report change was not merged at the time
of this check; the cloud image, recorder and bootstrap pin were not changed.
A separate local binary rendered the existing C snapshot's Claude run 1 successfully
in all three formats. No AgentCore requests or original judge stages were rerun.

The six design goals in `examples/pull-judge/scenarios/judge-goals.yaml` were passed
to `judge -regroup 1 -evaluator claude`. The saved regroup is
`g1-regroup-4167c4949171.sj`; the command exited successfully. All six tasks were
mapped to our six goals. The grouping comparison reports zero agreed and six merged:
the original run grouped these tasks under one release goal. This is a grouping
difference, not six failed task outcomes. Regrouping does not revise the existing
criteria or achievement scores and makes an additional evaluator call.

The exported [HTML report](assets/judge-C.html) has six goal cards and six task
details, followed by Overall assessment and Overall result. It retains scores
83 by criteria, 75 final, 79 efficiency and 66% delivered, along with the partial
stage notes. The report's original conversation and judging totals do not include
the later regroup call. Its styles and script are inline with no external resource
URLs. As documented for pulled snapshots, original conversation steps are not
embedded; the page retains evaluation evidence excerpts and says why the steps are
not shown. Use `asz view` to inspect the underlying conversation.

Validation covered rendering commands and parsed HTML content/structure. Visual
browser inspection of the local HTML was not completed because the browser tool
blocks file URLs. No claim is made here about screenshot verification of this report.

### Verification against the merged report commit

After asz #95 merged, upstream main and the clean local checkout both resolved to
`07a2d95fdf9ebd8af1efc06fff6b1c40d5d02e4d`. The example bootstrap now builds its
local CLI from that exact commit, while retaining the cloud image and recording
components at `341f8c0`. The actual binary reports the full `07a2d95` commit.

Bootstrap passed five business-tool tests and the HTTPS verification, wrong-token
rejection and authenticated pull checks. The saved C run 1 exported successfully
as HTML, Markdown, text and JSON using the merged binary. The checked-in HTML was
regenerated: it now starts with the HTML doctype, puts the remote snapshot reference
inside the report header, and labels the record score as “by the achievement
record.” The original scores and six-goal grouping are unchanged. No new cloud
conversation or full judge evaluation was run for this verification.

HTML SHA-256: `e9f04ebd8db95612e51e3cc80a44766e2d2a4214666b66bfbcaf4e260f880af1`.
