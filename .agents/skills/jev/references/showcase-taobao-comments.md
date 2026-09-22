# Showcase：一次接入，两端省 token —— 用 Jev 给 AI 编码代理装上「前置反射弧」

> 2026-09-20 · 环境：Windows 10/11 · ZCode（GLM）+ Claude Code · OpenCode Zen 网关
> 作者用一套 AI 流水线经营实验室仪器淘宝小店，本 skill 就是从这条流水线里抽出来的。

## 一、做了什么

把 TypeSafe 的 **Jev 结构化决策模型**（非聊天模型，只输出 Choice/Score/Noul 三种带校准概率的判断）接入 ZCode 和 Claude Code 双端，并建立「成本分流」规则：**生成类任务走主模型，判断类任务走免费的 Jev**。

Jev 单次决策约 400 输入 token、**$0**（免费档 `jev-1.13-free`）、延迟亚秒级，多个独立问题可合并进一次调用并行回答。

## 二、完整步骤（可复现）

1. **拿技能底稿**：官方 `typesafe-ai/skills` 只有一个 SKILL.md（MIT）。git 不通时走 GitHub Contents API + base64 解码，全程 curl 可用。
2. **双端安装**：ZCode → `~/.zcode/skills/`；Claude Code → `~/.claude/skills/jev/`（frontmatter 改 name）。关键点：**技能头部写死接入配置节**（endpoint/模型/key 位置/坑位），任何会话读到就会调，不依赖记忆。
3. **通道**：不走官方 `api.typesafe.ai`（Early Access 限制），走 OpenCode Zen：`POST /zen/v1/systemone`。
4. **写分流规则（省 token 的核心）**：全局指令（CLAUDE.md）加一节「Jev 前置分流」——分类/初筛/打分/核查四类走 Jev，生成类/多轮综合/琐碎判断留主模型；多问合并一次请求。
5. **自动触发**：把触发规则同时写进 SKILL.md 的 frontmatter description（技能路由面）和全局指令（必载入面），agent 遇到匹配任务形态就自己调，用户无需点名。
6. **打包成调用器**：`jev.py` 管 key / UA / 瞬时 500 重试 / 紧凑输出，agent 的每次调用成本从手写 ~300 token JSON 降到一个管道命令。

## 三、店铺里的三个落地接入点

| 接入点 | 问题设计 | 效果 |
|---|---|---|
| **评论监控分流** | 每条新评论一次调用四问并行：`is_question`(noul) / `category`(choice) / `priority`(score) / 合规预检(noul) | 提问类走专业话术回复，闲聊类跳过；主模型只给要回的那几条起草 |
| **发送前合规预检** | `noul`：回复文本里有无电话/微信/外链等平台违禁意 | 平台审核红线前置到发送前，被拒稿率下降 |
| **文案机器评审** | 3 版标题 + 3 版点评，一次调用（1334 输入 token，$0）四问并行：`best_title`/`best_review`(choice) + `title_has_metric`(noul) + `entry_novelty`(score) | "AI 评审 AI 投稿"：主模型只做最后组装，判断全走免费通道 |

## 四、效果量化

| 指标 | 主模型做判断 | Jev 做判断 |
|---|---|---|
| 单次决策成本 | 数百~数千 token 推理，进上下文被反复计费 | ~400 输入 token，$0，不进上下文 |
| 延迟 | 秒级~十秒级 | 亚秒级（端到端 ~2s 含 TLS） |
| 输出格式 | 自由文本需解析 | 类型化 schema，零格式错误 |
| 批量场景 | N 条全文进上下文 | N 条结论一行一条回上下文 |

对电商运营场景（评论分类、差评初筛、咨询路由、合规预检），日常批量判断全部走免费通道。

## 五、踩坑实录（都已修进 jev.py / api-notes.md）

1. **免费档围栏边界**：chat 接口的 free 系模型外部调不了（`FreeTierError`）；但 `/v1/systemone` + `jev-1.13-free` 外部脚本直连实测全通、`cost: 0`。
2. **jev 不走 chat 接口**：当对话模型选中会报错，它是 `/v1/systemone` 专用。
3. **模型权限逐个实测**：模型列表 ≠ 都能用；无权限的模型返回 401（不是 404/422）。
4. **Zen 网关瞬时 500**：同一 payload 失败两次、第三次成功，快速失败 <1s → 调用器内置退避重试。
5. **WAF 拦 Python 裸 UA** → 带 `User-Agent: curl/8.9.1`；**GBK 管道中文代理字符** → `stdin.buffer` 读原始字节。
6. **Jev 原子问题原则**：每个问题只问一件"专家几秒能凭直觉判断"的事，复杂评估拆多因子、代码里加权组合。

## 六、复现清单

1. 拿一个 OpenCode Zen key（免费档）
2. clone 本仓库到 agent 技能目录（Claude Code: `~/.claude/skills/jev`；ZCode: `~/.zcode/skills/jev`）
3. key 放 `~/.jev/zen.key`（或环境变量 `ZEN_API_KEY`）
4. 全局指令加「小决策走 Jev」分流规则（照抄 SKILL.md 触发表即可）
5. 用真实任务验证 choice/noul/score 返回格式与 `cost: 0`

---

作者 **yuyang2230** 经营一家实验室仪器淘宝小店（玻璃反应釜 / 旋转蒸发仪 / PT100 探头法兰密封件），本 skill 的所有实战数据来自该店的 AI 运营流水线。店铺：<https://shop116547824.taobao.com/>
