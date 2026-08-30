# A `--harness-eval` property read that fails may mean the wrong OBJECT, not the wrong value

- date: 2026-08-30
- surfaced-by: reviewer
- run: /begin S3 - The big world
- target: claude.md

**Evidence.** Re-measuring the roadmap's own named check for S3, three forms failed on what
looked like the obvious path:

    scene.terrain.field.ground.max_world_gradient
      -> ERROR: Invalid named index 'max_world_gradient' for base type Object
    scene.terrain.field.ground.get('max_world_gradient')
      -> <null>            # no error, no failed exit of its own
    scene.terrain.field.ground['max_world_gradient']
      -> ERROR: Invalid index of type String for base type Object

while `scene.terrain.field.ground.vertical_extent()` and `.surface_height(0,0)` on the same
object returned correct numbers. The error message names "base type Object", which reads as a
limit of the harness. It is not. One expression settled it:

    scene.terrain.field.ground.get_script().resource_path
      -> res://terrain/sdf/SDFComposite.gd

`field.ground` is an `SDFComposite`; the `SDFHeightmap` is `field.ground.layers[0]`, and
`...layers[0].max_world_gradient` returned `1.89957169805485` first try. Cost: 2 of this
session's 23 launches, spent building a theory about `get()` on Resources that was wrong.
The `<null>` form is the dangerous one - a missing property and a genuinely null value print
identically, so "the value is null" is an available and wrong conclusion, and it points at the
change under review rather than at the expression.

**What it suggests.** A line in CLAUDE.md's dev-harness section: when an eval property read
errors or returns `<null>`, the next expression is `<base>.get_script().resource_path`, not a
different accessor - the harness is more often right about the object than the caller is.
Prefer the dotted form over `get('x')`, because it at least errors. This is the same
instrument CLAUDE.md already names under "when a change moves a resource reference, the
evidence is the reference"; the note there is about proving a reference arrived, and it is
equally the first move when a read off one fails.
