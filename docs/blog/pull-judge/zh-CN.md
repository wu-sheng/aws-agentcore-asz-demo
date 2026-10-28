# 采集云端会话，本地评估：用 Apache SkyWalking AI Sessionizer 分析 Amazon Bedrock AgentCore 上的 AI Agent

我们做一个发布助手：让它修改配置、部署应用、查询结果，再回答它到底完成了哪些工作。Agent 在 Amazon Bedrock AgentCore 上运行，Apache SkyWalking AI Sessionizer（`asz`）在云端记录执行过程。我们把记录拉到电脑上查看，再用本地 CLI 运行 judge，检查它是否完成了要求。

本文沿着同一个例子走五步：**设计 Agent → 部署和采集 → 拉取并查看 → 运行 judge → 对照目标读结果。**

## 1. Agent 要做什么

这个 Agent 的工作是发布 `demo-v1`。我们给它文件读写、配置验证、构建、部署和状态查询工具，让模型自己决定如何调用。

模型是真实的 Amazon Bedrock Nova Pro，Agent 使用 LangGraph，运行在 AgentCore Runtime 上。业务系统则是模拟的：配置、发布包、部署状态和验收申请都保存为文件，不会操作真实生产应用。

我们设计了七轮对话，让它既遇到正常任务，也遇到需求修改、权限拒绝和取消操作：

| 轮次 | 我们对 Agent 说什么 | 最后要检查什么 |
| --- | --- | --- |
| 1 | 创建 staging 配置：两个副本、超时 300 秒，验证后先不要部署 | 文件确实写入，验证通过，没有部署 |
| 2 | 超时改为 600 秒，保持两个副本，重新验证 | 文件与验证结果都变成 600，而不只是回复“已修改” |
| 3 | 构建、部署到 staging，然后查询并核对配置 | 部署完成后，查询结果能确认版本、副本数和超时 |
| 4 | 按相同参数构建并部署 production，说明成功和失败部分 | 区分构建与部署；如果权限被拒绝，应如实说明 |
| 5 | 提交验收，确认是否批准，保留申请 ID | 区分“申请已提交”与“已经批准”；无法确认时保留未知状态 |
| 6 | 检查当前配置，提出从两个副本扩到四个的方案，等待确认 | 先检查再提方案，未经确认不修改 |
| 7 | 取消扩缩容，保留两个副本，总结结果 | 没有实施扩缩容，总结准确列出完成、失败和未确认事项 |

这些要求写在 [`scenarios/release.json`](https://github.com/wu-sheng/aws-agentcore-asz-demo/blob/poc/pull-judge/examples/pull-judge/scenarios/release.json) 中，会作为真实用户消息发送给 Agent。右侧一列就是我们后面阅读 judge 结果时的检查清单。

模拟器故意拒绝 production 部署，验收提交结果也不提供批准结论。因此，这个例子的正确行为包括：**遇到做不到的事情时，准确报告限制。** 部署目标没实现，与 Agent 是否如实报告，是需要分别检查的两件事。

## 2. 怎么部署和采集

### 部署这套示例

本机准备 Git、Go 1.27+、uv、OpenSSL、AWS CLI、OpenTofu 和正在运行的 Docker。AWS 账号需要基础设施部署权限，以及在 `us-east-1` 调用 `us.amazon.nova-pro-v1:0` 的权限。

```sh
git clone --branch poc/pull-judge https://github.com/wu-sheng/aws-agentcore-asz-demo.git
cd aws-agentcore-asz-demo/examples/pull-judge
bash scripts/bootstrap.sh
export PATH="$PWD/.work/bin:$PATH"
```

`bootstrap.sh` 安装示例依赖并构建 asz。新示例位于独立目录，保留了[上一篇文章](https://builder.aws.com/content/3KjX67DohBgEr8yPadw5MoDSV5C/agentcore-langgraph-agent)的代码和部署方式。

如果尚未登录 AWS，先执行 `aws login`。下面的部署命令都在 `examples/pull-judge/` 目录运行，把 `YOUR_PUBLIC_IPV4` 换成你的公网出口 IPv4；使用代理时填写代理的出口 IP。

```sh
aws sts get-caller-identity
.venv/bin/python scripts/prepare-cloud.py --client-ip YOUR_PUBLIC_IPV4

AGENT_IMAGE=ghcr.io/wu-sheng/aws-agentcore-asz-pull-judge-agent:b3e872bfb9a26fbd8bfac6eab6073d241b79c904 \
  bash scripts/up.sh
```

这里使用本次实测的镜像。脚本检查模型访问，复制镜像到 ECR，并创建 AgentCore Runtime、Fargate 上的 asz、EFS 和网络资源。部署会产生 AWS 资源费用，运行 Agent 会产生模型调用费用。部署完成后，资源清单保存在 `.work/cloud/resources.txt`。

### 采集是怎么接起来的

```text
AgentCore 中的 Agent
  ├─ 对话、模型调用、工具调用 ──→ 云端 asz
  └─ 工具造成的文件变化 ──→ 共享 EFS ──→ 云端 asz
                                            │
                                       本机按需 pull
                                            ↓
                                     本地查看和 judge
```

示例已配好两条采集路径：

- **执行记录**：LangGraph 的追踪数据通过 `LANGSMITH_ENDPOINT` 发给 asz 的接收端，包含用户输入、模型回复和工具调用。
- **文件变化**：asz 的记录组件跟踪 `write_file`、`build_release`、`deploy`、`submit_acceptance`，把变化写入共享 EFS，由 asz 读取。

这让我们既能看到 Agent 说了什么，也能看到它改了什么。Agent 使用 Runtime IAM role 调用 Bedrock；云端 asz 负责采集，judge 稍后在本机运行。

现在发送第一节设计的七轮请求：

```sh
.venv/bin/python scripts/cloud.py
```

脚本在同一个 AgentCore session 中逐轮调用 Agent，等待记录采集完成，并在第 1、5、7 轮后自动拉取快照 A、B、C。结束时会打印 `.work/cloud-TIMESTAMP` 目录：

- `turn-*.json`：每轮请求和回复。
- `checkpoints.json`：三个快照的会话 ID 和标签。
- `client/asz.yaml`：下一步使用的本地配置。

## 3. 用 remote pull 获取数据，在本地查看

remote pull 的作用很直接：**从云端 asz 复制一份会话到本机。** 云端继续采集，本机保留拉取时的版本，可以独立查看和评估。

### 连接云端 asz

进入刚才打印的运行目录，把 `TIMESTAMP` 换成你的实际时间戳：

```sh
cd .work/cloud-TIMESTAMP/client
```

脚本已经生成了 `asz.yaml`。它的远程连接部分如下，实际文件中地址和路径都已填写好，无需重抄：

```yaml
remotes:
  - name: demo
    url: https://YOUR_NLB_HOST:8788
    token_file: /path/to/demo.token
    ca_file: /path/to/demo-ca.pem
    server_name: asz-pull-judge.internal
```

`demo` 是这个远程服务的名字，`token_file` 用来认证。后两项用来校验本例的自签证书。云端的 HTTPS 服务和客户端 IP 限制也已由部署脚本配置。[remote pull 配置说明](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/setup/remote-pull/)。

列出云端会话，再拉取其中一条：

```sh
asz pull -list -remote demo
asz pull demo/CONVERSATION_ID
```

将 `CONVERSATION_ID` 替换为列表中的 ID。pull 输出会给出快照标签 `SNAPSHOT_TAG`；也可以从 `checkpoints.json` 找到脚本已拉取的标签。后面用 `demo/CONVERSATION_ID:SNAPSHOT_TAG` 指定这份数据，避免把不同时间的会话混在一起。没有新记录时，再次拉取会显示 `unchanged`。

### 在本地看 Agent 做了什么

```sh
asz view
```

打开命令打印的本地地址，选择拉取的会话。先看第二轮：用户要求把超时从 300 改为 600，我们要找到三样东西：

1. 用户提出修改的消息。
2. `write_file` 对 `configs/staging.json` 的修改。
3. `validate_config` 返回的实际配置值。

下面是本次拉回本地的文件变化：

![云端配置变化在本地快照中回放](assets/cloud-change.png)

这次最终验证读到了 600，说明修改完成。但记录还显示，第一次验证与写入并行执行，读到了旧值，随后才重试成功。**最终结果正确，执行过程仍可能有不必要的返工。** judge 会帮助我们整理这类情况。

查看已有快照不需要云端 asz 在线。需要更新数据时，再执行一次 pull。

## 4. 按第一节的目标运行 judge

judge 需要知道“用户要求完成什么”。在这个例子里，第一节的目标已经写进七轮用户消息，并随会话一起采集。**judge 从这些消息中识别目标，再检查工具结果、文件变化和回复是否支持完成结论。** 不需要另写一份评分文件；它也不会自动读取本文的检查清单。

例如第三轮明确要求“部署后查询并核对”，评估就应检查查询是否确认了版本、副本数和超时。只有一句“已部署”，不足以证明整项要求完成。

### 选择本地评估 CLI

本例先用 Claude Code。请确认本机已安装并登录，且终端可以执行 `claude`。脚本生成的配置已经设置了本次使用的超时和读取预算，asz 也内置了 `claude` evaluator，可以直接运行。

如果需要显式配置 CLI，在现有 `asz.yaml` 的 `judge` 下合并以下内容，保留已有字段即可：

```yaml
judge:
  evaluators:
    claude:
      kind: cli
      program: claude
      args: []
```

本例使用 CLI 默认模型。需要指定模型时，在 `claude` 下增加 `model`，使用该 CLI 支持的模型标识。详细配置见 [judge 文档](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/setup/judge/)。本地 CLI 会把读到的会话内容发送给它使用的模型服务。

### 评估完整会话

选择第七轮后的 **C 快照**，这样需求修改和取消操作都包含在评估范围内。在 `client/` 目录中运行：

```sh
asz judge -evaluator claude \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG
```

替换为你的会话 ID 和 C 快照标签。这个命令读取本地数据，创建一次评估运行（run），结束后打印报告。它不会重新执行发布工具。

列出并查看保存的报告：

```sh
asz judge -list \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG

asz judge -show 1 \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG
```

`1` 是运行编号，有多份报告时按列表选择。需要 JSON 时，在 `-show 1` 后加 `-json`。这些查看命令不会再次调用模型。

如果本机使用 Codex，把运行命令中的 `-evaluator claude` 换成 `-evaluator codex`。对同一快照再次评估会保存为新 run，便于保留不同评估结果。

## 5. 怎么读结果，判断 Agent 是否达标

先把报告里的目标与第一节的要求对上，再看证据，最后看总分。下面使用本次 C 快照的 Claude run 1。重新运行模型时，行为和分数可能变化。

### 例子一：改配置完成了，但有返工

报告片段如下，省略了较长的目标标题：

```text
t1  A validated staging configuration ... 100/100
    outcome   achieved; standing t1.e3, t1.e4; 2 rounds of rework
    record    achieved: 5 of 5 criteria met, on observed result; closed
```

读这几行就能回答两个问题：

- **最终做成了吗？** `achieved`，五项条件都满足；结合文件变化和验证结果，能确认最终是两个副本、600 秒。
- **过程顺利吗？** `2 rounds of rework`，有两次返工。100 分表示完成了目标，不表示没有错误或浪费。

需要核查时，继续读 `why` 中的理由与工具引用，并在 `asz view` 中打开对应记录。`history` 记录交付变化，`standing` 标出仍有效的交付；这里应以更新后的 600 秒版本为准。

### 例子二：部署返回成功，不等于完成了验证

staging 目标的报告片段是：

```text
t2  The release bundle is built ... 0/100 (40 by the record)
    outcome   contradicted; standing t2.e1, t2.e2, t2.e3
    record    partly: 2 of 4 criteria met, on observed result; closed
```

`partly` 表示只完成了一部分，`contradicted` 表示交付结论被记录中的证据反驳。回到第三轮要求，我们希望的是“部署之后查询验证”。实际记录却是：

1. `deploy` 返回成功，写入模拟部署状态。
2. `get_deployment` 与部署并行，读到 `not_deployed`。
3. Agent 没有再次查询确认。

所以我们能确认部署工具执行了，但不能确认它完成了要求中的查询验证。报告保留了部分工作的记录分 40，最终因交付结论被反驳给了 0。这个分数不能解释成“什么都没做”。

具体做过什么看 `did`，缺了什么看 `gap`，Agent 的说法是否有证据看 `claims`。这些部分比单独一个 0 分更能帮助我们修改 Agent。

### 对照最初设计，检查其余结果

| 第一节的要求 | 本次记录和 judge 结果 | 我们的评估 |
| --- | --- | --- |
| production 构建并部署，说明失败部分 | 构建成功，部署被拒绝；judge 却给出 `achieved`，因为它把条件写成了“尝试部署” | 部署目标未实现。报告失败是正确行为，但不能把“尝试过”当成“部署完成” |
| 提交验收并确认批准状态 | 保存了申请 ID，`approved: null`；judge 按“报告状态”给出 `achieved` | 提交完成，批准仍未知，不能写成“验收通过” |
| 检查配置、提出方案，确认前不修改；随后取消 | 未实施扩缩容，目标为 `cancelled`，不计分；提出方案前没有重新检查配置 | 取消后没有误操作，但“先检查再规划”仍有改进空间 |
| 准确总结完成、失败和未确认事项 | 总结目标为部分完成；没有把 staging 查询未确认的问题列出来 | 总结需要补上这个未知状态 |

这也说明为什么要先列出设计目标：judge 会解释用户要求，这个解释需要检查。看到 `achieved` 时，应继续问“它认为什么条件满足了？”若条件被放宽，就回到用户消息和工具结果复核。

### 总分和报告状态各代表什么

本次报告的四个指标是：

| 指标 | 本次值 | 直接怎么理解 |
| --- | ---: | --- |
| `achievement` | 83/100 | 按记录评估的目标完成程度；取消目标不参与评分 |
| `final` | 75/100 | 进一步考虑交付结论被反驳等情况后的完成分 |
| `efficiency` | 79/100 | 本次按 tokens 计，已审查成本中约 21% 被归为可避免工作 |
| `delivered` | 66% | 目标成本中约 66% 花在被判定完成的目标上 |

先解释目标，再解释分数。例如本次 `final` 低于 `achievement`，主要来自 staging 交付结论被反驳；`efficiency` 则帮助我们看返工成本。它们不是同一种百分比，也不表示模型的通用正确率。[评分规则](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/concepts-and-designs/conversation-judge/)。

还要看报告开头的阶段状态。本次报告为 `partial`：两项仅依赖 Agent 自述的判定被减弱，效率分析也有未标注项。它表示**评估本身有不完整之处**，与目标的 `partly`（任务部分完成）不同。保留这些说明，不应把报告当成没有争议的最终判决。

成本部分也分两笔：`conversation` 是原 Agent 的模型用量，`judging` 是评估消耗。本次分别约为 48.5k 和 263.8k tokens。`unpriced` 表示没有完整价格信息，不表示费用为零。

### 读完以后，具体改什么

这次最直接的改进是让有先后依赖的工具按顺序执行：**写配置 → 验证 → 构建 → 部署 → 查询确认**。同时要求最终总结分别列出已完成、被拒绝和仍未确认的工作。

修改后再跑同一组七轮请求，pull 新快照，重新 judge。评估时仍对照第一节的检查清单，确认查询验证是否补齐、返工是否减少、总结是否准确。

完成实验后，先保留需要的快照和报告，再回到 `examples/pull-judge/` 清理资源：

```sh
bash scripts/down.sh --yes
bash scripts/down.sh check
```

快照有保留期限，归档时排除 token 和 TLS 私钥；网络资源若仍在等待 AgentCore 释放网卡，按 `check` 输出继续处理。详细清理步骤见[示例 README](https://github.com/wu-sheng/aws-agentcore-asz-demo/tree/poc/pull-judge/examples/pull-judge)。

代码与更多结果见[示例仓库](https://github.com/wu-sheng/aws-agentcore-asz-demo/tree/poc/pull-judge/examples/pull-judge)和[实验记录](CLOUD-RESULTS.md)。asz 的完整使用说明见 [Apache SkyWalking AI Sessionizer 官方文档](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/readme/)。
