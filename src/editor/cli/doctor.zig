//! Toolchain diagnosis with explicitly approved zvm repairs.
const std = @import("std");
const zon_file = @import("eggy").assets.zon;
const required_zig = @import("build_options").zig_version;
const Prompt = @import("prompt.zig").Prompt;

pub const Options = struct {
    project: ?[]const u8 = null,
    fix: ?bool = null,
};

/// Check Zig's version, installation, cache and project build dependencies.
/// Repairing Zig selects the required version globally through zvm, only after consent.
/// Editor CLI only: uses `process` for tools/files and `prompt` for output/approval and arena
/// storage. May populate caches/dependencies and run the project's build configuration even
/// when repairs are declined. Probe sources are removed on return where possible; command,
/// validation and I/O errors propagate, without rolling back approved repairs.
///
/// ```zig
/// // Given process and Prompt pointers; explicitly decline optional repairs/prefetch:
/// try run(process, prompt, .{ .project = ".", .fix = false });
/// ```
pub fn run(process: *const std.process.Init, prompt: *Prompt, options: Options) !void {
    const directory = try prompt.text(options.project, "Project directory (or toolchain-only directory)", "project", ".");
    const dir = try std.fs.path.resolve(prompt.arena, &.{directory});
    var project = try std.Io.Dir.cwd().openDir(process.io, dir, .{});
    defer project.close(process.io);
    try prompt.output.print("Eggy requires Zig {s} (same major/minor). Recommended version manager: https://www.zvm.app\n", .{required_zig});
    if (!try checkVersion(process, prompt)) {
        const question = try std.fmt.allocPrint(prompt.arena, "Install/select Zig {s} with zvm? This changes your active Zig", .{required_zig});
        if (!try prompt.confirm(options.fix, question)) return error.ToolchainUnavailable;
        try prompt.output.flush();
        try execute(process, prompt, dir, &.{ "zvm", "install", required_zig });
        try execute(process, prompt, dir, &.{ "zvm", "use", required_zig });
        if (!try checkVersion(process, prompt)) {
            try prompt.output.writeAll("Put zvm's bin directory first on PATH, then run doctor again.\n");
            return error.ToolchainUnavailable;
        }
    }

    const env_result = try std.process.run(process.gpa, process.io, .{
        .argv = &.{ "zig", "env" },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer process.gpa.free(env_result.stdout);
    defer process.gpa.free(env_result.stderr);
    if (env_result.term != .exited or env_result.term.exited != 0) {
        try prompt.output.writeAll(env_result.stderr);
        return error.ZigEnvironmentFailed;
    }
    const Environment = struct { lib_dir: []const u8, global_cache_dir: []const u8 };
    const env = try zon_file.parse(Environment, prompt.arena, try prompt.arena.dupeSentinel(u8, env_result.stdout, 0), .{ .ignore_unknown_fields = true });
    const cwd = std.Io.Dir.cwd();
    try cwd.access(process.io, try std.fs.path.join(prompt.arena, &.{ env.lib_dir, "std", "std.zig" }), .{});
    try cwd.createDirPath(process.io, env.global_cache_dir);

    // A unique source verifies cache writes and an actual std-using compilation, without an executable.
    var random: [8]u8 = undefined;
    process.io.random(&random);
    const source = try std.fmt.allocPrint(prompt.arena, "{s}{c}eggy-doctor-{s}.zig", .{ env.global_cache_dir, std.fs.path.sep, std.fmt.bytesToHex(random, .lower) });
    const file = try cwd.createFile(process.io, source, .{ .exclusive = true });
    defer cwd.deleteFile(process.io, source) catch |err| std.log.warn("cannot remove doctor probe {s}: {t}", .{ source, err });
    {
        defer file.close(process.io);
        try file.writeStreamingAll(process.io, "const std = @import(\"std\"); export fn eggyDoctor() usize { return std.mem.len(@as([*:0]const u8, \"eggy\")); }\n");
    }
    try execute(process, prompt, dir, &.{ "zig", "build-obj", "-fno-emit-bin", source });
    try prompt.output.writeAll("OK: Zig standard library, compiler and writable cache.\n");

    project.access(process.io, "build.zig", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try prompt.output.writeAll("No build.zig here; toolchain checks passed. Use --project to check a game's dependencies.\n");
            return;
        },
        else => return err,
    };
    if (try prompt.confirm(options.fix, "Prefetch all project dependencies, including optional build tools?")) {
        try execute(process, prompt, dir, &.{ "zig", "build", "--fetch=all" });
    }
    // Evaluating the real build checks tool paths and fetches its needed dependencies.
    try execute(process, prompt, dir, &.{ "zig", "build", "--help" });
    try prompt.output.writeAll("OK: project build configuration and required dependencies.\n");
}

fn checkVersion(process: *const std.process.Init, prompt: *Prompt) !bool {
    const result = std.process.run(process.gpa, process.io, .{
        .argv = &.{ "zig", "version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try prompt.output.writeAll("Zig is not on PATH. Install zvm from https://www.zvm.app if it is not installed.\n");
            return false;
        },
        else => return err,
    };
    defer process.gpa.free(result.stdout);
    defer process.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        try prompt.output.writeAll(result.stderr);
        try prompt.output.writeAll("zig version failed.\n");
        return false;
    }
    const version = std.mem.trim(u8, result.stdout, " \t\r\n");
    try prompt.output.print("Zig on PATH: {s}\n", .{version});
    if (compatible(version)) return true;
    try prompt.output.print("Incompatible Zig; use zvm install {s} and zvm use {s}.\n", .{ required_zig, required_zig });
    return false;
}

fn compatible(text: []const u8) bool {
    const version = std.SemanticVersion.parse(text) catch return false;
    const required = std.SemanticVersion.parse(required_zig) catch unreachable;
    return version.major == required.major and version.minor == required.minor and version.order(required) != .lt;
}

fn execute(process: *const std.process.Init, prompt: *Prompt, dir: []const u8, argv: []const []const u8) !void {
    try prompt.output.print("$ {s}\n", .{try std.mem.join(prompt.arena, " ", argv)});
    try prompt.output.flush();
    var child = std.process.spawn(process.io, .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .stdin = .ignore,
    }) catch |err| {
        try prompt.output.print("Cannot start {s}: {t}. Install zvm from https://www.zvm.app for Zig repairs.\n", .{ argv[0], err });
        return err;
    };
    defer child.kill(process.io);
    const term = try child.wait(process.io);
    if (term != .exited or term.exited != 0) return error.DoctorCommandFailed;
}

test "Zig must match the engine's minor release and minimum version" {
    try std.testing.expect(compatible(required_zig));
    try std.testing.expect(!compatible("0.16.0"));
    try std.testing.expect(!compatible("0.18.0"));
    try std.testing.expect(!compatible("0.17.0-dev.1"));
    try std.testing.expect(!compatible("not a version"));
}
