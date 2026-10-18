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

## Check the game camera {#cameras-and-custom-drawing}

The game looks through the first matching Camera entity, placed by its world transform.
There are no camera priorities, camera stacks, or global current camera to configure.
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

General materials, scene lighting, postprocessing, world text/sprites, particles, debug
drawing, and skeletal animation have
[missing-backend contracts](../reference/feature-support.md#capability-support).
Mesh color and texture rendering is implemented. The missing-backend contracts do not
add shaders or modify physics.

See [ownership and reload](../explanation/ownership-and-reload.md) for borrowed world
storage and [game UI](../how-to/game-ui.md) for drawing over the scene.
