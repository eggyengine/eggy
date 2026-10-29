//! Player Controller: Assets > New > Player Controller writes a first- or third-person player for a
//! 3D game into the project as Zig code of its own (`first_person.zig`, `third_person.zig`), for
//! the game to list and change as it likes. A dev plugin: the code is the project's, not this.
const std = @import("std");
const eggy = @import("eggy");

pub const Plugin = struct {
    pub const editor_file_types = [_]eggy.plugins.EditorFileType{
        .{ .key = "first_person", .title = "First Person 3D Player Controller", .extension = ".zig", .contents = @embedFile("first_person.zig"), .category = "Player Controller" },
        .{ .key = "third_person", .title = "Third Person 3D Player Controller", .extension = ".zig", .contents = @embedFile("third_person.zig"), .category = "Player Controller" },
    };
};

// The files it writes build against this Eggy, and their tests pass.
test {
    std.testing.refAllDecls(@import("first_person.zig"));
    std.testing.refAllDecls(@import("third_person.zig"));
}
