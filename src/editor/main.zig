//! Entry point of a game's editor executable, desktop only. `addGame` compiles it against the
//! game's generated `eggy_project` module.
const std = @import("std");
const eggy = @import("eggy");
const editor = @import("eggy_editor");
const Editor = editor.Editor(@import("eggy_project"));
const sdl3 = eggy.sdl_adapter.sdl;

comptime {
    _ = eggy.sdl_adapter.main_callbacks;
}

// SDL's main callbacks provide the real entry point.
pub const _start = void;
pub const WinMainCRTStartup = void;

/// Executable panic namespace using the shared host reporter; see `eggy.entry.panic`
/// for the canonical reporting/termination contract and usage example.
pub const panic = std.debug.FullPanic(eggy.entry.panic);
/// Log through the editor, which keeps messages for its Console panel.
pub const std_options: std.Options = .{ .logFn = @import("eggy_editor").logFn };

// SDL's return-value adapter must not copy the editor's large state through its startup stack.
const State = struct {
    gui: *Editor,

    pub fn init(process: *const std.process.Init, args: []const [*:0]const u8) !State {
        const gui = try process.gpa.create(Editor);
        errdefer process.gpa.destroy(gui);
        gui.* = try Editor.init(process, args);
        return .{ .gui = gui };
    }

    pub fn iterate(self: *State) !sdl3.AppResult {
        return self.gui.iterate();
    }

    pub fn event(self: *State, current: sdl3.events.Event) !sdl3.AppResult {
        return self.gui.event(current);
    }

    pub fn deinit(self: *State) void {
        const gpa = self.gui.gpa;
        self.gui.deinit();
        gpa.destroy(self.gui);
    }
};

const callbacks = eggy.entry.Callbacks(State);

/// SDL editor-executable initialization callback, not a game/plugin API.
/// Borrows SDL's startup data; CLI invocations run headlessly and return a null editor with
/// success/failure, while GUI startup returns owned editor state plus its SDL result.
/// Callback infrastructure retains the process initialization; startup errors propagate to
/// SDL's entry adapter. Pair every successfully returned GUI state with `quit`.
///
/// ```zig
/// // SDL adapter supplies init_data and owns this callback lifecycle:
/// var state, const result = try init(init_data);
/// defer quit(&state, result);
/// // Only dispatch iterate/event when result == .run and state is non-null.
/// ```
pub fn init(init_data: sdl3.Init) !struct { ?State, sdl3.AppResult } {
    if (editor.cli.isCommand(init_data.args)) {
        const process = try eggy.entry.processInit(init_data);
        editor.cli.run(process) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            return .{ null, .failure };
        };
        return .{ null, .success };
    }
    const state, const result = try callbacks.init(init_data);
    return .{ state, result };
}

/// SDL per-frame callback for initialized GUI state; `state.*` must be non-null.
/// Advances/presents the editor through the shared entry callbacks, propagating frame errors.
/// Return `.run` to continue or a terminal result for SDL; never call after headless init.
///
/// ```zig
/// // SDL adapter, after init returned .run with a GUI:
/// const result = try iterate(&state);
/// // Stop callbacks and pass result to quit when result != .run.
/// _ = result;
/// ```
pub fn iterate(state: *?State) !sdl3.AppResult {
    return callbacks.iterate(&state.*.?);
}

/// SDL event callback for non-null GUI state, routing a borrowed SDL event through the
/// shared host callbacks. Propagates device/input/window errors; the return controls SDL's
/// continuation, including user-approved quit/reload. Does not transfer event ownership.
///
/// ```zig
/// // SDL adapter, between GUI frames:
/// const result = try event(&state, current);
/// _ = result; // Adapter stops on a terminal result and then calls quit.
/// ```
pub fn event(state: *?State, current: sdl3.events.Event) !sdl3.AppResult {
    return callbacks.event(&state.*.?, current);
}

/// SDL final callback: destroy GUI resources if present and finish shared entry cleanup.
/// Accepts absent state after CLI/startup termination; `result` is SDL's final application
/// result. Call once, with no subsequent frame/event callback or access to destroyed state.
///
/// ```zig
/// // SDL adapter after its callback loop (state is the optional value from init):
/// quit(&state, final_result);
/// // Headless/no-state shutdown may instead use quit(null, final_result).
/// ```
pub fn quit(state: ?*?State, result: sdl3.AppResult) void {
    callbacks.quit(if (state) |value| if (value.*) |*gui| gui else null else null, result);
}
