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

待补入三个报告的完成状态、目标判定、效率和 CLI 报告成本；不要用本地预验证的报告替换云端报告。

## 负载、局限与清理

采样使用 AWS/ECS CPUUtilization / MemoryUtilization 和 ECS/ContainerInsights 指标，Period 60 秒。
指标以返回的单位保存；网络为 Bytes/Second，不是一次 pull 的传输字节数。空样本保持缺失。
需要在 judge 完成后补录完整时间区间和清理结果。短暂 pull 峰值可能被一分钟聚合隐藏，单会话不能代表生产吞吐量。

参考：[ECS 服务指标](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service_utilization.html)、[Container Insights 指标](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-metrics-ECS.html)。
