const std = @import("std");
const eggy = @import("eggy");

pub fn main(init: std.process.Init) !void {
    var game = try eggy.Editor.init(init);
    defer game.deinit();
    try game.run();
}
