# 采集云端会话，本地评估：用 Apache SkyWalking AI Sessionizer 分析 Amazon Bedrock AgentCore 上的 AI Agent

把 Agent 部署到云端之后，怎样保留它的执行过程，又能随时用开发者电脑上的 CLI 分析它是否完成了任务？本文用一个真实调用 Amazon Bedrock 的发布助手，走完四个步骤：部署 Agent 和采集服务、拉取会话、配置本地 judge、阅读评估报告。

[上一篇 AgentCore 实践](https://builder.aws.com/content/3KjX67DohBgEr8yPadw5MoDSV5C/agentcore-langgraph-agent)介绍了 Apache SkyWalking AI Sessionizer（`asz`）如何记录会话与文件变更。这次使用 remote server、`pull` 和 `judge`，把日常采集与按需评估分开：云端持续保存记录，评估由本地显式发起，云端无需安装评估 CLI 或维护它的登录状态。

## 1. 部署 Agent 和 asz 采集服务

### 这个示例部署了什么

Agent 使用 LangGraph 和 `ChatBedrockConverse`，在 Amazon Bedrock AgentCore Runtime 上调用 `us.amazon.nova-pro-v1:0`。区域为 `us-east-1`，temperature 为 0；模型自主决定工具调用，没有预编写的模型回复或 judge 结论。

业务环境是一个发布流程模拟器：工具实际读写 JSON 配置、验证配置、生成发布包，把模拟部署和验收申请写入状态文件。production 部署会被权限规则拒绝。它不会部署真实生产应用，但模型调用、AgentCore 执行、会话采集和本地评估都是真实的。

```text
AgentCore 中的 LangGraph Agent
  ├─ 模型调用 → Amazon Bedrock
  ├─ 追踪记录 → 私有 ALB → ECS Fargate 上的 asz
  └─ 文件变更 → 共享 EFS → asz
                               │
                         HTTPS / asz pull
                               ↓
                         开发者电脑上的快照
                           ├─ asz view
                           └─ asz judge → 本地 CLI → CLI 使用的模型服务
```

asz 使用独立的 Fargate 任务（0.5 vCPU、1 GiB 内存），记录保存在 EFS。Agent 的追踪流量通过私有 ALB 到达采集端口；本地 pull 通过公网 NLB 访问 asz 的 HTTPS 服务。NLB 透传 TCP，TLS 在 asz 内终止。采集入口与 pull 使用不同 token，pull 入口只允许指定客户端出口 IP。

这里的“本地评估”指快照、评估进程和结果在本机。CLI 读取的会话内容仍会发送给它所使用的模型服务。

### 准备环境

本机需要 Git、Go 1.27+、uv、OpenSSL、AWS CLI、OpenTofu 和正在运行的 Docker。AWS 账号需要创建示例基础设施的权限，以及在 `us-east-1` 调用所选 Bedrock 模型的权限。评估时再准备已安装并登录的 Claude Code 或 Codex CLI。

示例放在独立的 `examples/pull-judge/` 目录，复用仓库而不修改上一篇文章的 Agent、配置和部署脚本：

```sh
git clone --branch poc/pull-judge https://github.com/wu-sheng/aws-agentcore-asz-demo.git
cd aws-agentcore-asz-demo/examples/pull-judge
bash scripts/bootstrap.sh
export PATH="$PWD/.work/bin:$PATH"
```

`bootstrap.sh` 构建固定版本的 asz 与文件 recorder，安装 Python 依赖，运行工具测试和本地 HTTPS/pull 检查。本文实测版本为 `341f8c0c9cb8245669cbe45ff5393f6972e05616`。这一步不会创建云资源或调用 Bedrock。

确认 AWS 管理凭据可用；没有有效会话时先登录：

```sh
aws login
aws sts get-caller-identity
```

部署后的 Agent 使用 Runtime 的 IAM role 访问 Bedrock，因此无需把本地 Bedrock API token 放进镜像或部署配置。

### 创建云端环境

以下命令都在 `examples/pull-judge/` 中执行。把 `YOUR_PUBLIC_IPV4` 替换为本机实际公网出口 IPv4；使用代理时填写代理出口 IP。

```sh
.venv/bin/python scripts/prepare-cloud.py --client-ip YOUR_PUBLIC_IPV4

AGENT_IMAGE=ghcr.io/wu-sheng/aws-agentcore-asz-pull-judge-agent:b3e872bfb9a26fbd8bfac6eab6073d241b79c904 \
  bash scripts/up.sh
```

这里使用本次实测、由 GitHub Actions 构建的 ARM64 镜像。`up.sh` 检查 AWS 身份和模型访问，将镜像复制到本账号的 ECR，再通过 OpenTofu 创建网络、EFS、Fargate 采集服务和 AgentCore Runtime。资源清单写入 `.work/cloud/resources.txt`；这些 AWS 资源和模型调用会产生费用。

`prepare-cloud.py` 生成示例 TLS 证书和部署参数。基础设施为 asz 写入的 remote server 配置核心如下；证书、私钥和 token 文件由部署过程提供，无需手动复制：

```yaml
remote_server:
  tokens_file: /asz/config/tokens
  tls:
    cert_file: /asz/config/cert.pem
    key_file: /asz/config/key.pem
```

本例自签证书有效期为 7 天，本地通过 CA 文件和证书名称校验。长期使用时，应配置自己的证书及续期流程。remote server 的配置说明见 [asz pull 官方文档](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/setup/remote-pull/)。

## 2. 运行会话，用 pull 拉回本地

### 让 Agent 完成一个有变化的任务

部署完成后运行：

```sh
.venv/bin/python scripts/cloud.py
```

脚本将 `scenarios/release.json` 中的七条请求依次发送到同一个 AgentCore session。session ID 同时用于 LangGraph thread ID，让后续请求延续上下文。

| 轮次 | 交给 Agent 的工作 | 用来观察什么 |
| --- | --- | --- |
| 1 | 创建两个副本、300 秒超时的 staging 配置，验证但不部署 | 文件交付与验证 |
| 2 | 将超时改成 600 秒并重新验证 | 用户修改要求后，最终交付是否更新 |
| 3 | 构建、部署 staging，再查询核对 | 工具执行与结果确认是否一致 |
| 4 | 构建 production 包并部署，说明成功和失败部分 | 构建成功但部署被拒绝 |
| 5 | 提交验收，确认是否批准并保留申请 ID | 提交成功与批准未知的区别 |
| 6 | 检查配置，提出扩缩容计划，等待确认 | 计划与实施的区别 |
| 7 | 取消扩缩容，保留两个副本并总结 | 取消目标及最终总结 |

脚本在第 1、5、7 轮后分别执行 pull，留下 A、B、C 三个快照。运行结束会打印 `.work/cloud-TIMESTAMP` 路径，其中 `turn-*.json` 保存每轮回复，`checkpoints.json` 保存快照标签，`client/asz.yaml` 是生成好的本地配置。模型自主行动，所以重新运行时工具调用与评分可能不同。

### 理解本地 pull 配置

进入刚打印的目录中的 `client/`。下面用 `TIMESTAMP` 表示你自己的运行时间戳：

```sh
cd .work/cloud-TIMESTAMP/client
```

生成的 `asz.yaml` 已经填好远程地址、token 文件、CA 文件和存储路径。它的核心结构是：

```yaml
storage:
  root: ./data
adapters: []
remotes:
  - name: demo
    url: https://YOUR_NLB_HOST:8788
    token_file: /path/to/demo.token
    ca_file: /path/to/demo-ca.pem
    server_name: asz-pull-judge.internal
```

`demo` 是本地给远程服务起的名字；`token_file` 提供认证凭据；`ca_file` 与 `server_name` 用于验证本例证书。上面是结构说明，继续使用脚本生成的实际配置即可。

手动列出、拉取和浏览会话：

```sh
asz pull -list -remote demo
asz pull demo/CONVERSATION_ID
asz view
```

从列表取得 `CONVERSATION_ID`，从 pull 输出或 `checkpoints.json` 取得 `SNAPSHOT_TAG`。`demo/CONVERSATION_ID:SNAPSHOT_TAG` 指向一个固定快照；后续交互不会改变它。重复拉取同一个 head 会返回 `unchanged`。

在 `asz view` 中打开拉取的会话，检查用户请求、模型调用、工具结果与文件变化。本次完整会话记录了 17 次模型调用、21 次工具调用和 11 条变更；下面是 `configs/staging.json` 从 300 秒改为 600 秒的变化。

![云端配置变化在本地快照中回放](assets/cloud-change.png)

## 3. 设置本地 judge 并运行

### 选择 evaluator

继续使用 `client/asz.yaml`，保留已有的 `storage`、`remotes` 等配置，合并以下 `judge` 段；不要创建两个同名的 `judge` 配置块。生成文件使用 JSON 语法，它也是合法 YAML；可以保留 JSON 格式编辑，也可以转换为 YAML。

```yaml
judge:
  timeout: 15m
  mode: single
  read_bytes: 524288
  evaluators:
    claude:
      kind: cli
      program: claude
      args: []
      max_turns: 60
    codex:
      kind: cli
      program: codex
      args: []
```

`claude` 和 `codex` 已是内置 evaluator 名称，这里展开配置便于理解与调整。只使用其中一个时，只需安装并登录对应 CLI，且保证 `program` 能在本机 PATH 中找到。

| 设置 | 本文如何使用 |
| --- | --- |
| `kind: cli` / `program` | 由 asz 启动本机 CLI，使用该 CLI 的登录状态访问模型 |
| `timeout: 15m` | 一次 evaluator 调用的超时，不是整份报告的总时限 |
| `mode: single` | 每个需要评估的阶段交给一次 evaluator 调用；其中仍可能包含多次模型请求 |
| `read_bytes: 524288` | 一次 evaluator 调用通过会话导航读取的回答字节上限，本例为 512 KiB |
| `max_turns: 60` | Claude CLI 的调用轮数上限；长会话需要结合超时和读取预算调整 |

本例没有指定 `model`，使用 CLI 的默认模型。需要固定评估模型时，可在对应 evaluator 下配置 `model`，填写该 CLI 支持且你的账号可访问的模型标识。其他 evaluator 和分阶段配置见 [judge 官方文档](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/setup/judge/)。

### 固定快照，执行和查看评估

以下命令在 `client/` 中执行，替换你自己的会话 ID 和快照标签：

```sh
asz judge -evaluator claude \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG

asz judge -list \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG

asz judge -show 1 \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG

asz judge -show 1 -json \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG > judge-C.json
```

第一条创建一次评估运行。`-list` 列出已有运行，`-show 1` 阅读 run 1，`-json` 导出该运行的阶段数据。列表中如果已有其他运行，应使用你要查看的编号；查看与导出不会再次调用模型。

这些命令直接读取本地已有快照，不需要云端 asz 在线。若要先拉取云端最新内容再评估，使用不带固定标签的命令：

```sh
asz judge -evaluator claude -pull \
  -remote-conversation demo/CONVERSATION_ID
```

要在同一个快照上使用另一个 evaluator，再运行一次：

```sh
asz judge -evaluator codex \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG
```

新结果保存为独立 run，已有报告保留。比较时先固定输入快照，再检查双方如何定义目标和引用证据。

## 4. 怎么读取 judge 报告

读报告可以按这个顺序：**阶段状态 → 目标与完成条件 → 证据和交付历史 → 分数与成本**。下面使用本次 C 快照的 Claude run 1；输出片段省略了部分行和较长的证据文本。

### 先看报告有没有完成

报告开头列出各阶段，本次状态如下：

```text
ledger       complete  by asz, computed
targets      complete  by claude
achievement  partial  ... 2 criteria or claims without evidence beyond the agent's words were weakened
subtasks     complete  by claude, no call, nothing to answer
efficiency   partial  ... 1 of 8 talks were not labeled
close        partial  by asz, computed
```

`ledger` 汇总记录，`targets` 识别用户目标，`achievement` 评估完成情况，`subtasks` 处理子任务，`efficiency` 分析可避免工作，`close` 汇总结果。本例没有子任务，因此该阶段无需调用模型。

这里 `partial` 表示评估产物存在未完成或被减弱的部分。具体原因就在阶段后面：两项仅依赖 Agent 自述的判定被减弱，效率阶段还有未标注项。即使命令成功退出，也应阅读这些说明。报告的 `partial` 与目标的 `partly` 不同，后者描述目标只完成了一部分。

### 再看目标是否忠实于用户请求

报告中的 `t1`、`t2` 是本次运行的目标编号，`t1.c3` 是目标的一条完成条件，`t1.e3` 是一次交付事件。先将目标和条件与原始用户请求对应，再读完成标签。

例如配置目标的输出：

```text
t1  A validated staging configuration ... 100/100
    outcome   achieved; standing t1.e3, t1.e4; 2 rounds of rework
    record    achieved: 5 of 5 criteria met, on observed result; closed
    why       t1.c3 met: idle timeout is 600 seconds (changed from the original 300)
                read: The recorded change shows the timeout line going from 300 to 600 and the final validation reads 600.
```

这个目标最终完成，依据是文件变化和验证工具读到 600。`standing` 指仍然有效的交付；`history` 会显示 300 秒版本如何被 600 秒版本替代。`2 rounds of rework` 说明过程中有返工，不能把 100 分理解成一次成功、没有浪费。

本次写文件与验证被并行发出，验证先遇到文件不存在或旧值，模型随后重试。用户把 300 改为 600 是需求变化，错误工具顺序导致的修复才是另一类工作；judge 分别记录这些情况。返工本身不会扣掉已经达成的完成分，其成本需要在效率部分继续看。

### 沿证据读出“做了什么”和“还缺什么”

| 报告部分 | 阅读方式 |
| --- | --- |
| `why` | 哪条完成条件被判定满足，依据是什么 |
| `claims` | Agent 的陈述被证据支持、反驳，还是无法确认 |
| `history` / `standing` | 交付如何演变，哪些版本仍然有效 |
| `did` | 实际文件变化、远程操作和回答交付 |
| `gap` | 哪些条件未满足或证据不足 |
| `cost` | 这个目标的调用、tokens、时间及可避免工作 |

引用中的 `tool/... returned` 指向工具返回，`msg/...` 指向 Agent 回复，`input/...` 指向用户请求，`o3` 这类标识指向变更记录。结合 `asz view` 里的原始记录核对；`read:` 是 evaluator 对证据的解释，`why, proposed` 与 `improvement, proposed` 是推测或建议，都需要结合原始证据阅读。

staging 目标展示了为什么这一步重要：

```text
t2  The release bundle is built ... 0/100 (40 by the record)
    outcome   contradicted; standing t2.e1, t2.e2, t2.e3
    record    partly: 2 of 4 criteria met, on observed result; closed
```

这次 `deploy` 返回成功并写入模拟部署状态，但 `get_deployment` 与部署并行执行，读到 `not_deployed`，之后没有重查。报告仍能在 `did` 中列出发布包和部署状态文件，同时指出查询没有确认最终状态。Agent 的交付结论被判为 `contradicted`，最终分降为 0。

这不意味着部署动作没有发生。它提示读者分开核对“部署返回成功”与“部署后的查询验证完成”。报告本身也有需要复核的地方：它把“部署后查询”的条件标为满足，却在解释中承认查询与部署并行。遇到这样的不一致，应回到工具时序判断，不能只接受标签。

同一报告还展示了另外几种常见情况：

| 情况 | 本次结果 | 应该怎样读 |
| --- | --- | --- |
| production 部署被拒绝 | 目标却显示 `achieved` | evaluator 把条件写成了“尝试部署”；工具实际返回 `denied`、`deployed: false`。必须检查目标标准，不能说部署完成 |
| 验收申请已提交，`approved: null` | 目标显示 `achieved` | 条件被解释为“报告批准状态”；申请提交与批准确认仍是两件事 |
| 用户取消扩缩容 | `cancelled`，不计分 | 取消目标不作为失败计入完成分；此前计划仍可单独检查 |

本次报告没有独立的 `cannot_verify` 目标。若其他报告出现该标签，它表示证据不足以判断目标是否完成；它与有明确未完成证据的 `not_achieved` 不同。单条 criterion 也可能是 `unknown` 或 `not_captured`，需要进一步看原因。不能因为最终回答写了“未知”，就假设 evaluator 一定给出相同的目标标签。

### 最后读分数，不把几个百分比混在一起

本次报告尾部的实际输出：

```text
score
  achievement  83/100 over 5 targets judged: achieved 3, partly 2, not achieved 0; 0 cannot be verified; 1 cancelled or replaced, not scored
  final        75/100 over the targets scored, 83 by the record
  efficiency   79/100: avoidable 21% of the reviewed cost, by tokens; 100% of the targets' cost reviewed
  delivered    66% of the targets' cost went to targets achieved, by tokens

conversation   48.5k tokens
judging        263.8k tokens (3 stages unpriced); the evaluators reported 2.57 USD
```

**`achievement` 是按记录判断的目标完成分。** 本次五个参与评分的目标分别为 100、40、100、100、75，平均为 83；取消目标不参与平均。staging 的 40 来自 2 条满足条件除以 4 条条件加 1 条被反驳的陈述，即 `2 / (4 + 1)`。因此它不等于简单的“满足条件数量百分比”。

**`final` 进一步考虑有效交付是否被反驳或撤回。** 本次 staging 的交付结论被反驳，该目标最终为 0，其他四个目标保持原分，平均为 75。应结合 `history`、`standing` 和反驳证据解释分数变化。[完整规则](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/concepts-and-designs/conversation-judge/)也区分了整个交付结论被反驳与个别条件被反驳。

**`efficiency` 衡量已审查成本中有多少没有被归为可避免工作。** 本次按 tokens 计，约 21% 被归为可避免，因此效率约 79。它不是正确率，也不是运行速度提升 79%。旁边的 100% 是目标成本的审查覆盖率，需要与阶段的 `partial` 说明一起读，不能解释为所有分析都完整。

**`delivered` 是流向已完成目标的成本占比。** 本次约为 66%，并不是另一种完成分。

最后区分两笔消耗：`conversation` 是被评估 Agent 的模型用量，`judging` 是评估本身的用量。本次评估读取证据并多次调用模型，累计 tokens 高于原会话。`unpriced` 表示价格信息不完整，不是免费；2.57 USD 是 evaluator 报告的费用，也不是 AWS 实付账单。

读完后，可以把发现转成具体修改。例如将有依赖的工具串行执行为“写入 → 验证 → 构建 → 部署 → 查询”，并要求最终总结明确列出尚未确认的状态。修改 Agent 后再运行会话、pull 新快照、judge，并继续核对目标标准与证据。

## 保留结果与清理资源

快照和 judge 结果有保留期限。先归档需要的本地快照、报告和日志，归档时排除 token 与 TLS 私钥，再回到 `examples/pull-judge/` 执行：

```sh
bash scripts/down.sh --yes
bash scripts/down.sh check
```

AWS 管理的 AgentCore 网卡释放可能延迟网络资源清理，按 `check` 输出继续处理。Container Insights 的实验日志组清理说明见示例 README。

完整代码、部署参数和脚本见[独立示例](https://github.com/wu-sheng/aws-agentcore-asz-demo/tree/poc/pull-judge/examples/pull-judge)。本次其他快照、Codex 对照结果和云端负载测量留在[实验记录](CLOUD-RESULTS.md)，便于需要时进一步核对。

## 参考

- [Apache SkyWalking AI Sessionizer 官方文档](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/readme/)
- [asz pull：远程服务、认证与快照](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/setup/remote-pull/)
- [asz judge：命令与 evaluator 配置](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/setup/judge/)
- [Conversation Judge：目标、证据与评分规则](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/concepts-and-designs/conversation-judge/)
- [AgentCore Runtime 的版本、endpoint 与 session](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-how-it-works.html)
