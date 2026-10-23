//! Eggy's own export platforms: what each is called, the settings it offers, whether this
//! computer can build for it, and the `zig build export` arguments its settings become.
const std = @import("std");
const builtin = @import("builtin");
const eggy = @import("eggy");
const ui = eggy.ui;

pub const Platform = eggy.plugins.BuiltinPlatform;
pub const count = std.meta.fields(Platform).len;

/// The processor a game is built for.
pub const Architecture = enum {
    x86_64,
    aarch64,

    pub fn label(architecture: Architecture, platform: Platform) []const u8 {
        return switch (architecture) {
            .x86_64 => if (platform == .macos) "Intel" else "x86-64",
            .aarch64 => if (platform == .macos) "Apple silicon" else "ARM64",
        };
    }
};

/// What the export is built for, as `-Dexport-optimize` names it.
pub const Optimize = enum {
    speed,
    size,
    safety,
    debugging,

    pub const labels = [_][]const u8{ "Speed", "Size", "Speed, with safety checks", "Debugging" };

    pub fn mode(optimize: Optimize) std.builtin.OptimizeMode {
        return switch (optimize) {
            .speed => .ReleaseFast,
            .size => .ReleaseSmall,
            .safety => .ReleaseSafe,
            .debugging => .Debug,
        };
    }
};

/// The C library a Linux game links: glibc, which most desktop distributions use, or musl,
/// which Alpine and other small systems use.
pub const Libc = enum {
    glibc,
    musl,

    pub const labels = [_][]const u8{ "glibc", "musl" };
};

/// The MacOSX.sdk folder's path, as typed.
pub const SdkPath = ui.TextEdit(512);

/// What the person chose for one platform, kept while the Export window is open.
pub const Settings = struct {
    architecture: Architecture,
    optimize: Optimize = .speed,
    /// Linux only.
    libc: Libc = .glibc,
    /// Tuned for this computer's processor, rather than any of its kind.
    this_cpu: bool = false,
    /// Zip the game's folder beside it (desktop platforms).
    zip: bool = true,
    /// macOS from another system: where its SDK is.
    sdk: SdkPath = SdkPath.init("") catch unreachable,

    /// Each platform's settings to start from: this computer's architecture for its own system,
    /// else the platform's usual one.
    ///
    /// ```zig
    /// var settings: [platforms.count]Settings = platforms.Settings.defaults();
    /// ```
    pub fn defaults() [count]Settings {
        var all: [count]Settings = undefined;
        for (&all, 0..) |*settings, i| {
            const platform: Platform = @enumFromInt(i);
            const choices = architectures(platform);
            const host_index = if (platform == this_system) std.mem.indexOfScalar(Architecture, choices, hostArchitecture()) orelse 0 else 0;
            settings.* = .{ .architecture = choices[host_index] };
        }
        return all;
    }
};

/// What a platform is called and what it builds.
pub fn title(platform: Platform) []const u8 {
    return switch (platform) {
        .windows => "Windows",
        .macos => "macOS",
        .linux => "Linux",
        .web => "Web",
    };
}

/// A line on what a platform's export is and what it needs.
pub fn note(platform: Platform) []const u8 {
    return switch (platform) {
        .windows => "A folder with the game's .exe, and a ZIP of it. Zig carries what Windows needs.",
        .macos => if (builtin.os.tag == .macos)
            "A folder with the game, and a ZIP of it, built with this Mac's SDK."
        else
            "A folder with the game, and a ZIP of it. Building from another system needs a macOS SDK.",
        .linux => "A folder with the game, and a ZIP of it, for Linux on the architecture and C library chosen.",
        .web => "A page and its files for a web server. Sets up emsdk if needed, or uses $EMSDK or ~/emsdk.",
    };
}

/// The architectures a platform can be built for from this computer, the first the default.
pub fn architectures(platform: Platform) []const Architecture {
    return switch (platform) {
        .web => &.{.x86_64},
        .windows, .linux => &.{ .x86_64, .aarch64 },
        .macos => &.{ .aarch64, .x86_64 },
    };
}

/// Whether macOS exports need the person to say where its SDK is: not on a Mac, which has one.
pub const needs_macos_sdk = builtin.os.tag != .macos;

/// Where Eggy's build looks for a macOS SDK when none is given: `$HOME/SDKs`, in `arena`.
pub fn defaultMacSdk(arena: std.mem.Allocator) ?[]const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    return std.fs.path.join(arena, &.{ home, "SDKs" }) catch null;
}

/// What a Linux game built with `libc` goes without, or null when it has everything.
pub fn libcNote(libc: Libc) ?[]const u8 {
    return switch (libc) {
        .glibc => null,
        .musl => "Without screen reader support or compiling shaders while it runs: their libraries are built for glibc.",
    };
}

/// The `-Dtarget` `platform` builds for with `settings`: `native` for this Linux computer's own
/// architecture and glibc, so the game links its libraries (GTK, for the error dialog).
pub fn target(platform: Platform, settings: Settings) []const u8 {
    return switch (platform) {
        .linux => if (builtin.os.tag == .linux and builtin.abi.isGnu() and settings.architecture == hostArchitecture() and settings.libc == .glibc)
            "native"
        else switch (settings.libc) {
            .glibc => if (settings.architecture == .aarch64) "aarch64-linux-gnu" else "x86_64-linux-gnu",
            .musl => if (settings.architecture == .aarch64) "aarch64-linux-musl" else "x86_64-linux-musl",
        },
        .web => "wasm32-emscripten",
        .windows => if (settings.architecture == .aarch64) "aarch64-windows-gnu" else "x86_64-windows-gnu",
        .macos => if (settings.architecture == .aarch64) "aarch64-macos" else "x86_64-macos",
    };
}

/// Whether `platform`'s export is a folder that can be zipped (not a page).
pub fn zips(platform: Platform) bool {
    return platform == .windows or platform == .macos or platform == .linux;
}

/// Whether `settings` builds for this computer's own system and processor, so it can be tuned
/// to its CPU.
pub fn buildsForThisCpu(platform: Platform, settings: Settings) bool {
    return platform == this_system and settings.architecture == hostArchitecture();
}

/// This computer's own system, where the Export window starts.
pub const this_system: Platform = switch (builtin.os.tag) {
    .macos => .macos,
    .windows => .windows,
    else => .linux,
};

/// The `zig build export` arguments for Eggy's own settings, in `arena`: the target, the scene
/// the game starts in, and what was chosen. `sdk` is the macOS SDK to build with, if any.
///
/// ```zig
/// const args = try platforms.exportArgs(arena, .windows, settings, "resources/main.scene.zon", null);
/// ```
pub fn exportArgs(arena: std.mem.Allocator, platform: Platform, settings: Settings, scene: []const u8, sdk: ?[]const u8) !std.ArrayList([]const u8) {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(arena, try std.fmt.allocPrint(arena, "-Dtarget={s}", .{target(platform, settings)}));
    try args.append(arena, try std.fmt.allocPrint(arena, "-Dscene={s}", .{scene}));
    try args.append(arena, try std.fmt.allocPrint(arena, "-Dexport-optimize={t}", .{settings.optimize.mode()}));
    if (zips(platform) and !settings.zip) try args.append(arena, "-Dexport-zip=false");
    if (settings.this_cpu and buildsForThisCpu(platform, settings)) try args.append(arena, "-Dcpu=native");
    if (platform == .macos) if (sdk) |path| try args.appendSlice(arena, &.{ "--sysroot", path });
    return args;
}

fn hostArchitecture() Architecture {
    return if (builtin.cpu.arch == .aarch64) .aarch64 else .x86_64;
}

test "settings become zig build export arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const settings = Settings{ .architecture = .aarch64, .optimize = .size, .zip = false };
    const args = try exportArgs(arena.allocator(), .macos, settings, "resources/main.scene.zon", "/sdk");
    const expected = [_][]const u8{ "-Dtarget=aarch64-macos", "-Dscene=resources/main.scene.zon", "-Dexport-optimize=ReleaseSmall", "-Dexport-zip=false", "--sysroot", "/sdk" };
    try std.testing.expectEqual(expected.len, args.items.len);
    for (expected, args.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "linux builds for the architecture and C library chosen" {
    const settings = Settings{ .architecture = .aarch64, .libc = .musl };
    try std.testing.expectEqualStrings("aarch64-linux-musl", target(.linux, settings));
}

test "the web is neither zipped nor tuned to this computer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const settings = Settings{ .architecture = .x86_64, .this_cpu = true, .zip = false };
    const args = try exportArgs(arena.allocator(), .web, settings, "resources/main.scene.zon", null);
    try std.testing.expectEqual(@as(usize, 3), args.items.len);
}
