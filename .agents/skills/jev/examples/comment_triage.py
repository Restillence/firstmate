#!/usr/bin/env python3
"""Batch-triage shop/e-commerce comments with Jev BEFORE the main model sees them.

Input : JSON array of comments (UTF-8 file), e.g.
          [{"id": 1, "text": "1L的反应釜配的探头是PT100吗?"},
           {"id": 2, "text": "发货挺快,包装很好"}]
Usage : python examples/comment_triage.py comments.json
Output: one line per comment -> REPLY/defer, bucket, priority(0-2), compliance risk

Pipeline position (as used by the author's shop):
  new comment -> this script -> question-type comments get a professional
  reply draft from the main model -> every outbound reply passes the same
  compliance pre-check (no phone/wechat/external links) before sending.
  Raw comment text never enters the agent conversation; only this summary does.
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from jev import call

QUESTIONS = {
    "is_question": {
        "type": "noul", "instructions": "买家是在提问吗(需要具体答复)?",
        "criteria": {"true": "询问产品参数/选型/使用/物流等,需要具体答复",
                     "false": "闲聊/纯好评/纯差评发泄"}},
    "category": {
        "type": "choice", "instructions": "归到哪一类?",
        "criteria": {"pre_sales": "售前咨询(参数/选型/价格)",
                     "tech": "使用中的技术问题",
                     "logistics": "物流/发货/包装",
                     "other": "其他"}},
    "priority": {
        "type": "score", "instructions": "回复优先级?",
        "criteria": ["可次日回", "当天回", "尽快回(买家在等/影响下单)"]},
    "compliance_risk": {
        "type": "noul", "instructions": "若要回复,该评论语境下回复有电话/微信/站外链接等平台违禁风险吗?",
        "criteria": {"true": "回复需提及或暗示站外联系方式",
                     "false": "常规站内回复即可"}},
}

def triage(comment):
    out = call({"state": {"comment": comment["text"]}, "questions": QUESTIONS})
    return comment.get("id", "?"), out.get("answers"), out.get("error")

def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    comments = json.loads(open(sys.argv[1], "rb").read().decode("utf-8"))
    for c in comments:
        cid, a, err = triage(c)
        if not a:
            print(f"{cid}: ERROR {err}")
            continue
        action = "REPLY" if a["is_question"]["noul"] > 0.6 else "defer"
        print(f"{cid}: {action:5s} {a['category']['choice']:9s} "
              f"prio={a['priority']['score']:.1f} "
              f"compliance_risk={a['compliance_risk']['noul']:.2f}")

if __name__ == "__main__":
    main()
