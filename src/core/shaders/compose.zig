//! A project's shader made whole: its `#include "eggy.slang"` replaced by Eggy's shader library, and
//! its function put into Eggy's own shader for its role, ready to compile as one Slang source.
const std = @import("std");

/// Eggy's shader library, which a project shader's `#include "eggy.slang"` stands for.
pub const library = @embedFile("eggy.slang");
const post_wrapper = @embedFile("post_pass.slang");
const surface_wrapper = @embedFile("mesh.slang");
const library_include = "#include \"eggy.slang\"";
/// What a project shader includes the library as; the bare name is what shaders wrote before
/// code editors were given the file (`.eggy/shaders/eggy.slang`), and still builds.
const project_includes = [_][]const u8{ "#include \"eggy.slang\"", "#include \"eggy\"" };

/// What a project's shader does, told by the input its function takes.
pub const Role = enum(u32) {
    /// `float4 post(PostInput input)`: a pass over the rendered image.
    post,
    /// `Surface surface(SurfaceInput input)`: how a material's surface looks before lighting.
    surface,
    /// `Surface terrainSurface(TerrainSurfaceInput input)`: how a Terrain's faces look before
    /// lighting.
    terrain,

    /// The entry point the composed source is compiled for.
    pub const entry_point = "fragmentMain";

    fn wrapper(self: Role) []const u8 {
        return switch (self) {
            .post => post_wrapper,
            .surface, .terrain => surface_wrapper,
        };
    }

    fn marker(self: Role) []const u8 {
        return switch (self) {
            .post => "// eggy: post\n",
            .surface => "// eggy: surface\n",
            .terrain => "// eggy: terrain\n",
        };
    }

    /// What the wrapper is told, so it leaves out its own function in the project's place.
    fn define(self: Role) []const u8 {
        return switch (self) {
            .post => "",
            .surface => "#define EGGY_SURFACE 1\n",
            .terrain => "#define EGGY_TERRAIN 1\n",
        };
    }
};

pub const Error = error{
    /// The shader doesn't `#include "eggy.slang"`.
    MissingEggyInclude,
    /// It takes none of `PostInput`, `SurfaceInput` and `TerrainSurfaceInput`.
    UnknownShaderRole,
    /// It mentions more than one, so it can't be told which it is.
    AmbiguousShaderRole,
};

/// What `source` is, by which of Eggy's inputs it mentions.
pub fn roleOf(source: []const u8) Error!Role {
    const post = std.mem.indexOf(u8, source, "PostInput") != null;
    // Every `TerrainSurfaceInput` holds a `SurfaceInput`, so only those beyond it count.
    const terrain_count = std.mem.count(u8, source, "TerrainSurfaceInput");
    const terrain = terrain_count > 0;
    const surface = std.mem.count(u8, source, "SurfaceInput") > terrain_count;
    if (@as(u2, @intFromBool(post)) + @intFromBool(surface) + @intFromBool(terrain) > 1) return error.AmbiguousShaderRole;
    if (post) return .post;
    if (surface) return .surface;
    if (terrain) return .terrain;
    return error.UnknownShaderRole;
}

/// The whole Slang source for project shader `source`, named `name` in diagnostics: Eggy's
/// wrapper for its role with the library inlined, and `source` at the wrapper's marker (its
/// include line left blank, so line numbers match the file). The caller owns the result.
pub fn compose(gpa: std.mem.Allocator, source: []const u8, name: []const u8) (Error || error{OutOfMemory})![:0]u8 {
    const role = try roleOf(source);
    const include, const include_len = for (project_includes) |spelling| {
        if (std.mem.indexOf(u8, source, spelling)) |at| break .{ at, spelling.len };
    } else return error.MissingEggyInclude;
    const wrapper = role.wrapper();
    const included = std.mem.indexOf(u8, wrapper, library_include).?;
    const marked = std.mem.indexOf(u8, wrapper, role.marker()).? + role.marker().len;

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const writer = &out.writer;
    // The wrapper up to its marker, with the library in place of its include.
    writer.writeAll(wrapper[0..included]) catch return error.OutOfMemory;
    // Inlined once, so its include guard would only draw Slang's warning.
    writer.writeAll(std.mem.trimStart(u8, library[std.mem.indexOf(u8, library, "#pragma once\n").? + "#pragma once\n".len ..], "\n")) catch return error.OutOfMemory;
    writer.writeAll(wrapper[included + library_include.len .. marked]) catch return error.OutOfMemory;
    // The project's shader, numbered as its own file.
    writer.writeAll(role.define()) catch return error.OutOfMemory;
    writer.print("#line 1 \"{s}\"\n", .{name}) catch return error.OutOfMemory;
    writer.writeAll(source[0..include]) catch return error.OutOfMemory;
    writer.writeAll(source[include + include_len ..]) catch return error.OutOfMemory;
    // The rest of the wrapper.
    writer.print("\n#line {d} \"eggy {t}\"\n", .{ std.mem.count(u8, wrapper[0..marked], "\n") + 1, role }) catch return error.OutOfMemory;
    writer.writeAll(wrapper[marked..]) catch return error.OutOfMemory;
    return out.toOwnedSliceSentinel(0);
}

test "a shader's role is told by its input, a terrain's apart from a surface's" {
    try std.testing.expectEqual(Role.terrain, try roleOf("Surface terrainSurface(TerrainSurfaceInput input) {}"));
    try std.testing.expectEqual(Role.surface, try roleOf("Surface surface(SurfaceInput input) {}"));
    try std.testing.expectEqual(Role.post, try roleOf("float4 post(PostInput input) {}"));
    try std.testing.expectError(error.AmbiguousShaderRole, roleOf("TerrainSurfaceInput a; SurfaceInput b;"));
}
