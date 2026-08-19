---
description: Report where this session's tokens went, and what the next turn costs.
---

Run the usage report and interpret it for the user:

```bash
python .claude/scripts/usage_report.py
```

Then say, briefly and in plain words:

- The headline: total effective tokens, and the cost of one more turn.
- The single biggest contributor, named concretely (not "context growth").
- Whether anything is baked in and therefore unfixable in this session —
  images read into the conversation are the usual culprit, and only a fresh
  session clears them.
- One concrete thing to do differently, if there is one. If spending looks
  reasonable, say so plainly rather than manufacturing advice.

Keep it to a handful of lines. A long report about spending is its own joke.
