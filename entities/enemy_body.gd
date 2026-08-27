extends StaticBody3D
class_name EnemyBody

# The foundation plan's "Enemy body | layer 4 | masks 1, 2" row, made real.
#
# WHAT IT IS. A hull that occupies space, can be shot at and can be driven into.
# It has hit points because a Damageable hangs off it, and it looks like
# something because a SkinSlot hangs off it. It has no brain, no sensors and no
# gun: acquiring and shooting are session F, and a guardian that thinks is not
# something this session is allowed to build.
#
# STATIC ON PURPOSE, FOR NOW. The first guardian archetype in the plan is a
# fixed turret, which is genuinely static; the hunter that moves is a different
# archetype and will need a different body. Making this one a CharacterBody3D in
# advance would be a physics cost paid every frame by something that does not
# move, in exchange for guessing right about a class that does not exist yet.
#
# COLLISION LAYERS ARE SET HERE AND NOWHERE ELSE. See CollisionLayers' header
# for why the script rather than the .tscn. Masking TERRAIN and PLAYER matches
# the plan's table: the tank can drive into a guardian, and a guardian sits on
# the ground. It does NOT mask ENEMIES - guardians do not collide with each
# other, which keeps a cluster of them on one ridge from shoving itself apart.


func _ready() -> void:
	collision_layer = CollisionLayers.ENEMIES
	collision_mask = CollisionLayers.TERRAIN | CollisionLayers.PLAYER
