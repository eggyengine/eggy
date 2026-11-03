//! Entry point of Eggy's own editor executable (`eggy_editor` in Eggy's build): the launcher,
//! or with arguments the editor's command-line interface. A game's editor is `main.zig`.
const std = @import("std");
const eggy = @import("eggy");
const editor = @import("eggy_editor");
const LauncherApp = editor.LauncherApp;
const sdl3 = eggy.sdl_adapter.sdl;

comptime {
    _ = eggy.sdl_adapter.main_callbacks;
}

// SDL's main callbacks provide the real entry point.
pub const _start = void;
pub const WinMainCRTStartup = void;

/// Report panics as every Eggy executable does; see `eggy.entry.panic`.
pub const panic = std.debug.FullPanic(eggy.entry.panic);
/// Log through the editor's log function, so messages reach the same log file.
pub const std_options: std.Options = .{ .log_level = .debug, .logFn = editor.logFn };

// SDL's return-value adapter copies this through its startup stack, so it holds a pointer.
const State = struct {
    app: *LauncherApp,

    pub fn init(process: *const std.process.Init, args: []const [*:0]const u8) !State {
        const app = try process.gpa.create(LauncherApp);
        errdefer process.gpa.destroy(app);
        try app.init(process, args);
        return .{ .app = app };
    }

    pub fn iterate(self: *State) !sdl3.AppResult {
        return self.app.iterate();
    }

    pub fn event(self: *State, current: sdl3.events.Event) !sdl3.AppResult {
        return self.app.event(current);
    }

    pub fn deinit(self: *State) void {
        const gpa = self.app.gpa;
        self.app.deinit();
        gpa.destroy(self.app);
    }
};

const callbacks = eggy.entry.Callbacks(State);

/// SDL start-up: a command runs headless and exits; otherwise the launcher opens.
pub fn init(init_data: sdl3.Init) !struct { ?State, sdl3.AppResult } {
    if (editor.cli.isCommand(init_data.args)) {
        const process = try eggy.entry.processInit(init_data);
        editor.cli.run(process) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            return .{ null, .failure };
        };
        return .{ null, .success };
    }
    // Opened from the desktop, PATH may lack the zig every build runs.
    editor.process_environ.adoptShellPath(init_data.gpa);
    const state, const result = try callbacks.init(init_data);
    return .{ state, result };
}

/// SDL's per-frame callback, for the launcher state `init` returned.
pub fn iterate(state: *?State) !sdl3.AppResult {
    return callbacks.iterate(&state.*.?);
}

/// SDL's event callback, for the launcher state `init` returned.
pub fn event(state: *?State, current: sdl3.events.Event) !sdl3.AppResult {
    return callbacks.event(&state.*.?, current);
}

/// SDL's final callback: free the launcher, if one opened.
pub fn quit(state: ?*?State, result: sdl3.AppResult) void {
    callbacks.quit(if (state) |value| if (value.*) |*app| app else null else null, result);
}
