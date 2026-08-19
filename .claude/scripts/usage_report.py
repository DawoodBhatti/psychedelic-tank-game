"""Report where this session's tokens actually went.

Effective cost, not raw counts, because a raw count makes a huge cached context
look free when it is the dominant term.

WEIGHTS - do not "simplify" these:
  input               1.0
  cache_creation      2.0   correct for the 1-HOUR cache TTL this setup uses.
                            (The 1.25x figure quoted in Anthropic's pricing is
                            the 5-minute TTL. Using it here understates writes.)
  cache_read          0.1
  output              5.0

The headline number is not a total. It is the SHAPE: context grows
monotonically within a session and is never reclaimed, so every turn re-reads
everything before it. Cost is superlinear in session length. The growth curve
below is the diagnostic that actually changes behaviour.

Run with no argument to analyse the most recently modified transcript.
"""
import json, os, sys, glob, collections

PROJECTS = os.path.expanduser("~/.claude/projects")
WEIGHTS = {"input_tokens": 1.0, "cache_creation_input_tokens": 2.0,
           "cache_read_input_tokens": 0.1, "output_tokens": 5.0}

# Measured on this project: the context delta across an image tool_result was
# 3.2-3.4k tokens, thirty times out of thirty. Used to attribute image cost
# rather than guessing from base64 length.
TOKENS_PER_IMAGE = 3300


def newest_transcript():
    files = glob.glob(os.path.join(PROJECTS, "*", "*.jsonl"))
    if not files:
        sys.exit("No transcripts found under %s" % PROJECTS)
    return max(files, key=os.path.getmtime)


def scan(path):
    total = 0.0
    raw = collections.Counter()
    images = []              # request index at which each image landed
    text = collections.Counter()
    calls = collections.Counter()
    params = collections.Counter()
    requests = []            # (cache_read, cache_creation, output) per request
    pending = {}

    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue

        msg = rec.get("message") or {}
        content = msg.get("content")

        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                kind = block.get("type")
                if kind == "tool_use":
                    name = block.get("name", "?")
                    pending[block.get("id")] = name
                    calls[name] += 1
                    params[name] += len(json.dumps(block.get("input", {})))
                elif kind == "tool_result":
                    name = pending.get(block.get("tool_use_id"), "unknown")
                    body = block.get("content")
                    if isinstance(body, str):
                        text[name] += len(body)
                    elif isinstance(body, list):
                        for part in body:
                            if not isinstance(part, dict):
                                continue
                            if part.get("type") == "image":
                                images.append(len(requests))
                            elif part.get("type") == "text":
                                text[name] += len(part.get("text", ""))

        usage = msg.get("usage")
        if usage:
            for field, weight in WEIGHTS.items():
                n = usage.get(field, 0)
                raw[field] += n
                total += n * weight
            requests.append((usage.get("cache_read_input_tokens", 0),
                             usage.get("cache_creation_input_tokens", 0),
                             usage.get("output_tokens", 0)))

    return total, raw, images, text, calls, params, requests


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else newest_transcript()
    total, raw, images, text, calls, params, requests = scan(path)

    subs = glob.glob(os.path.join(os.path.splitext(path)[0], "subagents", "*.jsonl"))
    sub_total = sum(scan(s)[0] for s in subs)
    n = len(requests) or 1

    print("Session : %s" % os.path.basename(path))
    print("Size    : %.1f MB   |   %d API requests" % (
        os.path.getsize(path) / 1048576, len(requests)))
    print()
    print("EFFECTIVE TOKENS")
    print("  main session : %12.0f" % total)
    print("  subagents(%d) : %12.0f   (%.1f%% - subagent context dies with the"
          % (len(subs), sub_total, 100.0 * sub_total / (total + sub_total) if total else 0))
    print("                                 agent, so this is the cheap place to work)")
    print("  TOTAL        : %12.0f" % (total + sub_total))
    print()
    print("WHERE IT WENT (raw x weight)")
    for field, weight in WEIGHTS.items():
        v = raw[field]
        print("  %-28s %12d x %.1f = %11.0f  (%4.1f%%)"
              % (field, v, weight, v * weight,
                 100.0 * v * weight / total if total else 0))

    # The growth curve. This is the finding: context is never reclaimed, so
    # the last requests of a long session each cost several times the first.
    print()
    print("CONTEXT GROWTH (the thing that actually drives cost)")
    k = 10
    for i in range(k):
        seg = requests[i * n // k:(i + 1) * n // k]
        if not seg:
            continue
        avg = sum(s[0] for s in seg) / float(len(seg))
        bar = "#" * int(avg / 25000)
        print("  %3d%%-%3d%% of session  avg context %7.0fk  %s"
              % (i * 10, (i + 1) * 10, avg / 1000, bar))
    if requests:
        first = requests[0][0] + requests[0][1]
        last = requests[-1][0] + requests[-1][1]
        print("  first request %.0fk -> last request %.0fk" % (first / 1000, last / 1000))

    print()
    print("WHAT IS SITTING IN THE CONTEXT")
    carried = sum(TOKENS_PER_IMAGE * (n - i) for i in images)
    processed = sum(r[0] + r[1] for r in requests) or 1
    print("  images read into context : %d  (~%.0fk tokens carried = %.1f%% of"
          % (len(images), len(images) * TOKENS_PER_IMAGE / 1000.0,
             100.0 * carried / processed))
    print("                             all input processed)")
    print("  -- tool CALL parameters (what the model wrote) --")
    for name, chars in params.most_common(4):
        print("     %-22s %8d chars (~%6d tok) over %d calls"
              % (name, chars, chars // 4, calls.get(name, 0)))
    print("  -- tool RESULTS (what came back) --")
    for name, chars in text.most_common(4):
        print("     %-22s %8d chars (~%6d tok)" % (name, chars, chars // 4))

    print()
    print("COST OF THE NEXT TURN")
    last_read = requests[-1][0] if requests else 0
    print("  context re-read on every turn : %d tokens" % last_read)
    print("  i.e. ~%.0fk effective tokens before a single new word is said."
          % (last_read * 0.1 / 1000))
    if last_read > 400000:
        print()
        print("  This session is expensive per turn. Finishing it and starting a")
        print("  fresh one is the largest single saving available - nothing else")
        print("  in this report comes close.")
    if images:
        print()
        print("  NOTE: %d images are baked into this history and are re-sent every"
              % len(images))
        print("  turn. That cannot be undone - only a fresh session clears it.")


if __name__ == "__main__":
    main()
