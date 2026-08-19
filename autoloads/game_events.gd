extends Node

# Autoloaded signal bus.
#
# The pattern: anything that HAPPENS in the world announces it here, and
# anything that CARES listens here. Emitters never look up listeners and
# listeners never look up emitters, so neither needs to know where the other
# sits in the scene tree - or whether it exists at all.
#
# That is what lets a shell blow a hole in the terrain without the shell ever
# holding a reference to the terrain, and what lets audio or screen shake be
# added later without editing the tank, the shell or the level.
#
# What belongs here: events more than one system reacts to, or that cross
# between unrelated parts of the tree. What does NOT: a parent talking to its
# own child (the tank's turret is a plain child and stays one) - routing that
# through a global bus would hide a relationship that is genuinely local.

# --- Gunnery ---------------------------------------------------------------

## A shell left the barrel. Carries the shell so UI and effects can follow it.
signal shell_fired(shell: Node3D)

## A shell hit something and detonated, at `position`, with a blast of
## `radius` world units.
##
## This is the load-bearing one. The Terrain listens and carves; the explosion
## effect listens and spawns; anything added later (shake, audio, scoring)
## listens too. The shell itself knows none of them - it announces and frees
## itself, which is why the same shell scene works whether or not a terrain is
## in the tree at all.
signal shell_exploded(position: Vector3, radius: float)

# --- Terrain ---------------------------------------------------------------

## Terrain material has actually been removed and the affected chunks have
## finished re-meshing. Separate from shell_exploded on purpose: that one is
## "a bang happened", this one is "the world is different now", and only the
## second is safe to measure geometry against.
signal terrain_carved(position: Vector3, radius: float, chunks_rebuilt: int)

# --- Scene lifecycle -------------------------------------------------------

## The active gameplay scene has finished building itself and has drawn a
## frame. Anything that must not run against a half-built scene - performance
## sampling above all - gates on this.
##
## On the bus rather than local to the scene because the things that wait for
## it (the perf sampler, the dev harness) are autoloads with no relationship to
## whichever scene happens to be loaded. Emitting it here means a second scene
## can raise it later without the listeners changing at all.
signal loading_complete(scene_name: String)

# --- Run state -------------------------------------------------------------

## The run is over and the level should be put back to its starting state.
## `reason` is "fell" or "manual" (the respawn key). The tank emits this rather
## than resetting itself, because what a reset RESTORES is the level's business
## and the tank has no idea what the level contains.
signal level_reset_requested(reason: String)

## The tank has been placed back at the start of a run. Separate from the
## request above: the request is "something should happen", this is "it has
## happened", which is the one effects and audio want.
signal tank_respawned()

# --- Drive -----------------------------------------------------------------

## Boost has started or stopped. Edge-triggered, not per-frame, so a listener
## can start and stop a looping sound or an effect without tracking state
## itself.
signal boost_started()
signal boost_ended()
