//! The editor's command-line interface, dispatched before GUI initialization.
const std = @import("std");
const cli = @import("cli");
const projects = @import("projects.zig");
const doctor = @import("doctor.zig");
const Prompt = @import("prompt.zig").Prompt;

// zig-cli actions have no context argument; this entry point runs once on the main thread.
var context: struct {
    process: *const std.process.Init,
    prompt: *Prompt,
    new: projects.New = .{},
    export_game: projects.Export = .{},
    doctor: doctor.Options = .{},
} = undefined;

/// No arguments and the existing GUI launch flags retain the normal SDL entry point.
/// Inspect process arguments including argv[0]; other first arguments select headless parsing.
/// This pure routing check borrows the null-terminated argument strings.
///
/// ```zig
/// std.debug.assert(isCommand(&.{ "eggy_editor", "doctor" }));
/// std.debug.assert(!isCommand(&.{ "game_editor", "--project", "/games/demo" }));
/// ```
pub fn isCommand(args: []const [*:0]const u8) bool {
    if (args.len <= 1) return false;
    const first = std.mem.span(args[1]);
    return !std.mem.eql(u8, first, "--project") and !std.mem.eql(u8, first, "--window");
}

/// Parse and execute one headless command. Errors go to the terminal, never a modal dialog.
/// Editor executable only: call once on the main thread, before SDL initialization, with the
/// real process environment. Commands may spawn tools, write projects/exports, or perform
/// approved toolchain repairs; parser, I/O and command failures propagate. Borrowed process
/// state need only survive this call; local I/O, runner and output buffers are cleaned up.
///
/// ```zig
/// // Given the editor entry point's original std.process.Init pointer:
/// try run(process);
/// ```
pub fn run(original_process: *const std.process.Init) !void {
    // SDL's Io has no process environment; subprocess lookup needs the real PATH.
    var threaded: std.Io.Threaded = .init(original_process.gpa, .{ .environ = original_process.minimal.environ });
    defer threaded.deinit();
    var process_value = original_process.*;
    process_value.io = threaded.io();
    const process = &process_value;
    var input_buffer: [16 * 1024]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(process.io, &input_buffer);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(process.io, &output_buffer);
    defer output.interface.flush() catch |err| std.debug.print("error writing CLI output: {t}\n", .{err});
    var prompt = Prompt{ .arena = process.arena.allocator(), .input = &input.interface, .output = &output.interface };
    context = .{ .process = process, .prompt = &prompt };
    var runner = cli.AppRunner.init(process);
    defer runner.deinit();
    const unattended = cli.Option{
        .long_name = "non-interactive",
        .help = "Never prompt: use defaults, or fail if a required answer is missing",
        .value_ref = runner.mkRef(&prompt.non_interactive),
    };
    const app = cli.App{
        .version = @import("build_options").version,
        .command = .{
            .name = "eggy_editor",
            .description = .{ .one_line = "Eggy editor: no arguments opens the GUI; commands run without a window." },
            .target = .{ .subcommands = &.{
                .{
                    .name = "doctor",
                    .description = .{ .one_line = "Check Zig, its standard library/cache and project dependencies; offer zvm repairs." },
                    .options = &.{
                        .{ .long_name = "project", .help = "Project directory (default: current directory)", .value_ref = runner.mkRef(&context.doctor.project), .value_name = "DIR" },
                        .{ .long_name = "fix", .help = "Approve zvm install/select and dependency prefetch; --fix=false declines repairs", .value_ref = runner.mkRef(&context.doctor.fix) },
                        unattended,
                    },
                    .target = .{ .action = .{ .exec = runDoctor } },
                },
                .{
                    .name = "export",
                    .description = .{ .one_line = "Export a project's ReleaseFast game as a folder and ZIP." },
                    .options = &.{
                        .{ .long_name = "project", .help = "Project directory (default: current directory)", .value_ref = runner.mkRef(&context.export_game.project), .value_name = "DIR" },
                        .{ .long_name = "scene", .help = "Startup scene path (default: eggy.zon's default_scene)", .value_ref = runner.mkRef(&context.export_game.scene), .value_name = "PATH" },
                        .{ .long_name = "target", .help = "Zig target triple (default: native)", .value_ref = runner.mkRef(&context.export_game.target), .value_name = "TRIPLE" },
                        unattended,
                    },
                    .target = .{ .action = .{ .exec = runExport } },
                },
                .{
                    .name = "new",
                    .description = .{ .one_line = "Create and build a project from the editor's bundled template." },
                    .options = &.{
                        .{ .long_name = "title", .help = "Project title", .value_ref = runner.mkRef(&context.new.title), .value_name = "TEXT" },
                        .{ .long_name = "name", .help = "Zig package name (default: derived from title)", .value_ref = runner.mkRef(&context.new.name), .value_name = "NAME" },
                        .{ .long_name = "directory", .help = "New project's directory (default: package name)", .value_ref = runner.mkRef(&context.new.directory), .value_name = "DIR" },
                        .{ .long_name = "open", .help = "Open the project's GUI after building", .value_ref = runner.mkRef(&context.new.open) },
                        unattended,
                    },
                    .target = .{ .action = .{ .exec = runNew } },
                },
            } },
        },
    };
    try runner.run(&app);
    try output.interface.flush();
}

fn runNew() !void {
    try projects.create(context.process, context.prompt, context.new);
}

fn runExport() !void {
    try projects.exportGame(context.process, context.prompt, context.export_game);
}

fn runDoctor() !void {
    try doctor.run(context.process, context.prompt, context.doctor);
}

test "headless routing preserves GUI startup and reload flags" {
    try std.testing.expect(!isCommand(&.{"eggy_editor"}));
    try std.testing.expect(!isCommand(&.{ "game_editor", "--project", "/game" }));
    try std.testing.expect(!isCommand(&.{ "game_editor", "--window", "1,2,800,600,0", "--project", "/game" }));
    for ([_][*:0]const u8{ "doctor", "export", "new", "--help", "--version", "typo" }) |command| {
        try std.testing.expect(isCommand(&.{ "eggy_editor", command }));
    }
}

test {
    _ = @import("prompt.zig");
    _ = projects;
    _ = doctor;
}
