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

## 4. 按第一节的目标运行 judge，生成 HTML 报告

judge 从会话中的用户请求识别任务，检查工具结果、文件变化和回复是否支持完成结论。我们还可以把第一节的设计目标交给它，让报告按自己的检查清单组织，方便逐项阅读。

### 准备本地 CLI 和目标清单

本机需要已安装并登录的 Claude Code，终端可以执行 `claude`。asz 会启动它进行评估；它读到的会话内容会发送给对应模型服务。使用 Codex 时，把后面命令的 `-evaluator claude` 换成 `-evaluator codex`。

`bootstrap.sh` 已将本地 CLI 固定到合并 HTML 报告功能的 `07a2d95`（#95），可以直接使用以下命令。本次云端采集和记录组件使用 `341f8c0`；已有快照无需重新采集。

继续在 `.work/cloud-TIMESTAMP/client/` 中操作。示例的 `scenarios/judge-goals.yaml` 已把七轮请求整理成六个目标：配置、staging 发布验证、production 发布、验收、扩缩容与取消、最终总结。把它复制到当前目录：

```sh
cp ../../../scenarios/judge-goals.yaml goals.yaml
```

文件使用简单的目标列表，例如其中一条是：

```yaml
goals:
  - Build and deploy staging, then query it to verify the release, replica count and timeout.
```

实际使用完整的六条目标；上面只展示一条的写法。你可以用自己的语言写目标，关键是保留用户真正要求的结果，例如“部署后查询确认”，而不只是“尝试部署”。

### 运行评估

选择第七轮后的 **C 快照**，让需求修改和取消操作都包含在评估中。在 `client/` 目录执行：

```sh
asz judge -evaluator claude -goals goals.yaml \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG
```

替换为你的会话 ID 和 C 快照标签。命令先评估这份本地记录，再将识别出的任务归入我们的目标，保存为一次 run。它不会重新执行 Agent 的发布工具，也不要求云端 asz 在线。

如果已经评估过，只想让已有报告按这份目标清单组织，可以直接使用已有 run：

```sh
asz judge -regroup 1 -goals goals.yaml -evaluator claude \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG
```

这一步会调用评估模型做目标归组，保留原来的评估。**`-goals` 调整的是结果如何对应我们的目标，不会把原有完成条件或分数自动改成预设答案。** 因此仍需阅读下一节中的条件和证据。本次文章就是对已有的 C 快照 run 1 归组，再用新版 CLI 导出报告。

### 导出并打开 HTML

先查看 run 编号，再导出指定的一份：

```sh
asz judge -list \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG

asz judge -show -run 1 -format html \
  -remote-conversation demo/CONVERSATION_ID:SNAPSHOT_TAG > judge-C.html
```

用浏览器打开本机的 `judge-C.html` 即可，不需要启动 Web 服务。文件内包含页面样式，便于保留或分享完整报告。导出只读取已保存的结果，不会再次调用模型。

新版 `-show` 默认选择最近一次已结束的 run；`-run 1` 明确选择 run 1。如果需要简短结论，把 `-format html` 换成 `-format markdown`；需要原始阶段数据则使用 `-show -run 1 -json`。[judge 命令说明](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/setup/judge/)。

## 5. 通过浏览器页面查看评估结果

现在主要读 HTML 页面。它把结果组织为目标表格、可展开的任务详情、整体评估和整体结果。先看每项工作，再看总分。

下面使用同一次 AgentCore 实验的 C 快照。新版 CLI 重新呈现已有评估，并按我们的目标清单归组；原来的 Agent 执行记录和完成分没有改变。[本次 HTML 报告](assets/judge-C.html)保留在示例仓库中，可保存到本地打开。

### 第一步：在 Goals 表格里找到要检查的工作

表格列出 **Goal、Target、Status、Score**。Goal 是我们要达成的目标，Target 是评估识别出的具体任务，Status 说明结果，Score 给出分数。点击某行的 **Check details**，查看该任务的详情。

![评估报告总览：六个目标的状态、分数和详情入口](assets/judge-overview.jpg)

例如先找“staging 配置”这一项。它显示完成、100 分。再看“staging 部署并验证”，它显示结论被反驳、0 分。我们已经知道这两项需要分开检查，无需先理解一串内部编号。

### 第二步：展开详情，看 Criteria、Done 和 Missing

| 页面区域 | 要回答的问题 |
| --- | --- |
| **Criteria** | 什么条件才算完成？每条条件是否满足，证据是什么？ |
| **Done** | Agent 实际完成了哪些工作？ |
| **Missing** | 哪些要求没完成、没有证据，或者过程中出现了什么问题？ |

下面是 staging 部署任务展开后的页面：完成条件、已做工作和缺口并排显示，可以直接对照阅读。

![staging 任务详情：Criteria、Done 和 Missing](assets/judge-staging.jpg)

**配置目标：结果完成，但过程有返工。** 在 Criteria 中检查“两副本”“600 秒”和“更新后验证”。本次文件变化和最终验证结果支持这些条件。Done 展示已完成的配置工作；Missing 则列出并行写入和验证造成的两次返工，以及可避免工作消耗。因此，100 分代表最终达到要求，不代表过程没有错误。

**staging 目标：部署返回成功，但查询验证没有完成。** 先看 Done：发布包已构建，部署工具返回成功并写入模拟状态。再看 Missing：查询与部署并行，返回 `not_deployed`，后面没有重查。对照第一节要求的“部署后查询确认”，缺口就很明确。

这个任务的详情显示最终分 0，同时保留按完成记录得到的 40 分。它表达的是“做了一部分工作，但交付结论被反驳”，不能理解为“什么都没做”。

本例是 remote pull 的快照。HTML 会显示评估保存的条件和证据摘录，但不会嵌入原始会话步骤；核对完整工具请求、返回和文件变化时，回到第三节的 `asz view`。

### 第三步：对照原始要求，核对完成条件和证据

打开 production 任务的 Criteria，会看到本次 evaluator 将一个条件写成了“尝试部署”。于是虽然工具返回 `denied`、`deployed: false`，报告仍把任务标为完成。归组到我们的 production 目标下之后，这个条件也不会自动变成“部署成功”。

因此要同时保留两个判断：**production 部署目标没有实现；Agent 如实报告拒绝是正确行为。** HTML 把条件和证据放在一起，让这种口径差异更容易被发现。

其余目标可以按相同方式检查：

| 原始要求 | 本次应如何评估 |
| --- | --- |
| 提交验收并确认批准状态 | 申请 ID 已保存，但 `approved: null`。提交完成，批准仍未知；不能把完成标签读成“验收通过” |
| 检查配置后规划扩缩容，等待确认，随后取消 | 没有实施扩缩容，取消目标不计分；提出计划前没有重新检查配置，仍需改进 |
| 总结完成、失败和未确认事项 | 总结漏掉了 staging 查询尚未确认的问题，应该补上 |

### 第四步：读 Overall assessment 和 Overall result

**Overall assessment** 汇总分数、效率和评估自身的完整性。本次按完成记录（by the achievement record）计算为 83/100，考虑交付结论被反驳后为 75/100；效率为 79/100，表示按 tokens 计，已审查成本中约 21% 被判为可避免工作。66% 则表示目标成本中流向已完成目标的比例。这些值衡量不同的事情，不是模型的通用正确率。

本次还显示 `grouping: the judge agreed with 0 of your 6 goals; 6 merged`。原评估把六项工作合在一个发布目标下，我们则将它们分开检查。这是目标分组方式的差异，不是“六项目标全部失败”。

这一部分也列出未完成的评估阶段。本次有两项仅依赖 Agent 自述的判定被减弱，效率分析还有未标注项，因此报告为 `partial`。它说明评估本身存在不完整之处，不等于某个任务只是部分完成。[评分与证据规则](https://skywalking.apache.org/docs/skywalking-ai-sessionizer/next/en/concepts-and-designs/conversation-judge/)。

**Overall result** 用文字总结完成、被反驳和取消的任务，并区分 Agent 执行与 judge 的消耗。本次原会话约 48.5 thousand tokens，原评估约 263.8 thousand tokens。目标归组是额外一次评估调用；它的记录与原 run 分开保存，不应把这两个数字当成包含后续归组的一切费用。

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
