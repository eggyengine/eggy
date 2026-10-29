---
title: First- and third-person players
---

The **Player Controller** plugin writes a player for a 3D game into your project as Zig code,
which is then yours to change. New projects start with it installed; in an older project,
install it from **Edit > Plugins...**, under **Made by Eggy** (see
[Install plugins](install-plugins.md)). It's a dev plugin, so exported games leave it out:
they only need the code it wrote.

In the Assets panel, open your project's `src` folder and choose **New > Player Controller >
First Person 3D Player Controller** or **Third Person 3D Player Controller**, then name the
file. Both walk with WASD or the left stick, look with the mouse or right stick, and sprint
with Shift or the controller's west button. The first-person player looks out of a camera at
eye height. The third-person player orbits a camera over its shoulder and turns to face
where it walks, so give it your character's model as a child.

The comment at the top of the file shows what to add to your game: list its component and
controls, and call its `update` from yours.

```zig
const first_person = @import("first_person_player.zig");

pub const Game = struct {
    pub const components = .{first_person.FirstPersonPlayer};
    pub const input_maps = .{first_person.Controls};

    pub fn update(self: *Game, app: *eggy.App) !void {
        try first_person.update(app);
    }

    /// Playing stopped or paused: give the mouse back.
    pub fn editorUpdate(self: *Game, editor: *eggy.editor.Context) !void {
        try first_person.releaseMouse(editor.app);
    }
};
```

Then add the component to an entity in the Inspector. The player makes its own camera when
the game starts. Its fields set the speeds, look sensitivity, field of view and how far up
and down it can look, and for the third-person player how far behind and to the side the
camera sits. Click in the game to capture the mouse, and press Escape to let it go.
