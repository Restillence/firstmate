#!/usr/bin/env python3
"""jev.py — call Jev (TypeSafe System One decision model) via OpenCode Zen.

Zero dependencies, stdlib only. Reads a request JSON from stdin or a file:

  echo '{"state": "text", "questions": {"q1": {"type": "noul", "instructions": "..."}}}' | python jev.py
  python jev.py request.json
  python jev.py --raw request.json     # print full JSON response instead of compact lines

Key lookup order (first hit wins):
  1. env ZEN_API_KEY
  2. ~/.jev/zen.key
  3. zen.key next to this script (gitignored — never commit it)
  4. ~/.zcode/skills/typesafe-ai/zen.key (ZCode install location)

Optional overrides: env JEV_ENDPOINT, JEV_MODEL.

Exit codes: 0 ok / 1 request or API error / 2 no key found.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = os.environ.get("JEV_ENDPOINT", "https://opencode.ai/zen/v1/systemone")
MODEL = os.environ.get("JEV_MODEL", "jev-1.13-free")
RETRYABLE = {429, 500, 502, 503, 529}


def load_key():
    env = os.environ.get("ZEN_API_KEY")
    if env:
        return env.strip()
    for path in (
        os.path.expanduser("~/.jev/zen.key"),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "zen.key"),
        os.path.expanduser("~/.zcode/skills/typesafe-ai/zen.key"),
    ):
        if os.path.exists(path):
            return open(path, encoding="utf-8").read().strip()
    return None


def call(req, retries=3):
    """POST req to the System One endpoint; returns the parsed response dict.

    Retries transient gateway failures (500/429/529/network) with backoff —
    the Zen gateway throws fast ~1s 500s occasionally; fails fast on
    auth/validation errors (401/422), those never heal on retry.
    """
    req.setdefault("model", MODEL)
    body = json.dumps(req, ensure_ascii=False).encode("utf-8")
    last = None
    for attempt in range(retries):
        try:
            r = urllib.request.Request(ENDPOINT, data=body, headers={
                "Authorization": "Bearer " + load_key(),
                "Content-Type": "application/json",
                # Bare urllib UA gets 403 from the gateway WAF; a curl-ish UA passes.
                "User-Agent": "curl/8.9.1",
            })
            with urllib.request.urlopen(r, timeout=60) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code not in RETRYABLE:
                return {"error": "HTTP %d: %s" % (e.code, e.read().decode("utf-8", "replace")[:300])}
            last = e
        except Exception as e:  # network hiccups etc.
            last = e
        time.sleep(1 + attempt)
    return {"error": "after %d attempts: %s" % (retries, last)}


def fmt(qid, ans):
    t = ans.get("type")
    if t == "noul":
        return "%s: %.2f" % (qid, ans["noul"])
    if t == "choice":
        probs = " ".join("%s=%.2f" % (o, p) for o, p in sorted(ans["probabilities"].items(), key=lambda x: -x[1]))
        return "%s: %s (conf %.2f) [%s]" % (qid, ans["choice"], ans.get("confidence", 0), probs)
    if t == "score":
        return "%s: %.2f (conf %.2f)" % (qid, ans["score"], ans.get("confidence", 0))
    return "%s: %s" % (qid, json.dumps(ans, ensure_ascii=False))


def main():
    argv = sys.argv[1:]
    show_raw = "--raw" in argv
    args = [a for a in argv if a != "--raw"]
    if not load_key():
        print("No API key found. Set ZEN_API_KEY, or put a key file at ~/.jev/zen.key", file=sys.stderr)
        sys.exit(2)
    # Windows pipes/GBK consoles can hand us surrogate chars — always read raw bytes.
    data = open(args[0], "rb").read() if args else sys.stdin.buffer.read()
    req = json.loads(data.decode("utf-8"))
    out = call(req)
    if show_raw or "answers" not in out:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        sys.exit(0 if "answers" in out else 1)
    for qid, ans in out["answers"].items():
        print(fmt(qid, ans))
    print("-- usage: %s / cost: %s" % (json.dumps(out.get("usage", {})), out.get("cost")))


if __name__ == "__main__":
    main()
