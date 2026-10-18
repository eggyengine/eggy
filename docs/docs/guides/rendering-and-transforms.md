---
sidebar_position: 8
title: Rendering and transforms
---

# Rendering and transforms

Start with scene components rather than GPU commands. Native ECS spawning is explicit:
include the components a rendered entity needs.

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

The Inspector and scene registry honor component `dependencies`. A direct native
`world.spawn` does not replace that with hidden engine construction.

## Positions, directions, and parents

`Transform.position`, `rotation_deg`, and `scale` are relative to the parent.
Rotations are degrees around X, then Y, then Z; the local matrix scales, rotates, then
translates. Forward is -Z, right is +X, and up is +Y.

```zig
transform.translate(transform.forward());
transform.rotation_deg[1] += turn_deg_per_s * app.time.delta_s;
```

`forward`, `right`, and `up` use the entity's rotation in its parent's space. They do
not silently traverse parents. `eggy.transform.worldMatrix(&app.world, entity)` composes
the full parent chain. `eggy.math` exposes the existing vector/matrix operations directly.

An entity without a Transform contributes an identity local matrix. A zero scale makes
the transform singular; inverse conversion can fail. Keep units in your own field names,
for example `speed_m_per_s` and `turn_deg_per_point`.

Mutating through a native query uses the ECS query API. When you edit a component
borrowed through `world.get` or `EntityRef.get`, call `world.markChanged(entity, T)`
if systems depend on change tracking. Editor tools should use
[`Action(T)` edits](editor-tools.md), which record history and mark changes together.

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
Use [resource loaders](assets-and-scenes.md) when you need owned CPU data instead.

For custom rendering, `eggy.mesh.gatherAlloc(gpa, &app.world)` returns all drawables
without a fixed buffer limit. Free the slice with `gpa.free`; model and texture paths
still borrow the world's Mesh components. The non-allocating `gather(world, buffer)`
continues to return only as many drawables as fit.

## Cameras and custom drawing

The game looks through the first matching Camera entity, placed by its world transform.
This change does not introduce camera priorities, camera stacks, or a global current camera.
The editor Scene view has its own camera while editing.

A game with neither a camera nor UI/custom drawing shows the missing-camera notice.
UI-only and custom-renderer-only games can render without a camera.
Use the [`draw` hook](game-ui.md#use-your-own-renderer) for custom commands, not another
swapchain or an independent presentation loop.

`Graphics` owns the device and main Surface; extra windows have their own Surface.
`beginFrame` waits for the reusable slot and returns a borrowed frame; `endFrame` submits
and presents it. Scene textures support offscreen rendering for panels. Most game code
does not need to manage these objects.

General materials, scene lighting, postprocessing, world text/sprites, particles, debug
drawing, and skeletal animation are explicit [missing-backend contracts](developer-api.md#capability-support).
Current Mesh color/texture rendering remains real; those contracts do not add new shaders
or modify physics.
