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

    /// The entry point the composed source is compiled for.
    pub const entry_point = "fragmentMain";

    fn wrapper(self: Role) []const u8 {
        return switch (self) {
            .post => post_wrapper,
            .surface => surface_wrapper,
        };
    }

    fn marker(self: Role) []const u8 {
        return switch (self) {
            .post => "// eggy: post\n",
            .surface => "// eggy: surface\n",
        };
    }
};

pub const Error = error{
    /// The shader doesn't `#include "eggy.slang"`.
    MissingEggyInclude,
    /// It takes neither a `PostInput` nor a `SurfaceInput`.
    UnknownShaderRole,
    /// It mentions both, so it can't be told which it is.
    AmbiguousShaderRole,
};

/// What `source` is, by which of Eggy's inputs it mentions.
pub fn roleOf(source: []const u8) Error!Role {
    const post = std.mem.indexOf(u8, source, "PostInput") != null;
    const surface = std.mem.indexOf(u8, source, "SurfaceInput") != null;
    if (post and surface) return error.AmbiguousShaderRole;
    if (post) return .post;
    if (surface) return .surface;
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
    if (role == .surface) writer.writeAll("#define EGGY_SURFACE 1\n") catch return error.OutOfMemory;
    writer.print("#line 1 \"{s}\"\n", .{name}) catch return error.OutOfMemory;
    writer.writeAll(source[0..include]) catch return error.OutOfMemory;
    writer.writeAll(source[include + include_len ..]) catch return error.OutOfMemory;
    // The rest of the wrapper.
    writer.print("\n#line {d} \"eggy {t}\"\n", .{ std.mem.count(u8, wrapper[0..marked], "\n") + 1, role }) catch return error.OutOfMemory;
    writer.writeAll(wrapper[marked..]) catch return error.OutOfMemory;
    return out.toOwnedSliceSentinel(0);
}

test "a post shader is put into the post wrapper with the library inlined" {
    const source =
        \\#include "eggy.slang"
        \\float4 post(PostInput input) { return float4(1.0 - sceneColor(input.uv), 1.0); }
    ;
    try std.testing.expectEqual(Role.post, try roleOf(source));
    const whole = try compose(std.testing.allocator, source, "invert.slang");
    defer std.testing.allocator.free(whole);
    try std.testing.expect(std.mem.indexOf(u8, whole, "#include") == null);
    try std.testing.expect(std.mem.indexOf(u8, whole, "struct PostInput") != null);
    const user = std.mem.indexOf(u8, whole, "1.0 - sceneColor").?;
    try std.testing.expect(std.mem.indexOf(u8, whole, "float3 sceneColor").? < user);
    try std.testing.expect(std.mem.indexOf(u8, whole, "fragmentMain").? > user);
    try std.testing.expect(std.mem.indexOf(u8, whole, "#line 1 \"invert.slang\"").? < user);
}

test "a surface shader replaces the mesh shader's default surface" {
    const source =
        \\#include "eggy"
        \\Surface surface(SurfaceInput input) { return defaultSurface(input); }
    ;
    const whole = try compose(std.testing.allocator, source, "plain.slang");
    defer std.testing.allocator.free(whole);
    try std.testing.expect(std.mem.indexOf(u8, whole, "#include") == null);
    try std.testing.expect(std.mem.indexOf(u8, whole, "#define EGGY_SURFACE 1").? < std.mem.indexOf(u8, whole, "#ifndef EGGY_SURFACE").?);
    try std.testing.expect(std.mem.indexOf(u8, whole, "vertexMain") != null);
}

test "a shader without Eggy's include or a role is refused" {
    try std.testing.expectError(error.MissingEggyInclude, compose(std.testing.allocator, "float4 post(PostInput input) { return 0; }", "a.slang"));
    try std.testing.expectError(error.UnknownShaderRole, roleOf("#include \"eggy\"\nfloat4 main() { return 0; }"));
    try std.testing.expectError(error.AmbiguousShaderRole, roleOf("PostInput SurfaceInput"));
}
