# Pull / judge 博客 PoC 实施说明

状态：真实 Bedrock 模型的七轮会话、本地采集、HTTPS pull 与本地 CLI judge 已实测；AgentCore 云端七轮会话和三个快照也已完成，新版 judge 正在核对。详见 [云端实测记录](CLOUD-RESULTS.md)。日期：2026-10-28。

## 已确认范围

- Agent 在 Amazon Bedrock AgentCore Runtime 上运行，必须调用真实 Amazon Bedrock 模型。
- 模型自主选择工具、处理结果；模拟的是业务环境，不是 AI 调用。
- 云端采集、远程 pull、本地 CLI judge 都实际运行。
- 新示例放在 `examples/pull-judge/`，旧示例的代码、命令、镜像标签与版本固定值不改。
- 中文和英文使用同一份原始会话与同一批 judge 结果，不各跑一套来拼接结论。
- 不发布、部署或声称实验已完成，直到相应工作实际完成。

## 版本基线与旧文章保护

- 旧 demo 基线：`2ad72209751711924f1d09d570ebd88fb116e4a6`。
- 当前写作参考 asz：`22bcf3cc5ed4d1dd90f3ce1be8db192442844469`，文档标记为 0.7.0 开发中。
- 参考提交不代表已验证镜像可用。实施时检查镜像与本地 CLI，确定并记录实际测试提交。
- 本地首轮预验证使用 `4ff3d426780d28ef06bced7050d60426e9cebbff`，结果保留版本标记。云端实验升级到 `341f8c0c9cb8245669cbe45ff5393f6972e05616`（#94），同步 CLI、采集服务和记录组件；新增 absence claim 的读取范围统计，以及工具参数显示修复。
- 新 Agent 的 asz-changes、LangChain 记录组件与云端 asz 使用一致的提交。
- 不移动旧 `:main` 镜像。新 workflow 使用新镜像名称和独立的提交标签。
- 新 OpenTofu 根目录、状态、资源前缀、输出目录与旧部署分开；新清理脚本只处理新示例。
- 新示例使用内置业务 fixture，不克隆并修改旧示例仓库。
- 旧示例会克隆仓库默认分支；即使只增加目录也可能改变它看到的文件列表。新增内容集中在目录内，发布前检查旧克隆和文件读写路径。需要精确复现旧实验时使用上述历史提交，不宣称实时模型会逐字复现旧回答。

## 新示例拟定结构

```text
examples/pull-judge/
  agent/                 # 真实模型 LangGraph agent、工具与独立 Dockerfile
  fixtures/              # 配置 schema、初始业务状态、实验条件
  scenarios/             # 七轮用户请求与快照检查点
  config/                # 云端采集、本地 remote、文件变更配置
  infra/                 # 独立 OpenTofu 根目录与变量
  scripts/               # 构建校验、调用、pull、judge、测量、清理
  README.md              # 可复现使用步骤
```

部署镜像由独立 GitHub Actions workflow 构建发布，沿用仓库的构建约定。本文档本身不授权改变旧 workflow。

## Agent 与工具契约

- `BEDROCK_MODEL_ID` 必填；没有模型配置或调用失败时明确报错，不回退到 ScriptedAdvisor。
- 显式限制输出 token 和 Agent 循环次数。记录模型 ID、依赖版本与推理参数。
- 每段会话使用独立工作目录。所有业务状态写入同一被监控目录下，工具限制路径范围。
- 不提供执行任意云端部署的工具。业务状态只影响演示环境。
- 状态修改工具按请求内容操作，不按轮次直接返回预设答案。
- 配置摘要、部署 ID、申请 ID、操作结果可通过后续只读工具核对。
- 业务拒绝返回结构化结果（如 `status: denied`、原因及未执行的操作）；未知状态明确为 `unavailable`，不伪装成通过或失败。
- 故障条件由 fixture 配置：production 无部署权限；验收查询不可用。文章明确披露。

| 工具 | 工作与证据 |
| --- | --- |
| `read_file` / `write_file` | 读取、写入配置或说明，返回路径；记录文件 diff |
| `validate_config` | 解析实际文件，按 schema 检查类型、范围和必填项，返回全部发现的错误及摘要 |
| `build_release` | 保存包含实际配置的发布包和清单，返回可验证的摘要 |
| `deploy` | 校验发布包和模拟权限；staging 写入部署状态，production 拒绝并保持原状态 |
| `get_deployment` | 返回实际保存的版本、配置值、摘要和状态；没有部署时明确说明 |
| `submit_acceptance` | 保存申请并返回 ID，不授予批准 |
| `get_acceptance` | 查找申请；实验配置令结果不可用，不因此推断拒绝 |

实施时将所有改变文件的工具加入新示例的 recorder scope，不沿用旧示例只有 `write_file` 的名单。

## 会话脚本

英文请求作为实际执行文本，中文文章提供对应译文。请求只说明用户目标，不包含 judge 分类名。

1. "Prepare a staging configuration for release demo-v1 with two replicas and an idle timeout of 300 seconds. Save it as staging.json and validate it. Do not deploy yet."
2. "The requirement has changed: use an idle timeout of 600 seconds instead. Keep two replicas, update staging.json, and validate it again."
3. "Build the release bundle from the validated configuration, deploy it to staging, then query staging and verify the release, replica count, and timeout."
4. "Prepare a production release bundle for demo-v1 with the same replica count and timeout, then deploy it to production. Tell me which parts succeeded and which did not."
5. "Submit the staging release for acceptance and confirm whether it has been approved. Keep the request ID so we can follow it up."
6. "I also want autoscaling for staging, from two to four replicas. First inspect the current configuration and propose an implementation plan. Wait for my confirmation before changing anything."
7. "Cancel the autoscaling implementation; keep the current fixed replica count. Summarize what was completed, what failed, and what still cannot be verified."

这些轮次是拟定请求。模型的回复、工具调用与 judge 输出必须来自实际运行。

## 快照与采集完成条件

- A：第 1 轮结束，配置与验证的记录已采集。
- B：第 5 轮结束，新增业务结果已采集。
- C：第 7 轮结束，完整会话已采集。
- 每个检查点等待追踪发送完成，并确认 asz 中已经出现该轮结束、工具结果及文件变更；不能只等固定秒数就假设完整。
- 以 pull 列表的实际 conversation ID 定位，不能按标题猜测或自行拼接 ID。
- 保存每次 pull 返回的 TAG、head round、文件完整性结果及开始/结束时间。
- 固定 tag 执行 judge，保存 run number；三次独立运行，人工并排解释，不宣称 asz 自动比较它们。
- 中途等待不得超过已配置会话生命周期而不自知。记录是否发生环境重建；本实验不以丢失上下文作为预定故障。

## 验证 judge 的方法

评估前根据实际工具状态和原始记录写人工核查表；不给 evaluator 预设分类答案。检查目标及 criteria、证据引用、修改记录、费用、返工和未覆盖部分。

| 情况 | 应检查的事实，非强制标签 |
| --- | --- |
| 完成 | 配置、校验、staging 状态一致，通常支持 `achieved` |
| 需求变更返工 | 用户修改要求在前，重新修改与验证在后；不能直接等同 avoidable work |
| 部分完成 / 失败 | production 包已生成但部署被拒绝；允许 target 划分不同 |
| 未知 | 申请已提交，批准结果未知；允许一个 target 的未知 criteria 或单独的 `cannot_verify` |
| 取消 | 实施目标取消，已交付计划可能另属一个已完成 target |

`contradicted`、`reverted` 和 `agent_error` 返工仅在真实记录支持时使用，不为了凑齐标签强制模型犯错。

真实模型的用量从采集记录读取。价格表缺失时标记 unpriced，不以示例数字补齐。任务成本与 judge 成本分别展示；未知不等于零。模拟部署状态不能当成真实 AWS 服务健康或账单证据。

## 远程访问和负载验证

- 保留独立云端 asz 进程；新示例启用 remote server，并分开配置 ingest 凭证与 pull Token。
- 实施前确定 HTTPS 终止与证书配置。当前旧部署为 HTTP，不可直接照搬为新示例的远程访问流程。
- 开启全站 Token 后，旧的 `/` 健康检查会收到 401。新部署必须验证正确的健康检查方法，不在未经检查时放行部署。
- 先验证成功认证、错误 Token 拒绝、云端和本地内容一致、重复 pull 复用。
- 对已拉取快照，在阻止本机连接远程 asz 的情况下运行 judge；仍允许 evaluator 访问其模型服务。
- 采集基线、首次 pull、同一 head 重复 pull、会话增长后的 pull、本地 judge 分开测量。
- 记录云端规格、工具调用量、会话字节数、pull 字节数、耗时、CPU、内存及采样粒度。负载结论限定在此次规模。

## 交付与发布条件

- [x] 新示例实现与工具状态测试通过，旧文件未改动。
- [x] 使用真实模型的本地采集 → pull → judge 链路通过（judge 含 partial 结果，需如实解释）。
- [x] 按仓库约定构建独立部署镜像。
- [x] 真实 AgentCore 部署和七轮会话完成，原始证据保存到独立目录。
- [ ] 三个快照与 judge 结果保存，人工核查完成。
- [x] 本地 judge 独立于远程 asz 的验证完成（remote 改为不可达地址；pull 失败而已有快照可评估）。
- [ ] 负载数据与局限写入两篇文章。
- [ ] 中英文截图来自同一次实验；所有占位符替换。
- [ ] 旧示例复现路径复查；新增资源清理结果记录。
- [ ] 文章内容审核后再进入 AWS Builder 发布流程。

实验材料保存到新示例专用、git-ignored 的 evidence 目录。原始数据中的凭证不进入仓库或截图。快照及其中的 judge 结果会过期，另存长期证据包。

## 当前产物

- [中文初稿](zh-CN.md)
- [英文初稿](en.md)
- [独立示例与本地测试入口](../../../examples/pull-judge/README.md)。五项业务状态测试、模型配置必填检查和本地 HTTPS/错误 Token 拒绝/认证 pull 列举已通过。
- Bedrock API token 已支持真实模型调用。本地实测结果见 [LOCAL-RESULTS.md](LOCAL-RESULTS.md)；AWS 管理会话已恢复，云端七轮实测见 [CLOUD-RESULTS.md](CLOUD-RESULTS.md)。
