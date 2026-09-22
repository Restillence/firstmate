# jev-agent-skill — free typed judgments for AI coding agents

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![works with](https://img.shields.io/badge/works%20with-Claude%20Code%20%7C%20ZCode-8A2BE2)
![cost](https://img.shields.io/badge/judgment%20cost-%240-brightgreen)

Offload **high-frequency small judgments** (classify / batch-screen / score /
verify) from your main model to [Jev](https://docs.typesafe.ai/concepts/system-one)
(TypeSafe System One decision model, free tier via OpenCode Zen). The main
model generates; judgments go through a $0 typed-probability side channel.
Works with Claude Code, ZCode, or any agent with a skills directory.

| | Main model judges | Jev judges |
|---|---|---|
| Cost per call | 100s–1000s of reasoning tokens, re-paid every turn via context | ~400 input tokens, **$0**, never enters context |
| Output | free text to parse | typed schema (choice/noul/score), zero format errors |
| Parallelism | serial | many questions, one request |

Verified 2026-09-20 over 10+ real calls: 283–694 input tokens each, `cost: 0`,
~2s end-to-end, 4 parallel questions per request, Chinese state/criteria OK.
**Full benchmark (token consumption & quality vs main-model judging, incl. 3×-repeat consistency) in [references/benchmark-jev-vs-mainmodel.md](references/benchmark-jev-vs-mainmodel.md).**

## Why it saves tokens

Batch is the big win: screening 50 comments with the main model means tens of
thousands of tokens enter context **and stay there, re-billed every turn**.
With this skill the raw items stay inside the script; only 50 lines of
conclusions return to the agent.

## Quick start

```bash
# 1. Get an OpenCode Zen key (free tier) -> ~/.jev/zen.key  or export ZEN_API_KEY=...
# 2. Clone into your agent's skills dir
git clone https://github.com/yuyang2230/jev-agent-skill.git ~/.claude/skills/jev   # Claude Code
# ZCode: ~/.zcode/skills/jev
# 3. Smoke test
echo '{"state":"Payment system down 3h, users complaining","questions":{"is_urgent":{"type":"noul","instructions":"Urgent?"}}}' | python ~/.claude/skills/jev/jev.py
# -> is_urgent: 0.95
```

Once installed, agents that read SKILL.md trigger `jev.py` automatically on
classify/screen/score/verify tasks — no need to ask for it.

## Triggers

| Task shape | Primitive |
|---|---|
| Classify/route tickets, comments, messages, logs | `choice` |
| Batch screen candidates | `noul` ×N |
| Score/rank against explicit criteria | `score` |
| Verify claims / outputs / policy compliance | `noul` |

Not for: generating text/code, multi-turn synthesis, one-off trivial calls.

## Pitfalls (hit in real use)

| Symptom | Fix |
|---|---|
| `HTTP 500` on a payload that worked before | Zen gateway transient; retry 1–2× (built into `jev.py`) |
| `HTTP 403` from Python | WAF blocks bare urllib UA; send `User-Agent: curl/8.9.1` |
| `surrogates not allowed` on Windows | GBK pipe poisoning; read `sys.stdin.buffer`, decode utf-8 |
| `HTTP 401` with a valid key | model name not entitled; use `jev-1.13-free`, not `jev-latest` |
| Free-tier `FreeTierError` | that's the chat endpoint; `/v1/systemone` works from external scripts (verified) |

## Real-world case

Extracted from the author's production pipeline: a Taobao shop selling lab
glassware (glass reactors, rotary evaporators, PT100 probes & fittings) uses
it for comment triage, pre-send compliance checks, and A/B copy review.
See [references/showcase-taobao-comments.md](references/showcase-taobao-comments.md).

## Ecosystem

- [typesafe-ai/skills](https://github.com/typesafe-ai/skills) — official skills pack; the source of this repo's SKILL.md (MIT)
- **Curated lists** (browse for more Jev integrations/patterns): [awesome-jev-by-typesafe](https://github.com/Anil-matcha/awesome-jev-by-typesafe) · [yibie/awesome-jev](https://github.com/yibie/awesome-jev) · [cobanov/awesome-jev](https://github.com/cobanov/awesome-jev) · [AbdelStark/awesome-typesafe](https://github.com/AbdelStark/awesome-typesafe)
- [fast-jev-compaction](https://github.com/tamaratran/fast-jev-compaction) — same "judgments-down" idea, one level up: replace compaction summaries with Jev decisions (Claude Code plugin, 4k★)
- [building-with-jev-skill](https://github.com/dbreunig/building-with-jev-skill) — companion skill: teaching agents to write programs that call Jev well

## Author

**yuyang2230** — runs a lab-instrument Taobao shop:
**[shop116547824.taobao.com](https://shop116547824.taobao.com/)**
(glass reactors, rotary evaporators, probes/flanges/seals). If this skill
saved you tokens, a visit or a star is appreciated.

Based on the official [typesafe-ai/skills](https://github.com/typesafe-ai/skills)
SKILL.md (MIT). License: MIT — see [LICENSE](LICENSE).
