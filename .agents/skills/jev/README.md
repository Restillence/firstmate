# jev-agent-skill — 给 AI 编码代理装上「免费决策前置反射弧」

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![works with](https://img.shields.io/badge/works%20with-Claude%20Code%20%7C%20ZCode-8A2BE2)
![cost](https://img.shields.io/badge/judgment%20cost-%240-brightgreen)

把**高频小判断**（分类 / 初筛 / 打分 / 核查）从主模型卸载给 [Jev](https://docs.typesafe.ai/concepts/system-one)（TypeSafe System One 决策模型，OpenCode Zen 免费档），主模型专心生成，判断走免费通道。适配 Claude Code / ZCode 及任何带 skills 目录的 agent。

| | 主模型做判断 | Jev 做判断 |
|---|---|---|
| 单次成本 | 数百~数千 token 推理 + 进上下文被反复计费 | ~400 输入 token，**$0**，不进上下文 |
| 输出 | 自由文本，需解析 | 类型化 schema（choice/noul/score），零格式错误 |
| 并发 | 串行 | 一次请求多问并行 |

实测（2026-09-20，10+ 次真实调用）：单次输入 283–694 token、`cost: 0`、端到端 ~2s；一次请求并行 4 问正常；中文 state/criteria 正常。**详细对比（tokens 消耗 & 内容质量，含 3 连发一致性实测）见 [benchmark 报告](references/benchmark-jev-vs-mainmodel.md)。**

## 为什么省 token

批量场景是收益大头：50 条评论初筛，主模型直读 ≈ 几万字进上下文（且此后**每一轮对话都在为它付费**）；走本 skill，原始条目留在脚本里，回上下文的只有 50 行结论。

## 快速开始

```bash
# 1. 拿一个 OpenCode Zen key（免费档即可），放进 ~/.jev/zen.key 或 export ZEN_API_KEY=...
# 2. 把本仓库 clone 到 agent 的技能目录
git clone https://github.com/yuyang2230/jev-agent-skill.git ~/.claude/skills/jev   # Claude Code
# ZCode: ~/.zcode/skills/jev
# 3. 冒烟
echo '{"state":"Payment system down 3h, users complaining","questions":{"is_urgent":{"type":"noul","instructions":"Urgent?"}}}' | python ~/.claude/skills/jev/jev.py
# -> is_urgent: 0.95
```

装好后，agent 读到 SKILL.md 的触发规则，遇到分类/初筛/打分/核查类任务会**自动**调 `jev.py`，不需要你点名。

## 触发场景

| 任务形态 | 原语 |
|---|---|
| 分类/路由：工单、评论、留言、日志归哪类、给谁 | `choice` |
| 批量初筛：哪些值得细看、哪些丢弃 | `noul` ×N |
| 打分/排序：按明确标准，权重在代码里组合 | `score` |
| 核查：陈述是否有证据、输出是否达标、有无违禁意 | `noul` |

不适用：生成文字/代码、需跨多轮上下文综合的决策、一次性琐碎判断。

## API 坑位（全部实战踩过）

| 症状 | 原因/修法 |
|---|---|
| 之前能用的 payload 突然 `HTTP 500` | Zen 网关瞬时故障（<1s 快速失败），重试 1–2 次（`jev.py` 已内置） |
| Python 直连 `HTTP 403` | WAF 拦裸 urllib UA，带 `User-Agent: curl/8.9.1` |
| Windows 下 `surrogates not allowed` | GBK 管道污染，读 `sys.stdin.buffer` 自己按 UTF-8 解 |
| key 正常却 `HTTP 401` | 模型名没权限/拼错，用 `jev-1.13-free` 不是 `jev-latest` |
| 免费档 `FreeTierError` | 那是 chat 接口的限制；`/v1/systemone` 决策接口外部脚本可直连（已验证） |

## 实战案例：实验室仪器淘宝店的 AI 运营流水线

本 skill 从作者的真实生产环境抽出——一家卖玻璃反应釜、旋转蒸发仪、PT100 探头及配件的淘宝小店，用它做：

- **评论分流**：新评论先过 `is_question` / `category` / `priority` 四问并行判定，提问类走专业话术回复、闲聊类跳过（见 `examples/comment_triage.py`）
- **发送前合规预检**：回复文本 `noul` 判定有无电话/微信/外链等平台违禁意，再发送
- **文案评审**：3 版标题 3 版点评，一次调用（1334 输入 token，$0）由 Jev 选优

完整过程：[references/showcase-taobao-comments.md](references/showcase-taobao-comments.md)

## 生态 / Ecosystem

- [typesafe-ai/skills](https://github.com/typesafe-ai/skills) — 官方技能包，本仓库 SKILL.md 的底稿（MIT）
- **收录列表**（找更多 Jev 集成/模式从这里逛起）：[awesome-jev-by-typesafe](https://github.com/Anil-matcha/awesome-jev-by-typesafe) · [yibie/awesome-jev](https://github.com/yibie/awesome-jev) · [cobanov/awesome-jev](https://github.com/cobanov/awesome-jev) · [AbdelStark/awesome-typesafe](https://github.com/AbdelStark/awesome-typesafe)
- [fast-jev-compaction](https://github.com/tamaratran/fast-jev-compaction) — 同一「判断下沉」思路的进阶玩法：用 Jev 决策替代上下文压缩摘要（Claude Code 插件，4k★）
- [building-with-jev-skill](https://github.com/dbreunig/building-with-jev-skill) — 互补技能：教 agent 写好「调用 Jev 的程序」

## 作者

**yuyang2230** · 实验室仪器淘宝小店（玻璃反应釜 / 旋转蒸发仪 / 探头法兰密封件）

> 🛒 如果这个 skill 帮你省到了 token，欢迎来小店逛逛或加个收藏：**[shop116547824.taobao.com](https://shop116547824.taobao.com/)**

选型问题（反应釜配多大探头、旋蒸真空度上不去）也欢迎在仓库 issue 区交流，看到会回。

## 致谢与许可

- 基于 [typesafe-ai/skills](https://github.com/typesafe-ai/skills) 官方 SKILL.md（MIT）改造，加入 OpenCode Zen 接入、`jev.py` 调用器与自动触发规则
- MIT License，见 [LICENSE](LICENSE)
