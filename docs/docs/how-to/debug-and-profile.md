---
title: Debug drawing and profiling
---

## Draw gameplay diagnostics

Debug requests belong to one host frame. Submit them from `update` while playing, or
`editorUpdate` while editing:

```zig
try app.debug_draw.line(.zero, .init(0, 2, 0), .{ 1, 0, 0, 1 });
try app.debug_draw.box(.init(-1, 0, -1), .init(1, 2, 1), .{ 0, 1, 0, 1 });
try app.debug_draw.text(.init(0, 2, 0), "Spawn point");
```

Positions are world-space metres. Lines and boxes take RGBA in 0–1. Labels copy their
UTF-8 text, so temporary strings can be freed immediately after the call.

The engine draws requests through the runtime camera or the editor's Scene camera.
They are overlays: they remain visible through scene geometry, do not receive input, and
do not require a `gameUi` or `draw` hook. Lines are clipped against the camera frustum;
labels behind the camera are omitted.

A frame holds up to 1024 line segments and 128 labels of at most 256 bytes. A box needs
twelve segments and is recorded all-or-nothing. Invalid coordinates, colors, bounds,
UTF-8 or capacity exhaustion return explicit errors. Requests clear before the next
frame's hooks; startup-only requests are not persistent gizmos.

## Measure CPU work

```zig
const sample = try app.profiling.begin("Enemy AI");
// Do the work to measure.
try app.profiling.end(sample);
try app.profiling.counter("Active enemies", @floatFromInt(enemy_count));
```

Names are copied. Each sample must end in the same frame on the same collector; stale,
already-ended or invalid handles are errors. Nested samples are allowed. Repeating a
counter name updates that frame's value. Finish samples on error paths too.

Open **Help > DevTools > Game** to see the last completed CPU frame, timing samples,
entity count, scene draw calls, meshes, triangles, cached textures and light count.
Scene render counters include every rendered view and selection-outline passes, not UI
draws. The automatically recorded **ECS update** sample covers world systems and queued
scene replacement.

The collector supports 128 samples and 64 distinct counters per frame, including host
counters. Names are 1–96 UTF-8 bytes. Values must be finite; capacity exhaustion and
unfinished samples are errors rather than silently missing measurements.

Games can read `app.profiling.last` without the editor. It remains stable while the next
frame is collected. These are CPU wall-clock measurements, not GPU timestamps; frame
time includes presentation waits and host work.
