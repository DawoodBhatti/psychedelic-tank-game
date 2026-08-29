# psychedelic-tank-game

_prototyping a 3d game_ — Godot 4.7, GDScript.

A minimalist prototype inspired by *Wild Metal Country* and *Deep Rock Galactic*.
🧠 Procedural terrain meets chunky tank combat, with dynamic environment destruction built in
and currently switched **off** behind `Terrain.destructible`.

---

## 🚀 Core mechanics (built)

| Feature | How it works |
|---|---|
| 🌄 Procedural hills | fBm Perlin heightmap expressed as a signed distance field (`terrain/sdf/SDFHills.gd`), meshed by CPU marching cubes. |
| 💥 Destructible world — **off by default** | A shell subtracts a sphere from the shared field and only the chunks it reaches are re-meshed (`Terrain.carve()`). Real holes, not dents — overhangs and see-through gaps included. Nothing is removed: `Terrain.destructible` is `false`, so the terrain simply does not subscribe to the shell bus. Set it true — in `main.tscn` or at runtime — and destruction is back exactly as it was. |
| 🛞 Tank physics | `CharacterBody3D` with drag-limited drive, speed-scaled steering, boost and handbrake. The body only yaws; the visible lean over slopes is applied to the hull mesh, so input never stops meaning what it says. |
| 🎯 Turret | Aimed in **world space**, so the gun holds its target while the hull turns underneath it. Camera shares the gun's elevation. |
| 🧨 Fireable shells | Raycast-swept rather than simulated, so a 95 m/s shell cannot tunnel through a crater lip. Impact point is exact, because it is the centre of the crater. |
| 🌈 Neon terrain | World-space triplanar grid, height-driven hue ramp and rim glow (`terrain/shaders/neon_terrain.gdshader`), with a trip mode on `F`. |

Everything talks through the `GameEvents` bus: the shell does not know the terrain exists,
and the terrain does not know what hit it.

---

## 🎮 Controls

| Input | Action |
|---|---|
| `W` / `S` | Drive forward / reverse |
| `A` / `D` | Steer |
| `Space` | Boost |
| `Shift` | Handbrake |
| `Mouse` | Turret aim |
| `Left Click` | Fire shell |
| `R` | Respawn (also restores the terrain) |
| `F` | Trip mode |
| `T` | Toggle the controls overlay |

Gamepad is bound in parallel: left stick drives, right stick aims, triggers boost and brake,
`A` fires.

---

## 🛠 Tech

- **Engine:** Godot 4.7 (mono build), Jolt physics, D3D12
- **Terrain:** CPU marching cubes over a shared SDF — ported from
  [`../flying-game-prototype`](../flying-game-prototype) (repo name: `marching-cubes-prototype`)
- **No plugins.** FastNoiseLite and `ArrayMesh` are enough.

---

## 🤖 Working on this project

This repo carries the same agent pipeline as the prototype it came from. **Read `CLAUDE.md`
first** — it is the operational contract, and several of the traps in it will make a change
look correct when it is not.

```bash
.claude/scripts/gd.sh --headless --quit-after 120            # compile
.claude/scripts/gd.sh --headless -- --harness-check-resources # resources
.claude/scripts/newest-log.sh                                 # newest session log
```

- `/build <task>` runs the Doer/Reviewer loop. One per session — the budgets do not reset.
- `/source-model <thing>` finds CC0 assets and hands back links; downloading is a human step.
- `/consolidate` folds `.claude/learnings/` into the pipeline, in a fresh session.
- The reasoning behind every rule lives in `.claude/pipeline-notes.md`, which is not
  auto-loaded.

Ask the running game questions rather than assuming:

```bash
.claude/scripts/gd.sh --headless -- --harness-eval="scene.chunks_total" --harness-eval="scene.terrain_triangles"
```

---

## 🧪 Milestones

### ✅ Core setup
- [x] Procedural terrain generation
- [x] Basic tank movement & camera
- [x] Fireable shells

### ✅ Destructibility
- [x] Chunk-based terrain damage
- [ ] Particle and sound feedback — particles and flash done, **no audio yet**
- [ ] Environmental hazards

### 🚧 Next
- Enemy tanks and a reason to shoot them
- Time dilation to go with the trip mode
- Terrain that remembers damage across a reset

---

## 💡 Inspiration

- [Wild Metal Country (Rockstar)](https://www.youtube.com/watch?v=XEwILwkeQqE)
- [Deep Rock Galactic](https://www.deeprockgalactic.com/)
- [Procedural Destruction in Godot](https://www.youtube.com/watch?v=FgF3oFrAwUY)
- [Sci-fi shield shader](https://godotshaders.com/shader/scifi-shield/)
- [Shadertoy tsScRK](https://www.shadertoy.com/view/tsScRK)

---

## 📄 License

MIT

---

## 🌌 Author(s)

Ali Bhatti // Designed with Copilot
Feel free to fork, remix, and prototype your own version!
