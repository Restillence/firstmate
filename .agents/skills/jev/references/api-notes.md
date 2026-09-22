# OpenCode Zen — System One 接口笔记

> 全部内容来自 2026-09-20 的真实调用（10+ 次，覆盖 noul/choice/score、结构化 state、中文、多问并行）。

## Endpoint

```
POST https://opencode.ai/zen/v1/systemone
Authorization: Bearer <key>
Content-Type: application/json
User-Agent: curl/8.9.1        # 裸 urllib UA 会被 WAF 403
```

- 免费档模型：`jev-1.13-free`。官方文档的 `jev-latest` 在 Zen 通道不可用/无权限（实测 401）。
- 可用 `JEV_ENDPOINT` / `JEV_MODEL` 环境变量覆盖（付费档模型同理）。

## 请求体

```json
{
  "state": "纯字符串，或结构化对象/数组（引用嵌套路径如 `ticket.messages[0].text`）",
  "model": "jev-1.13-free",
  "questions": {
    "<自取id>": {
      "type": "noul | choice | score",
      "instructions": "判定什么（一个原子判断）",
      "criteria": { "noul": {"true": "...", "false": "..."},
                     "choice": {"opt1": "...", "opt2": "..."},
                     "score":  ["级别1", "级别2", "级别3"] }
    }
  }
}
```

- **id 不发给模型**，随意命名；答案按同样 id 返回。
- 多个独立问题合并进一次请求 → 并行执行、不增延迟。
- 原子问题原则：每个问题问一件"专家几秒能凭直觉判断"的事；复杂评估拆成多因子分别问，代码里加权。

## 响应体

```json
{
  "model": "jev-1.13-free",
  "answers": {
    "a_noul":   {"type": "noul", "noul": 0.94},
    "a_choice": {"type": "choice", "choice": "app", "confidence": 0.97,
                 "probabilities": {"app": 0.98, "network": 0.02, "hardware": 0.0}},
    "a_score":  {"type": "score", "score": 1.23, "confidence": 0.63,
                 "legend": {"0": "平静", "1": "不满", "2": "愤怒"},
                 "probabilities": {"0": 0.3, "1": 0.5, "2": 0.2}}
  },
  "usage": {"input_tokens": 438, "output_tokens": 73},
  "cost": 0
}
```

- `usage` 字段名有过 `input_tokens` / `input_tokens` 变体，代码兼容处理或直接整体打印。
- score 的 `legend` 中文在 GBK 终端显示乱码，但字节是正确 UTF-8——**代码只消费 `score` 数值和 `probabilities`，别依赖 legend 文本**。

## 错误码与坑

| 码 | 含义 | 处理 |
|---|---|---|
| 401 | key 无效 **或模型名无权限** | 先查 model 拼写再查 key |
| 403 | WAF 拦 UA（Python 裸 urllib） | 带 `User-Agent: curl/8.9.1` |
| 422 | 请求体校验失败 | 看 body 里的 offending field |
| 429/529 | 限流/过载 | 指数退避重试 |
| **500** | **网关瞬时故障**（同 payload 重试即好，<1s 快速失败） | 重试 1–2 次；`jev.py` 已内置 3 次退避 |

## 免费档围栏的准确边界

- **chat 接口**（`/v1/chat/completions`）的 free 系模型（mimo/nemotron/big-pickle/jev-free 等）有客户端围栏：外部 curl 报 `FreeTierError: can only be used from within OpenCode`。
- **`/v1/systemone` 决策接口无此限制**：外部脚本（curl / Python urllib）直连 `jev-1.13-free` 全部成功，响应 `cost: 0`（2026-09-20 实测 10+ 次）。
- jev 不是聊天模型，选中它当对话模型会报错——它只服务 `/v1/systemone`。

## Windows 专项

- GBK 管道会把中文变代理字符 → `json.dumps` 时 `UnicodeEncodeError: surrogates not allowed`。**读原始字节自己解**：`json.loads(sys.stdin.buffer.read().decode("utf-8"))`（`jev.py` 已内置）。
- bash heredoc 内联中文在某些终端会 GBK 乱码 → 假 500/422。写临时 JSON 文件（UTF-8）再 `python jev.py file.json` 最稳。
