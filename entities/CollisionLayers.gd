extends RefCounted
class_name CollisionLayers

# The project's physics layer registry, as NAMED BITS.
#
# WHY THIS FILE EXISTS. Godot's inspector numbers layers from 1; code shifts
# from bit 0. "Enemies" is editor layer 4 and `1 << 3`, and every place those
# two numbering schemes meet is a chance to be off by one - silently, because a
# body on the wrong layer still runs, still draws, and only stops colliding with
# something it was never watched colliding with. Naming the bits once removes
# the arithmetic from every call site.
#
# THE ONE PLACE A BODY'S LAYERS ARE ASSIGNED IS ITS SCRIPT, NOT ITS .tscn.
# tank.tscn and tank.gd used to both set them, which is two places to disagree
# and one of them silently winning (the script, in _ready, whatever the scene
# said). Picking the script rather than the scene is not arbitrary:
#
#   - a .tscn can only store the raw int, so it reads `collision_layer = 8` and
#     the reader has to redo exactly the 1-based/0-based conversion above;
#   - the script can say `CollisionLayers.ENEMIES`, which is the plan's mask
#     table transcribed rather than re-derived;
#   - a `.tscn` value silently overridden by `_ready()` is a comment that lies.
#
# So: no `collision_layer`/`collision_mask` line in any gameplay .tscn. Nodes
# that are not bodies (the tank's SpringArm3D and its ground RayCast3D) keep
# their own mask in the scene - what a camera arm collides with is scene
# dressing, not a layer allocation.
#
# THE WINDOW BEFORE _ready() IS REAL BUT NOT OBSERVABLE, and this was checked
# rather than assumed. Assigning in _ready() means a body carries Godot's
# default layer 1 from the moment it is constructed until its _ready() runs, so
# in principle a physics query in that gap would see a spawned body on the
# terrain layer. It cannot happen here: Tank._ready() runs before
# LevelRunner._ready(), a spawned body's _ready() runs synchronously inside the
# add_child() that creates it, and no physics step occurs anywhere in between.
# The same argument covers Spawner._place(), which add_child()s an entity before
# setting its global_position and so leaves it at the origin for the rest of
# that call.
# Anything that later spawns a body DURING gameplay should re-check this rather
# than inherit the conclusion.
#
# ALWAYS RE-MEASURE OFF THE LIVE NODE. These constants say what was intended;
# `--harness-eval="scene.tank.collision_mask"` says what happened.
#
# The full table, including the reserved bits, is in docs/foundation-plan.md.

## Editor layer 1. The terrain chunks' static bodies.
const TERRAIN := 1 << 0

## Editor layer 2. The player's tank.
const PLAYER := 1 << 1

## Editor layer 3. RESERVED AND UNUSED - player shells are raycasts and have no
## body at all (see shell.gd). Held empty rather than reused: point defence or
## shell-vs-shell would need to detect a shell, and renumbering afterwards is
## the expensive version of this decision.
const PLAYER_SHELLS := 1 << 2

## Editor layer 4. Guardian hulls and anything else that fights back.
const ENEMIES := 1 << 3

## Editor layer 5. RESERVED AND UNUSED, for the same reason as PLAYER_SHELLS.
const ENEMY_SHELLS := 1 << 4

## Editor layer 6. Destructible scenery - towers, and whatever else stands on the
## glen and can be shot down.
##
## A BIT OF ITS OWN, NOT A RENAMED `ENEMIES`. The obvious economy - nothing
## fights back any more, so reuse bit 3 - is wrong as soon as something does.
## Towers and enemy tanks want the SAME treatment in exactly one place, the
## shell's hit_mask, and different treatment everywhere else: an aggro query
## looks for a target on ENEMIES and must not find a tower, while the tank's
## chassis has to be stopped by both. One bit cannot say both things, and
## renumbering after the fact is the expensive version of this decision - which
## is the same argument PLAYER_SHELLS and ENEMY_SHELLS are held empty for.
##
## Bit 5 rather than 3 or 4: bits 3 and 4 are spoken for above, and bits 5 and up
## are free.
const STRUCTURES := 1 << 5
