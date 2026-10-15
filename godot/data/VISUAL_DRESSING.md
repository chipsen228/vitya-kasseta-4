# Visual dressing integration contract

`VisualDressing.build(builder)` is called after the location modules have
filled `WorldBuilder.buckets`, and before `WorldBuilder._finish()` turns those
buckets into meshes. If `data/visual_dressing.json` is absent or invalid, the
call is a no-op.

The JSON has only three geometry arrays: `boxes`, `planes`, and
`atlas_quads`. Entries may carry `zone` and `cluster` labels for review, but
must never contain interaction or collision fields. Boxes are always emitted
with `collide=false`; atlas UV rectangles use pixels in a 512 x 512 atlas and
are bounds-checked before emission.

Boxes and planes use the existing semantic materials and material-bucket
machinery, but their runtime bucket key is prefixed with `visual:`. This keeps
small dressing from expanding the AABB (and shadow pass) of a large base-world
mesh. Materials additionally provide `dressing-paper-atlas` (opaque) and
`dressing-patina-atlas` (alpha-cut). All paper quads merge into one
`ArrayMesh`, all patina quads into a second one, and no visual bucket casts
shadows.

Recommended integration in `WorldBuilder`:

1. Add a `visual_dressing` result field and assign
   `visual_dressing = VisualDressing.build(self)` immediately before `_finish`.
2. In `_finish`, strip `visual:` before material lookup and disable shadow
   casting for every visual-only bucket.
3. Do not feed the layer to `CollisionWorld`, `Props`, `Interact`, `GameState`,
   nav baking, or story snapshots.

The repeated boards, tins, sacks, trim and distant windows intentionally use
the same bucket mechanism as the procedural world. Model-based scatter remains
owned by `Scatter`; additions there should be data-only `at` placements with
`shadow: false`, not duplicated by this schema.
