---
sidebar_position: 8
title: Render entities and cameras
slug: /guides/rendering-and-transforms
---

Create a Mesh entity and a Camera to draw a 3D scene, then move them through their
Transforms. The editor Scene view has its own camera while editing; the game uses
Camera entities.

## Spawn a mesh and camera

Use `app.world` from a game hook. Include each component the entity needs when
spawning it:

```zig
const cube = try app.world.spawn(.{
    eggy.Name.init("Cube"),
    eggy.Transform{ .position = .{ 0, 0.5, 0 } },
    eggy.Mesh{ .shape = .cube, .color = .{ 1, 0.55, 0.1 } },
});
const camera = try app.world.spawn(.{
    eggy.Transform{ .position = .{ 0, 2, 7 }, .rotation_deg = .{ -15, 0, 0 } },
    eggy.Camera{ .fov_deg = 60, .near = 0.1, .far = 1000 },
});
```

The Inspector and scene registry honor component `dependencies`. Direct native
`world.spawn` requires you to include those components yourself.

## Positions, directions, and parents

`Transform.position`, `rotation_deg`, and `scale` are relative to the parent.
Rotations are degrees around X, then Y, then Z; the local matrix scales, rotates, then
translates. Forward is -Z, right is +X, and up is +Y.

```zig
transform.translate(transform.forward());
transform.rotation_deg[1] += turn_deg_per_s * app.time.delta_s;
```

Use `forward`, `right`, and `up` for directions in the parent's space. They use the
entity's rotation without traversing parents.
`eggy.transform.worldMatrix(&app.world, entity)` composes the full parent chain.
`eggy.math` exposes the existing vector/matrix operations directly.

An entity without a Transform contributes an identity local matrix. A zero scale makes
the transform singular; inverse conversion can fail. Keep units in your own field names,
for example `speed_m_per_s` and `turn_deg_per_point`.

Mutating through a native query uses the ECS query API. When you edit a component
borrowed through `world.get` or `EntityRef.get`, call `world.markChanged(entity, T)`
if systems depend on change tracking. Editor tools should use
[`Action(T)` edits](../how-to/extend-editor.md), which record history and mark changes together.

## Find entities safely

`app.world` is the native Clutch world. Pointers returned by `world.get` or a query are
borrowed; do not keep them across structural changes, world resets, or library reloads.
Store an `EntityRef(T)` when a component needs to refer to another entity:

```zig
pub const Follow = struct {
    target: eggy.EntityRef(eggy.Transform) = .{},
};
```

Resolve it each time it is needed:

```zig
const target = follow.target.get(&app.world) orelse return;
target.position[1] += app.time.delta_s;
app.world.markChanged(follow.target.entity.?, eggy.Transform);
```

An unset, deleted or incompatible target resolves to null. `EntityRef(void).get` returns
a live entity ID instead of a component pointer. Inspector slots accept matching entities
from the Hierarchy; scene-local references are remapped on loading.

## Meshes and textures

Built-in shapes are cube, sphere, plane, cylinder, and cone. Use `.shape = .sphere`
or `eggy.mesh.Source.of(shape)` for a selected `eggy.mesh.Shape`.
For an imported static model:

```zig
const mesh = eggy.Mesh{
    .shape = .{ .model = .init("resources/models/ship.glb") },
    .texture = .init("resources/art/ship.png"),
    .color = .{ 1, 1, 1 },
};
```

The explicit texture overrides model-part textures and is tinted by the mesh color.
Without it, a model uses its imported textures; an untextured shape uses plain color.
The renderer owns GPU caches and prepares texture uploads outside render passes.
Use [resource loaders](../how-to/load-assets.md) when you need owned CPU data instead.

For custom rendering, `eggy.mesh.gatherAlloc(gpa, &app.world)` returns all drawables
without a fixed buffer limit. Free the slice with `gpa.free`; model and texture paths
still borrow the world's Mesh components. The non-allocating `gather(world, buffer)`
continues to return only as many drawables as fit.

Meshes outside each camera's frustum are culled using transformed bounds. Each view
retains the complete entity list for other cameras. The renderer accepts up to 4096
**visible** meshes per color or shadow pass; exceeding a pass's limit reports an error
instead of silently dropping the end of the scene. Profiling counters include culled
meshes across views.

## Check the game camera {#cameras-and-custom-drawing}

The game looks through an active Camera entity, placed by its world transform.
Higher `priority` wins; equal priorities use the lowest entity ID rather than query order.
Existing cameras default to active with priority zero. To switch exclusively:

```zig
try app.cameras().setActive(camera);
// Pass null to disable all game cameras.
```

Set `Camera.projection = .orthographic` and `orthographic_height_m` for a view whose
visible height stays constant with depth. Perspective cameras use `fov_deg`.
Run the game or enter Play in the editor to check the view through that Camera.
The first example should show an orange cube. If it is missing, check that the
Mesh and Camera entities each have a Transform and that you are viewing the game
camera, not the editor's editing camera.

A game with neither a camera nor UI/custom drawing shows the missing-camera notice.
UI-only and custom-renderer-only games can render without a camera.
If you need custom commands, use the
[`draw` hook](../how-to/game-ui.md#use-your-own-renderer). Do not create another swapchain
or independent presentation loop for the main window.

`Graphics` owns the device and main Surface; extra windows have their own Surface.
`beginFrame` waits for the reusable slot and returns a borrowed frame; `endFrame` submits
and presents it. Scene textures support offscreen rendering for panels. Most game code
does not need to manage these objects.

## Related rendering contracts

Materials, directional/point/spot lights and directional shadows have
[working components and reusable assets](materials-and-lighting.md).
[World sprites and text](world-drawing.md) share the scene camera and depth buffer.
[Debug lines, boxes and labels](debug-and-profile.md) are frame-owned overlays.
See [feature support](../reference/feature-support.md) for the remaining backend contracts.

See [ownership and reload](../explanation/ownership-and-reload.md) for borrowed world
storage and [game UI](../how-to/game-ui.md) for drawing over the scene.
