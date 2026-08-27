extends Resource
class_name SpawnGroup

# One line of a level's spawn manifest: what to scatter, how many, and on what
# kind of ground.
#
# This is the resource that makes a second level cost a .tres rather than code.
# The Spawner reads nothing else about what it is placing - not the archetype,
# not the mesh, not the stats - so a level that wants twelve of something
# somewhere else adds a SpawnGroup and changes no script at all.

## Name used for the spawned nodes and for this group's line in the spawn log.
## Keep it a valid node-name fragment: entities are named "<id>_<index>", which
## is also how a harness eval reaches one.
@export var id: String = "group"

## What to instance. Anything deriving Node3D; it does not need a body, a script
## or a Damageable.
@export var scene: PackedScene

## How many to place. Every one that cannot be placed is a spawn_failure, which
## is the number the session gate is written against.
@export var count: int = 1

## Which ground this group belongs on. Left null, anywhere inside the world will
## do - which is a scatter, not a placement, and should be a deliberate choice.
@export var placement: PlacementRule

## How far above the surface the entity's origin is dropped.
##
## Small and positive rather than exactly zero: an entity whose collision box
## starts intersecting the terrain is resolved by the physics engine pushing it
## out, which for a static body means it simply overlaps and for anything else
## means it is launched. This is the same reasoning as LevelDef.spawn_clearance,
## which does the same job for the tank; it is per-group because a two-metre
## turret and a knee-high rock do not want the same number.
@export var ground_clearance: float = 0.5

## Minimum distance in the XZ plane to any other placed entity or reserved
## point. Where two groups meet, the LARGER of their two separations wins - the
## rule is symmetric, so neither group can be crowded by the other declaring
## itself small.
@export var separation: float = 10.0

## Randomises yaw on placement. Off, every entity in the group faces +Z, which
## reads as a bug rather than as a scatter.
@export var random_yaw: bool = true
