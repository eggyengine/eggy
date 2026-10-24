//! Prepare cross-platform export toolchains before dependencies inspect their SDK headers.
const std = @import("std");
const android_build = @import("android.zig");

/// Reuse configured SDKs, otherwise install pinned official tools in Eggy's user cache.
/// Output streams to the export log; setup failure stops configuration before compilation.
pub fn prepare(b: *std.Build, target: std.Build.ResolvedTarget, emsdk: ?[]const u8, android_sdk: ?[]const u8) ?[]const u8 {
    const web = target.result.os.tag == .emscripten;
    const android = target.result.abi.isAndroid();
    if (!web and !android) return emsdk;
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(b.allocator, &.{
        if (b.graph.host.result.os.tag == .windows) "python" else "python3",
        b.root.joinString(b.allocator, "src/build/sdk_setup.py") catch @panic("OOM"),
        if (web) "web" else "android",
    }) catch @panic("OOM");
    if (if (web) emsdk else android_sdk) |root| args.appendSlice(b.allocator, &.{ "--root", root }) catch @panic("OOM");
    // The Android platform and NDK for the API level asked for; out of range, the build says so.
    if (android) {
        const api = std.math.clamp(android_build.apiOf(target.result), android_build.min_api, android_build.max_api);
        args.appendSlice(b.allocator, &.{ "--android-api", b.fmt("{d}", .{api}), "--ndk", android_build.ndkFor(api) }) catch @panic("OOM");
    }
    const text = switch (b.runFallible(args.items, .{})) {
        .success => |stdout| stdout,
        .spawn_failed => |err| std.debug.panic("export SDK setup requires Python 3.12+: {t}", .{err}),
        .bad_exit_code, .crashed => {
            std.log.err("Export SDK setup failed; see the setup output above.", .{});
            std.process.exit(1);
        },
    };
    const parsed = std.json.parseFromSlice(std.json.Value, b.allocator, text, .{}) catch @panic("invalid SDK setup environment");
    var values = parsed.value.object.iterator();
    while (values.next()) |entry| b.graph.environ_map.put(entry.key_ptr.*, entry.value_ptr.string) catch @panic("OOM");
    // A copy: another Eggy in the graph (a plugin's) re-runs setup, and `put` frees the old value.
    return if (web) b.dupe(b.graph.environ_map.get("EMSDK").?) else emsdk;
}
