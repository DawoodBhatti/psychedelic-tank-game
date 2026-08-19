"""PreToolUse hook on Read: refuse to pull images into the conversation.

An image read is not a one-off cost. A screenshot read on turn 10 is re-sent on
every turn after it, for the life of the session.

Measured here at 3.2-3.4k tokens per screenshot, thirty times out of thirty;
carried forward, 10% of all input tokens in that session. That is a bad trade
for information a file path conveys just as well - but it is NOT the headline
cost, and this guard should not be mistaken for the one that matters. Session
length is that one; see pipeline-notes.md and warn_session_cost.py.

CLAUDE.md says to report the path instead. That is a promise; this is the wall.

To SHOW the user an image, use SendUserFile - it displays without entering the
context. To genuinely diagnose a visual defect, set CLAUDE_ALLOW_IMAGE_READ=1
for that command, deliberately.
"""
import os

import hooklib

IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tga", ".tiff")


def main():
    if os.environ.get("CLAUDE_ALLOW_IMAGE_READ") == "1":
        return

    target = hooklib.tool_input(hooklib.read_payload(), "file_path") or ""
    if not target.lower().endswith(IMAGE_EXTS):
        return

    hooklib.deny(
        "Refused: reading %s would pull an image into the conversation, where "
        "it is re-sent on every later turn. Measured here at ~3.3k tokens per "
        "screenshot, carried for the life of the session.\n"
        "To show it to the user: SendUserFile (displays without entering "
        "context).\n"
        "To report it: give the path.\n"
        "To genuinely diagnose a visual defect: re-run with "
        "CLAUDE_ALLOW_IMAGE_READ=1 and say why." % os.path.basename(target))


if __name__ == "__main__":
    main()
