//! What the Assets panel's New menus offer: Eggy's own kinds, then each plugin's file templates.
const std = @import("std");
const eggy = @import("eggy");
const FileType = eggy.plugins.EditorFileType;

pub const Entry = union(enum) {
    scene,
    folder,
    file: FileType,

    /// Return the editor menu caption, borrowing plugin title storage for file templates.
    ///
    /// ```zig
    /// const caption = (Entry{ .scene = {} }).label(); // "Scene"
    /// ```
    pub fn label(self: Entry) []const u8 {
        return switch (self) {
            .scene => "Scene",
            .folder => "Folder",
            .file => |file_type| file_type.title,
        };
    }
};

/// Eggy's own: what a game is made of, in the order their categories show in New. Plain text
/// files belong in the code editor, not here; plugins add their own kinds with `editor_file_types`.
const builtins = [_]Entry{
    .scene,
    .{ .file = .{
        .key = "eggy/material",
        .title = "Material",
        .extension = ".material.zon",
        .contents = ".{\n    .color = .{ 1, 1, 1, 1 },\n    .metallic = 0,\n    .roughness = 1,\n    .texture = \"\",\n    .normal_texture = \"\",\n    .metallic_roughness_texture = \"\",\n    .emissive_texture = \"\",\n    .occlusion_texture = \"\",\n    .emissive_color = .{ 0, 0, 0 },\n    .unlit = false,\n    .alpha_mode = .cutout,\n    .alpha_cutoff = 0.01,\n    .double_sided = false,\n    .shader = \"\",\n}\n",
        .category = "Rendering",
    } },
    .{ .file = .{
        .key = "eggy/surface_shader",
        .title = "Surface Shader",
        .extension = ".slang",
        .contents = surface_shader_template,
        .category = "Rendering",
    } },
    .{ .file = .{
        .key = "eggy/post_shader",
        .title = "Post Shader",
        .extension = ".slang",
        .contents = post_shader_template,
        .category = "Rendering",
    } },
    .{ .file = .{
        .key = "eggy/tilemap",
        .title = "Tilemap",
        .extension = eggy.assets.tilemap.extension,
        .contents = eggy.assets.tilemap.template,
        .category = "2D",
    } },
    .{ .file = .{
        .key = "eggy/animation_clip",
        .title = "Animation Clip",
        .extension = ".clip.zon",
        .contents = ".{\n    .format_version = 1,\n    .duration_s = 1,\n    .tracks = .{},\n}\n",
        .category = "Animation",
    } },
    .{ .file = .{
        .key = "eggy/ui_scene",
        .title = "UI Scene",
        .extension = eggy.assets.ui_scene.extension,
        .contents = eggy.assets.ui_scene.template,
        .category = "UI",
    } },
    .{ .file = .{
        .key = "eggy/input_map",
        .title = "Input Map",
        .extension = ".inmap.zon",
        .contents = ".{\n    .version = 1,\n    .controls = .{},\n}\n",
        .category = "Input",
    } },
    .folder,
};

/// A pass over the image, which a `PostProcess` lists in its `passes`.
const post_shader_template =
    \\#include "eggy.slang"
    \\
    \\// Runs for every pixel of the scene's light, before bloom and tone mapping.
    \\// `input.values` are the four values the pass is given in its PostProcess.
    \\float4 post(PostInput input) {
    \\    float3 color = sceneColor(input.uv);
    \\    // Fade towards grey by the pass's first value.
    \\    color = lerp(color, luminance(color).xxx, saturate(input.values.x));
    \\    return float4(color, 1.0);
    \\}
    \\
;

/// How a material's surface looks before it is lit, which a material names as its `shader`.
const surface_shader_template =
    \\#include "eggy.slang"
    \\
    \\// Runs for every point drawn with a material using this shader. Start from the surface
    \\// the material describes, change what you need, and Eggy lights the result.
    \\Surface surface(SurfaceInput input) {
    \\    Surface shown = defaultSurface(input);
    \\    // A slow glow in the surface's own colour.
    \\    shown.emissive += shown.base_color * (0.25 + 0.25 * sin(input.time_s * 2.0));
    \\    return shown;
    \\}
    \\
;

/// How many entries are Eggy's own; the plugins' follow, in plugin order.
pub const builtin_count = builtins.len;

/// The plugin that offers `file_type`: its key's part before the first `/`.
/// The returned slice borrows the template's key; no allocation or registry lookup occurs.
///
/// ```zig
/// // Given a plugin's EditorFileType named template:
/// const plugin_key = ownerOf(template);
/// ```
pub fn ownerOf(file_type: FileType) []const u8 {
    const key: []const u8 = file_type.key;
    return key[0 .. std.mem.indexOfScalar(u8, key, '/') orelse key.len];
}

/// Return the editor catalog size, including built-ins before the borrowed plugin templates.
///
/// ```zig
/// const builtin_total = count(&.{});
/// std.debug.assert(builtin_total == builtin_count);
/// ```
pub fn count(plugins: []const FileType) usize {
    return builtins.len + plugins.len;
}

/// The same catalog serves both the toolbar dropdown and the right-click submenu.
/// Return the zero-based entry, or null beyond `count(plugins)`; template strings remain borrowed.
///
/// ```zig
/// const first = at(0, &.{}).?;
/// std.debug.assert(std.mem.eql(u8, first.label(), "Scene"));
/// ```
pub fn at(index: usize, plugins: []const FileType) ?Entry {
    if (index < builtins.len) return builtins[index];
    if (index - builtins.len < plugins.len) return .{ .file = plugins[index - builtins.len] };
    return null;
}

test "built-in input maps are valid ZON and plugin templates extend the same catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input_map = for (builtins) |entry| {
        if (entry == .file and std.mem.eql(u8, entry.file.key, "eggy/input_map")) break entry.file;
    } else unreachable;
    _ = try eggy.input.asset.File.parse(arena.allocator(), try arena.allocator().dupeSentinel(u8, input_map.contents, 0));
    const plugins = [_]FileType{.{ .key = "game/material", .title = "Material", .extension = ".material.zon", .contents = ".{}" }};
    try std.testing.expectEqualStrings("Material", at(builtins.len, &plugins).?.label());
    try std.testing.expect(at(count(&plugins), &plugins) == null);
    try std.testing.expectEqualStrings("game", ownerOf(plugins[0]));
}
