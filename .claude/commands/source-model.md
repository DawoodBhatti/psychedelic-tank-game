---
description: Find free CC0 3D models matching a description, and pick one to download by hand.
argument-hint: <what you need a model of>
---

Find a model for:

**$ARGUMENTS**

You are the **orchestrator**. You do not search yourself — `modeller` does, inside a subagent,
so the pages it reads die with it instead of sitting in this session's context for the rest of
the day. You own everything the user sees, because a subagent cannot ask them anything.

## The cycle

1. **Spawn `modeller`** with the request. It returns three to five candidates and the path to
   a `.candidates.json`.

   **Killed mid-run, it is resumed via SendMessage** (CLAUDE.md § The loop) — but the
   recover-from-disk half of that rule does not apply here: the modeller writes
   `.candidates.json` only at the very end, so an interruption leaves *nothing* on disk and a
   cold respawn re-buys ~29 minutes of WebFetch.

2. **Print the shortlist as text, then ask over the same list.** In that order. AskUserQuestion
   is a blocking modal, so a link inside an option is one the user cannot go and open, and
   choosing blind is not choosing.

   One line per candidate: title, site, approved or not, licence, format and what that format
   costs to integrate, `notes`, and the verified `source_url` and `thumbnail_url` as links.
   Every field is already in `.candidates.json`; this costs no turn and no launch.

   Do not editorialise about which looks *best*. That is the user's eye — which is why this
   stops here instead of downloading, and why the links go out *before* the question. A
   thumbnail and a page are what "which looks best" is made of.

3. **A pick** → Finishing.
   **"None of these"** → continue the SAME modeller via SendMessage with the user's reason, so
   it keeps its searches and can widen rather than starting cold. Then back to step 2.

Two rounds is the limit before going back to the user empty-handed. If two passes find
nothing, either the request needs rephrasing or the thing does not exist as CC0 — say which
you think it is.

## Finishing

Write `assets/incoming/<slug>.source.json`: the chosen candidate's object, plus `"chosen_at"`.
That file is the provenance record. Write it now, not later — the download happens outside
this pipeline, so this is the last moment anything knows where the asset came from.

Then tell the user:

- **The download link** for the one they picked.
- **Where to put the file** — next to its sidecar in `assets/incoming/`, keeping the slug.
- **The licence and what it obliges.** CC0 obliges nothing; say that plainly rather than
  leaving them to wonder whether it does.
- **Any domains appended to `candidates`** in `.claude/model-sources.json`, and that promoting
  one into `approved` is a manual edit they make, not something you do.

`assets/incoming/` is a **staging area, not a new convention.** This project keeps assets in
feature folders — `firefly/dragonfly8.glb`, `route setting/hoop_model.glb`. Moving the file
there, importing it and wiring it up is the Doer's job through `/build`.

**Before you send them off to download, check `assets/incoming/.gdignore` exists.** A pack
unzipped into an unfenced staging folder is imported by Godot in every format it ships — see
the trap in `CLAUDE.md`. Writing that one empty file is cheap here and expensive later, and
this is the moment you know a download is about to happen.

Do not import, launch the engine, or edit game code here. **This command spends zero engine
launches** — keep it that way, and it stays cheap enough to run beside other work.
