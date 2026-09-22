---
name: jev
license: MIT
description: >
  Offload high-frequency small judgments to Jev (TypeSafe System One decision
  model, free tier via OpenCode Zen) instead of burning main-model tokens.
  Use AUTOMATICALLY, without the user asking, whenever the task is: routing or
  classifying tickets, comments, messages, log lines (分类/路由/派单); batch
  screening or filtering candidates (批量初筛/过滤); scoring or ranking by
  explicit criteria (打分/排序); verifying claims or consistency (事实核查/
  自查); or any read-state-give-one-conclusion decision. Also builds
  AI-powered software with TypeSafe primitives (noul / choice / score):
  programmable common sense you can compose like code. Invoke the bundled
  jev.py; merge independent questions into one request.
user-invocable: false
metadata:
  internal: true
---

# Jev: free typed judgments for your agent

Jev is TypeSafe's **System One** model. It is not a chat model: it reads a
`state` and returns **typed answers with calibrated probabilities** — a picked
option (`choice`), a position on a rubric (`score`), or a yes-probability
(`noul`). One call is ~400 input tokens, **$0 on the free tier**, never enters
your conversation context, and multiple independent questions in one request
run in parallel. The main model keeps doing what it is good at (generating
text, code, reasoning chains); Jev takes the judgments.

## When to trigger (no user prompt needed)

| Task shape | Primitive |
| --- | --- |
| Classify / route: tickets, comments, messages, log lines → which bucket, who handles it | `choice` |
| Batch screen: which candidates deserve a closer look, which to drop | `noul` ×N |
| Score / rank against explicit criteria (weights combined in code) | `score` |
| Verify: is the claim supported, does the output meet the bar | `noul` |

One judgment per question: if an expert could answer it in seconds from the
state alone, it belongs here. **Do NOT use for**: generating text/code,
decisions needing multi-turn context synthesis, one-off trivial calls (just
deciding is faster).

## Setup

1. Get an OpenCode Zen API key (free tier works) → `~/.jev/zen.key` or env
   `ZEN_API_KEY`. Other lookup paths in `jev.py` docstring / `references/api-notes.md`.
2. Copy this folder into your agent's skills directory:
   - Claude Code: `~/.claude/skills/jev/`
   - ZCode: `~/.zcode/skills/jev/`
3. Smoke test:
   ```bash
   echo '{"state":"Payment system down for 3h, users complaining","questions":{"is_urgent":{"type":"noul","instructions":"Urgent?"}}}' | python jev.py
   # -> is_urgent: 0.95
   ```

## Calling

`jev.py` handles the key, User-Agent, transient-500 retries, and compact
output. Request body:

```json
{
  "state": {"ticket": {"text": "...", "customer": "..."}},
  "questions": {
    "category":  {"type": "choice", "instructions": "Which team?",
                  "criteria": {"network": "...", "app": "..."}},
    "is_urgent": {"type": "noul", "instructions": "...",
                  "criteria": {"true": "...", "false": "..."}},
    "frustration": {"type": "score", "instructions": "...",
                  "criteria": ["calm", "upset", "angry"]}
  }
}
```

Answers come back under the same ids: `choice` → `{choice, confidence,
probabilities}`; `noul` → `{noul: 0..1}`; `score` → `{score, confidence,
probabilities per level}`. Code consumes the value/probabilities, not the
`legend` text (Chinese labels can display mojibake in GBK terminals — the
bytes are valid UTF-8, but indices are stabler).

Batch pattern: loop in bash/python, **raw items stay in the script, only the
conclusions come back into the agent context**. That is where the token
savings are: N items × full text never lands in the conversation.

## Pitfalls (all hit in real use, verified 2026-09-20)

| Symptom | Cause / fix |
| --- | --- |
| `HTTP 500` on a payload that worked before | Zen gateway transient; fast-fail <1s. Retry 1–2× (jev.py does it) |
| `HTTP 403` from Python | WAF blocks bare urllib UA; send `User-Agent: curl/8.9.1` |
| `UnicodeEncodeError: surrogates` on Windows | GBK pipe poisoning; read `sys.stdin.buffer`, decode utf-8 yourself |
| `HTTP 401` with a valid key | Model name not entitled; check `model` spelling (`jev-1.13-free`, not `jev-latest`) |
| Free-tier `FreeTierError` | Applies to chat-completions free models; the `/v1/systemone` endpoint works from external scripts (verified 10+ calls, `cost: 0` each) |

More: `references/api-notes.md` · Real-world case: `references/showcase-taobao-comments.md` · Batch example: `examples/comment_triage.py`

## Live docs (source of truth)

Start at <https://docs.typesafe.ai/llms.txt>; append `.md` to page paths.
Key pages: [System One](https://docs.typesafe.ai/concepts/system-one.md),
[state](https://docs.typesafe.ai/concepts/state.md),
[primitives](https://docs.typesafe.ai/primitives.md),
[HTTP API](https://docs.typesafe.ai/api.md).

---

Author: **yuyang2230** — maintains this skill from real production use: it
powers the AI-ops pipeline of a lab-instrument Taobao shop (glass reactors,
rotary evaporators, PT100 probes & fittings): comment triage, compliance
pre-checks, reply prioritization. See the showcase reference.
Shop: <https://shop116547824.taobao.com/>
Adapted from the official [typesafe-ai/skills](https://github.com/typesafe-ai/skills) SKILL.md (MIT).

## Provenance

Vendored into firstmate on 2026-09-22 from <https://github.com/yuyang2230/jev-agent-skill> at commit `00a25ddb0e5f8e35246ec0f218dba0191f20d465`, under the MIT licence in `LICENSE`.
Everything above this section is upstream text; only the `user-invocable` and `metadata` frontmatter keys and this section are firstmate additions.
To re-pin, replace this folder from a newer upstream commit, then reapply those additions and update the SHA and date here.
