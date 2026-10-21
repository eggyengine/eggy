//! Test-only fixtures for the project asset tests: a throwaway project folder and a glTF model
//! with one clip.
const std = @import("std");

/// A fixture project in a new folder under `.zig-cache`, removed with `close`.
pub const Fixture = struct {
    path: []u8,
    dir: std.Io.Dir,

    pub fn open(gpa: std.mem.Allocator, io: std.Io) !Fixture {
        var random: [8]u8 = undefined;
        io.random(&random);
        const path = try std.fmt.allocPrint(gpa, ".zig-cache/editor-project-assets-{x}", .{random});
        errdefer gpa.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
        return .{ .path = path, .dir = try std.Io.Dir.cwd().openDir(io, path, .{}) };
    }

    pub fn close(self: *Fixture, gpa: std.mem.Allocator, io: std.Io) void {
        self.dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        gpa.free(self.path);
    }
};

/// One triangle with a blend shape that the "smile" clip turns on over one second.
pub const smiling_triangle =
    \\{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"name":"face","mesh":0}],"meshes":[{"name":"tri","weights":[0],"primitives":[{"attributes":{"POSITION":0},"indices":2,"targets":[{"POSITION":1}]}]}],"animations":[{"name":"smile","samplers":[{"input":3,"output":4}],"channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[0,0,2]},{"bufferView":2,"componentType":5123,"count":3,"type":"SCALAR"},{"bufferView":3,"componentType":5126,"count":2,"type":"SCALAR","min":[0],"max":[1]},{"bufferView":4,"componentType":5126,"count":2,"type":"SCALAR"}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":36},{"buffer":0,"byteOffset":72,"byteLength":6},{"buffer":0,"byteOffset":80,"byteLength":8},{"buffer":0,"byteOffset":88,"byteLength":8}],"buffers":[{"byteLength":96,"uri":"data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAIAAAAAAAAAAACAPwAAAAAAAIA/"}]}
;
