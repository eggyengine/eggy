//! Prepare cross-platform export toolchains before dependencies inspect their SDK headers.
const std = @import("std");
const android_build = @import("android.zig");

/// Reuse configured SDKs, otherwise install pinned official tools in Eggy's user cache.
/// Output streams to the export log; setup failure stops configuration before compilation.
pub fn prepare(b: *std.Build, target: std.Build.ResolvedTarget, emsdk: ?[]const u8, android_sdk: ?[]const u8) ?[]const u8 {
    const web = target.result.os.tag == .emscripten;
    const android = target.result.abi.isAndroid();
    if (!web and !android) return emsdk;
    const io = b.graph.io;
    b.cache_root.handle.createDirPath(io, "export-sdk") catch @panic("cannot create SDK setup state");
    const result = b.cache_root.join(b.allocator, &.{b.fmt("export-sdk/{s}-environment.json", .{if (web) "web" else "android"})}) catch @panic("OOM");
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(b.allocator, &.{
        if (b.graph.host.result.os.tag == .windows) "python" else "python3",
        b.path("src/build/sdk_setup.py").getPath(b),
        if (web) "web" else "android",
        "--result",
        result,
    }) catch @panic("OOM");
    if (if (web) emsdk else android_sdk) |root| args.appendSlice(b.allocator, &.{ "--root", root }) catch @panic("OOM");
    // The Android platform and NDK for the API level asked for; out of range, the build says so.
    if (android) {
        const api = std.math.clamp(android_build.apiOf(target.result), android_build.min_api, android_build.max_api);
        args.appendSlice(b.allocator, &.{ "--android-api", b.fmt("{d}", .{api}), "--ndk", android_build.ndkFor(api) }) catch @panic("OOM");
    }
    var child = std.process.spawn(io, .{ .argv = args.items, .environ_map = &b.graph.environ_map }) catch |err|
        std.debug.panic("export SDK setup requires Python 3.12+: {t}", .{err});
    defer child.kill(io);
    const term = child.wait(io) catch @panic("SDK setup was interrupted");
    if (term != .exited or term.exited != 0) {
        std.log.err("Export SDK setup failed; see the setup output above.", .{});
        std.process.exit(1);
    }
    const text = std.Io.Dir.cwd().readFileAlloc(io, result, b.allocator, .limited(64 * 1024)) catch @panic("cannot read SDK setup environment");
    const parsed = std.json.parseFromSlice(std.json.Value, b.allocator, text, .{}) catch @panic("invalid SDK setup environment");
    var values = parsed.value.object.iterator();
    while (values.next()) |entry| b.graph.environ_map.put(entry.key_ptr.*, entry.value_ptr.string) catch @panic("OOM");
    return if (web) b.graph.environ_map.get("EMSDK") else emsdk;
}
