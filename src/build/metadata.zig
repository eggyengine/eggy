//! What a game's executable says about itself, from its project's `eggy.zon`: the title (as the
//! product name), version and `.metadata` (company, description, copyright and the project's
//! own entries), and its icon. On Windows, `addTo` gives the executable a version information
//! resource, which its Properties show, and the icon Explorer shows; on every platform, `text` goes into the project module for the runtime to
//! keep in a section of its own (`.eggy_metadata` on Linux), which `readelf -p .eggy_metadata`
//! shows.
const std = @import("std");
const package_root = @import("package_root.zig");
const project = @import("../core/project.zig");

/// Name and value pairs, in the order they are kept.
pub const Pairs = []const project.Metadata.Entry;

/// The project's metadata as name and value pairs, empty ones left out; none without an
/// `eggy.zon` that reads.
/// Build-internal; result and strings live in `b`'s arena. Invalid/missing configuration
/// produces an empty list. Does not modify the project or escape values for a destination format.
///
/// ```zig
/// const pairs = metadata.read(b);
/// metadata.addTo(b, runtime_exe, pairs);
/// ```
pub fn read(b: *std.Build) Pairs {
    const config = readConfig(b) orelse return &.{};
    var pairs: std.ArrayList(project.Metadata.Entry) = .empty;
    const known = [_]project.Metadata.Entry{
        .{ .name = "ProductName", .value = config.title },
        .{ .name = "ProductVersion", .value = config.version },
        .{ .name = "FileVersion", .value = config.version },
        .{ .name = "CompanyName", .value = config.metadata.company },
        .{ .name = "FileDescription", .value = if (config.metadata.description.len > 0) config.metadata.description else config.title },
        .{ .name = "LegalCopyright", .value = config.metadata.copyright },
    };
    for (known) |pair| if (pair.value.len > 0) pairs.append(b.allocator, pair) catch @panic("OOM");
    for (config.metadata.extra) |pair| if (pair.name.len > 0) pairs.append(b.allocator, pair) catch @panic("OOM");
    return pairs.items;
}

/// The project's icon (`eggy.zon`'s `.icon`): an image file, relative to the project; null
/// without one, or without an `eggy.zon` that reads.
pub fn iconPath(b: *std.Build) ?[]const u8 {
    return (readConfig(b) orelse return null).icon;
}

fn readConfig(b: *std.Build) ?project.Config {
    const source = package_root.open(b).readFileAllocOptions(b.graph.io, project.file_name, b.allocator, .limited(1 << 20), .of(u8), 0) catch return null;
    return project.parse(b.allocator, source) catch null;
}

/// `pairs` as text, a `name=value` line each, for the section the runtime keeps them in.
/// Allocates in `b`'s arena and preserves pair order. This is display metadata, not an escaped
/// interchange format: embedded line breaks and equals signs are left unchanged.
///
/// ```zig
/// project_options.addOption([]const u8, "metadata_text", metadata.text(b, metadata.read(b)));
/// ```
pub fn text(b: *std.Build, pairs: Pairs) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pairs) |pair| out.print(b.allocator, "{s}={s}\n", .{ pair.name, pair.value }) catch @panic("OOM");
    return out.items;
}

/// On Windows, give `exe` a version information resource holding `pairs` (its version numbers
/// from `ProductVersion`) and `icon` (an `.ico`, from `icoFrom`) as its icon; elsewhere, nothing.
/// Build-internal; adds an escaped generated `.rc` input to `exe`, owned by the build graph.
/// No-op for empty pairs without an icon, or non-Windows targets. Missing/non-numeric version
/// parts remain zero.
///
/// ```zig
/// metadata.addTo(b, runtime_exe, metadata.read(b), null);
/// ```
pub fn addTo(b: *std.Build, exe: *std.Build.Step.Compile, pairs: Pairs, icon: ?std.Build.LazyPath) void {
    if (exe.rootModuleTarget().os.tag != .windows) return;
    const files = b.addWriteFiles();
    var rc: std.ArrayList(u8) = .empty;

    // The icon, beside the script that names it.
    if (icon) |ico| {
        _ = files.addCopyFile(ico, "icon.ico");
        rc.appendSlice(b.allocator, "1 ICON \"icon.ico\"\n") catch @panic("OOM");
    }

    // The version information.
    if (pairs.len > 0) {
        var version: [4]u16 = .{ 0, 0, 0, 0 };
        for (pairs) |pair| if (std.mem.eql(u8, pair.name, "ProductVersion")) {
            var parts = std.mem.tokenizeAny(u8, pair.value, ".-+");
            for (&version) |*number| number.* = std.fmt.parseInt(u16, parts.next() orelse break, 10) catch break;
        };
        rc.print(b.allocator,
            \\1 VERSIONINFO
            \\FILEVERSION {0d},{1d},{2d},{3d}
            \\PRODUCTVERSION {0d},{1d},{2d},{3d}
            \\FILETYPE 0x1
            \\BEGIN
            \\  BLOCK "StringFileInfo"
            \\  BEGIN
            \\    BLOCK "040904B0"
            \\    BEGIN
            \\
        , .{ version[0], version[1], version[2], version[3] }) catch @panic("OOM");
        for (pairs) |pair| rc.print(b.allocator, "      VALUE \"{s}\", \"{s}\"\n", .{ rcString(b, pair.name), rcString(b, pair.value) }) catch @panic("OOM");
        rc.appendSlice(b.allocator,
            \\    END
            \\  END
            \\  BLOCK "VarFileInfo"
            \\  BEGIN
            \\    VALUE "Translation", 0x409, 1200
            \\  END
            \\END
            \\
        ) catch @panic("OOM");
    }
    if (rc.items.len == 0) return;
    exe.root_module.addWin32ResourceFile(.{ .file = files.add("metadata.rc", rc.items), .include_paths = &.{files.getDirectory()} });
}

/// The packaged image `texture` (an `.eggtexture`) as a Windows `.ico`, converted on the host
/// by `ico.zig`, built with Eggy's builder `engine`.
///
/// ```zig
/// metadata.addTo(b, runtime_exe, pairs, metadata.icoFrom(b, engine, prepared.directory.path(b, key)));
/// ```
pub fn icoFrom(b: *std.Build, engine: *std.Build, texture: std.Build.LazyPath) std.Build.LazyPath {
    const host = engine.graph.host;
    const tool = engine.addExecutable(.{
        .name = "eggy_ico",
        .root_module = engine.createModule(.{
            .root_source_file = engine.path("src/build/ico.zig"),
            .target = host,
            .optimize = .fast,
            .imports = &.{.{ .name = "eggy_assets", .module = @import("models.zig").assetsModule(engine, host, .fast) }},
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(texture);
    return run.addOutputFileArg("icon.ico");
}

/// `value` as a resource script string's contents: quotes doubled, line breaks as spaces.
fn rcString(b: *std.Build, value: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |char| switch (char) {
        '"' => out.appendSlice(b.allocator, "\"\"") catch @panic("OOM"),
        '\n', '\r' => out.append(b.allocator, ' ') catch @panic("OOM"),
        else => out.append(b.allocator, char) catch @panic("OOM"),
    };
    return out.items;
}
