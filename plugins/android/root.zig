//! Android export: File > Export's Android platform, a test-signed APK for the Android version
//! and processor chosen. Eggy's build packages the APK (`src/build/android.zig`, which sets up
//! the Android SDK, NDK and JDK the first time); this plugin offers the platform and turns its
//! settings into the `-Dtarget` it builds for. `icon.png` is Android's logo from Simple Icons
//! (simpleicons.org, CC0 1.0), Google's trademark, used only to name the platform.
const std = @import("std");
const builtin = @import("builtin");
const eggy = @import("eggy");

/// The oldest Android a game can run on, as an API level, from the range Eggy's build takes
/// (`src/build/android.zig`'s `min_api`..`max_api`).
pub const ApiLevel = enum(u32) {
    android_13 = 33,
    android_14 = 34,
    android_15 = 35,
    android_16 = 36,

    /// Each level as File > Export lists it, oldest first.
    pub const labels = blk: {
        const versions = [_][]const u8{ "13", "14", "15", "16" };
        var all: [versions.len][]const u8 = undefined;
        for (&all, versions, std.enums.values(ApiLevel)) |*label, version, level| label.* = std.fmt.comptimePrint("Android {s} (API {d})", .{ version, @backingInt(level) });
        break :blk all;
    };
};

/// The processor a game is built for: ARM64 for phones and tablets, x86-64 for emulators.
pub const Architecture = enum {
    arm64,
    x86_64,

    pub const labels = [_][]const u8{ "ARM64 (phones and tablets)", "x86-64 (emulators)" };
};

pub const Plugin = struct {
    /// What File > Export builds for; it starts from the preferences, and choices there last
    /// until the game's code is rebuilt.
    api_level: ApiLevel,
    architecture: Architecture,

    pub const Preferences = struct {
        api_level: ApiLevel = .android_15,
        architecture: Architecture = .arm64,

        pub const descriptions = .{
            .api_level = "The oldest Android an export runs on, unless File > Export picks another.",
            .architecture = "The processor an export is built for, unless File > Export picks another.",
        };
    };

    pub const export_platforms = [_]eggy.plugins.ExportPlatform{.{
        .key = "android",
        .title = "Android",
        .target = "aarch64-linux-android.35",
        .note = "A test-signed APK for the Android version chosen and later, on devices with Vulkan 1.3. Sets up the Android SDK, NDK and JDK if needed. Not for store release.",
        .icon_png = @embedFile("icon.png"),
        .zips = false,
    }};

    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Plugin {
        _ = gpa;
        const chosen = app.preferences(Preferences);
        return .{ .api_level = chosen.api_level, .architecture = chosen.architecture };
    }

    /// The Android version and processor, on the Android platform only.
    pub fn exportUi(self: *Plugin, platform: eggy.plugins.ExportTarget, editor: *eggy.editor.Context, ui: *eggy.ui.Context) !void {
        _ = editor;
        if (platform.own == null) return;
        if (unavailable) |why| ui.alert("Not from this computer", why, false);
        var rows = eggy.setting_rows.SettingRows{};
        eggy.setting_rows.beginGroup(ui);
        rows.begin(ui, "Android version", "The oldest Android the game runs on. A version is downloaded the first time it is used.");
        var level = std.mem.indexOfScalar(ApiLevel, std.enums.values(ApiLevel), self.api_level).?;
        if (ui.select("##android version", &ApiLevel.labels, &level)) self.api_level = std.enums.values(ApiLevel)[level];
        rows.end(ui);
        rows.begin(ui, "Architecture", "The processor the game runs on.");
        var architecture: usize = @backingInt(self.architecture);
        if (ui.select("##android architecture", &Architecture.labels, &architecture)) self.architecture = @fromBackingInt(@intCast(architecture));
        rows.end(ui);
        eggy.setting_rows.endGroup(ui);
    }

    /// Build for the Android version and processor chosen.
    pub fn exportArgs(self: *Plugin, platform: eggy.plugins.ExportTarget, args: *eggy.plugins.ExportArgs) !void {
        if (platform.own == null) return;
        if (unavailable != null) return error.UnsupportedHost;
        try args.buildFor(try self.target(args.arena));
    }

    /// `-Dtarget` for the choices, in `arena`.
    fn target(self: Plugin, arena: std.mem.Allocator) ![]const u8 {
        const cpu = switch (self.architecture) {
            .arm64 => "aarch64",
            .x86_64 => "x86_64",
        };
        return std.fmt.allocPrint(arena, "{s}-linux-android.{d}", .{ cpu, @backingInt(self.api_level) });
    }
};

/// Why this computer can't build for Android, or null when it can: the Android tools Eggy sets
/// up run on macOS and on Linux on x86-64.
const unavailable: ?[]const u8 = if (builtin.os.tag == .macos or (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64))
    null
else
    "Export for Android from macOS, or Linux on x86-64: the Android tools Eggy sets up run there.";

test "the choices become the -Dtarget Android builds for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plugin = Plugin{ .api_level = .android_13, .architecture = .x86_64 };
    try std.testing.expectEqualStrings("x86_64-linux-android.33", try plugin.target(arena.allocator()));
    try std.testing.expectEqualStrings("Android 16 (API 36)", ApiLevel.labels[3]);
}

test "the plugin compiles" {
    std.testing.refAllDecls(Plugin);
}
