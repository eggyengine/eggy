//! The graphics options as Weeoui cards (a card per option, its name and note on the left and its
//! control on the right), shared by the player's graphics menu, the editor's Graphics
//! preferences and the Project section's defaults. It edits a draft `Settings`; whoever shows it
//! decides when the draft is applied.
const std = @import("std");
const ui = @import("weeoui");
const render_settings = @import("../render_settings.zig");

const Settings = render_settings.Settings;
const Capabilities = render_settings.Capabilities;
const NumberEdit = ui.TextEdit(12);
const control_width: f32 = 240;
const render_scale_step: f32 = 0.05;

const backend_labels = [_][]const u8{ "Automatic", "Vulkan", "Direct3D 12", "WebGPU" };
const present_mode_labels = [_][]const u8{ "Automatic", "On (VSync)", "Adaptive VSync", "Low latency (triple buffered)", "Off (may tear)" };
const anti_aliasing_labels = [_][]const u8{ "Off", "2x MSAA", "4x MSAA", "8x MSAA", "FXAA" };
const texture_filter_labels = [_][]const u8{ "Nearest (pixelated)", "Linear (smooth)" };
const window_mode_labels = [_][]const u8{ "Windowed", "Borderless fullscreen" };
const anisotropy_levels = [_]u16{ 1, 2, 4, 8, 16 };

/// What the caller can do with the buttons `Form.buttons` shows.
pub const Action = enum { apply, restore_defaults, cancel };

/// What a form shows of the machine and the game.
pub const Options = struct {
    /// What this machine and window can do: only those choices are offered. Borrowed for the frame.
    caps: *const Capabilities,
    /// A GPU is a machine's choice, so a project's defaults leave it out.
    adapter: bool = true,
    /// The backend `caps.adapters` belong to. A draft on any other backend can't pick from them
    /// (an index means a different GPU there), so the card stays Automatic until a restart.
    /// Null skips the check.
    adapters_backend: ?render_settings.Backend = null,
};

/// A draft of the graphics settings and the text behind its number fields. Keep it where it
/// lives as long as its UI is open: the fields' text is edited in place.
pub const Form = struct {
    draft: Settings = .{},
    width: NumberEdit = NumberEdit.init("900") catch unreachable,
    height: NumberEdit = NumberEdit.init("675") catch unreachable,
    frame_limit: NumberEdit = NumberEdit.init("0") catch unreachable,
    /// What the last Apply said, shown above the buttons until the draft changes.
    message: [200]u8 = undefined,
    message_len: usize = 0,
    message_kind: enum { none, saved, restart, failed } = .none,

    /// Replace the draft, its number fields and any message with `settings`.
    /// Touches only this form.
    ///
    /// ```zig
    /// form.load(app.graphics_options.requested);
    /// ```
    pub fn load(self: *Form, settings: Settings) void {
        self.draft = settings;
        setNumber(&self.width, settings.width);
        setNumber(&self.height, settings.height);
        setNumber(&self.frame_limit, settings.frame_limit);
        self.message_kind = .none;
    }

    /// The draft, with the number fields' text read in: a field that isn't a whole number
    /// is an error, naming what it was for.
    ///
    /// ```zig
    /// try app.saveGraphicsSettings(try form.read());
    /// ```
    pub fn read(self: *const Form) error{ InvalidWindowSize, InvalidFrameLimit }!Settings {
        var result = self.draft;
        result.width = parseNumber(u32, &self.width) orelse return error.InvalidWindowSize;
        result.height = parseNumber(u32, &self.height) orelse return error.InvalidWindowSize;
        result.frame_limit = parseNumber(u16, &self.frame_limit) orelse return error.InvalidFrameLimit;
        return result;
    }

    /// Show what applying the draft did: a success (noting a restart when one is needed) or why
    /// it failed, so a failure is never silent.
    ///
    /// ```zig
    /// form.report(app.saveGraphicsSettings(try form.read()));
    /// ```
    pub fn report(self: *Form, result: anyerror!render_settings.ApplyResult) void {
        const applied = result catch |err| {
            const text = std.fmt.bufPrint(&self.message, "Can't use these settings: {s}", .{describe(err)}) catch &self.message;
            self.message_len = text.len;
            self.message_kind = .failed;
            return;
        };
        const text = switch (applied) {
            .queued => "Applied and saved.",
            .restart_required => "Saved. The graphics API, GPU or vertical sync changes the next time the game starts.",
        };
        @memcpy(self.message[0..text.len], text);
        self.message_len = text.len;
        self.message_kind = if (applied == .queued) .saved else .restart;
    }

    /// Declare a card per option the machine offers, editing the draft. Returns whether the
    /// draft changed this frame. Call in a frame with an active `context`; borrows nothing past it.
    ///
    /// ```zig
    /// if (form.build(context, .{ .caps = &caps })) project_dirty = true;
    /// ```
    pub fn build(self: *Form, context: *ui.Context, options: Options) bool {
        const before = self.draft;
        const caps = options.caps;
        const draft = &self.draft;
        const arena = context.builder().allocator;

        beginCard(context, "Graphics API", "What draws the game. Takes effect after the game restarts.");
        // A GPU chosen for the old backend means nothing on the new one.
        if (pick(context, "##graphics api", render_settings.Backend, &draft.backend, &backend_labels, caps.backends)) draft.adapter_index = null;
        endCard(context);

        const adapters_listed = adaptersFit(options, draft.backend);
        if (options.adapter and caps.adapter_count > 0 and !adapters_listed) {
            beginCard(context, "Graphics card", "Cards are listed for the graphics API in use. Restart with this API to choose one.");
            context.muted(if (draft.adapter_index == null) "Automatic" else "Chosen earlier, for the next start");
            endCard(context);
        } else if (options.adapter and caps.adapter_count > 0) {
            beginCard(context, "Graphics card", "Which GPU draws the game. Takes effect after the game restarts.");
            // Names live in the frame's arena: the caller's capabilities may not outlive it.
            const names = arena.alloc([]const u8, caps.adapter_count + 1) catch return false;
            names[0] = "Automatic";
            for (caps.adapters[0..caps.adapter_count], names[1..]) |*adapter, *name| name.* = arena.dupe(u8, adapter.nameSlice()) catch return false;
            var selected: usize = if (draft.adapter_index) |index| @min(@as(usize, index) + 1, caps.adapter_count) else 0;
            if (context.select("##graphics card", names, &selected)) draft.adapter_index = if (selected == 0) null else @intCast(selected - 1);
            endCard(context);
        }

        if (caps.window_settings) {
            beginCard(context, "Window mode", "Borderless fullscreen fills the screen without changing its resolution.");
            _ = pick(context, "##window mode", render_settings.WindowMode, &draft.window_mode, &window_mode_labels, .initFull());
            endCard(context);
            if (draft.window_mode == .windowed) {
                beginCard(context, "Window size", "How big the window opens, in pixels.");
                context.begin(.row);
                _ = context.textInput("##window width", &self.width, "900");
                context.text("×");
                _ = context.textInput("##window height", &self.height, "675");
                context.end();
                endCard(context);
            }
        }

        beginCard(context, "Vertical sync", "Waits for the screen to refresh: no tearing, but more delay. Takes effect after the game restarts.");
        _ = pick(context, "##present mode", render_settings.PresentMode, &draft.present_mode, &present_mode_labels, caps.present_modes);
        endCard(context);

        if (caps.frame_limit) {
            beginCard(context, "Frame rate limit", "Frames per second, up to 1000. 0 is unlimited.");
            _ = context.textInput("##frame limit", &self.frame_limit, "0");
            endCard(context);
        }

        beginCard(context, "Render scale", "How many pixels the 3D scene is drawn at, from 0.25x to 2x. Below 1 is faster, above 1 is crisper. The interface stays sharp.");
        var scale = draft.render_scale;
        if (context.slider("##render scale", &scale, 0.25, 2)) draft.render_scale = @round(scale / render_scale_step) * render_scale_step;
        context.muted(std.fmt.allocPrint(arena, "{d:.2}×", .{draft.render_scale}) catch "");
        endCard(context);

        beginCard(context, "Antialiasing", "Smooths jagged edges. MSAA is sharper; FXAA is cheaper and softens textures a little.");
        _ = pick(context, "##anti aliasing", render_settings.AntiAliasing, &draft.anti_aliasing, &anti_aliasing_labels, caps.anti_aliasing);
        endCard(context);

        beginCard(context, "Mipmapping", "Smaller copies of each texture for distant surfaces: less shimmer, a little more memory.");
        _ = context.checkbox("Enabled##mipmaps", &draft.mipmaps);
        endCard(context);

        beginCard(context, "Texture filtering", "How textures are smoothed up close. Linear with mipmapping is trilinear.");
        if (pick(context, "##texture filter", render_settings.TextureFilter, &draft.texture_filter, &texture_filter_labels, .initFull())) {
            // Anisotropic filtering works only on smoothed textures.
            if (draft.texture_filter == .nearest) draft.anisotropy = 1;
        }
        endCard(context);

        if (caps.max_anisotropy > 1 and draft.texture_filter == .linear) {
            beginCard(context, "Anisotropic filtering", "Keeps textures sharp at a slant, such as a road stretching away.");
            pickAnisotropy(context, &draft.anisotropy, caps.max_anisotropy);
            endCard(context);
        }

        // The number fields count only while they are whole numbers; `settings` says otherwise.
        if (parseNumber(u32, &self.width)) |value| draft.width = value;
        if (parseNumber(u32, &self.height)) |value| draft.height = value;
        if (parseNumber(u16, &self.frame_limit)) |value| draft.frame_limit = value;

        const changed = !std.meta.eql(before, self.draft);
        if (changed) self.message_kind = .none;
        return changed;
    }

    /// Declare the message the last Apply left, if any.
    pub fn notice(self: *const Form, context: *ui.Context) void {
        const text = self.message[0..self.message_len];
        switch (self.message_kind) {
            .none => {},
            .saved => context.alert("Graphics", text, false),
            .restart => context.alert("Restart needed", text, false),
            .failed => context.alert("Graphics", text, true),
        }
    }

    /// Declare the message the last Apply left (if any) and the Apply, Restore defaults and
    /// `cancel_label` buttons; returns the one pressed. The caller acts on it.
    /// Call in a frame with an active `context`.
    ///
    /// ```zig
    /// if (form.buttons(context, "Cancel")) |action| switch (action) { ... }
    /// ```
    pub fn buttons(self: *Form, context: *ui.Context, cancel_label: []const u8) ?Action {
        self.notice(context);
        var action: ?Action = null;
        context.begin(.row);
        if (context.buttonVariant("Apply", .default)) action = .apply;
        if (context.buttonVariant("Restore defaults", .outline)) action = .restore_defaults;
        if (context.buttonVariant(cancel_label, .ghost)) action = .cancel;
        context.end();
        return action;
    }
};

/// A message for an apply failure that a player or developer can act on.
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedBackend => "this graphics API isn't available here.",
        error.InvalidGraphicsAdapter => "that graphics card isn't available.",
        error.UnsupportedPresentMode => "this vertical sync mode isn't available.",
        error.UnsupportedAntialiasing => "this antialiasing isn't available on this GPU.",
        error.UnsupportedAnisotropy => "this anisotropic filtering level isn't available.",
        error.AnisotropyRequiresLinearFiltering => "anisotropic filtering needs linear texture filtering.",
        error.UnsupportedFrameLimit => "a frame rate limit isn't available here.",
        error.UnsupportedWindowSettings => "the window can't be changed here.",
        error.InvalidWindowSize => "the window size must be whole numbers, at least 320 by 240.",
        error.InvalidFrameLimit => "the frame rate limit must be a whole number from 0 to 1000.",
        error.InvalidRenderScale => "the render scale must be from 0.25 to 2.",
        error.InvalidAnisotropy => "the anisotropic filtering level must be 1, 2, 4, 8 or 16.",
        else => @errorName(err),
    };
}

fn setNumber(edit: *NumberEdit, value: anytype) void {
    var buffer: [12]u8 = undefined;
    // Twelve characters hold any 32-bit number.
    edit.set(std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable) catch unreachable;
}

fn parseNumber(comptime T: type, edit: *const NumberEdit) ?T {
    return std.fmt.parseInt(T, std.mem.trim(u8, edit.text(), " "), 10) catch null;
}

/// Whether the adapter list in `options` is for `backend`, so one of its indices may be picked.
fn adaptersFit(options: Options, backend: render_settings.Backend) bool {
    return if (options.adapters_backend) |listed| listed == backend else true;
}

/// A dropdown of `E`'s choices that `allowed` has, with `value`'s even when it isn't: a project
/// asking for something this machine lacks still shows what it asks for. Returns whether it changed.
fn pick(context: *ui.Context, id: []const u8, comptime E: type, value: *E, labels: []const []const u8, allowed: std.enums.EnumSet(E)) bool {
    const arena = context.builder().allocator;
    var names: std.ArrayList([]const u8) = .empty;
    var choices: std.ArrayList(E) = .empty;
    var selected: usize = 0;
    for (std.enums.values(E)) |choice| {
        const offered = allowed.contains(choice);
        if (!offered and choice != value.*) continue;
        if (choice == value.*) selected = names.items.len;
        const label = labels[@intFromEnum(choice)];
        names.append(arena, if (offered) label else std.fmt.allocPrint(arena, "{s} (unavailable)", .{label}) catch label) catch return false;
        choices.append(arena, choice) catch return false;
    }
    if (!context.select(id, names.items, &selected)) return false;
    value.* = choices.items[selected];
    return true;
}

/// The anisotropic filtering levels up to `max`, with the current one even if it is over.
fn pickAnisotropy(context: *ui.Context, value: *u16, max: u16) void {
    const arena = context.builder().allocator;
    var names: std.ArrayList([]const u8) = .empty;
    var levels: std.ArrayList(u16) = .empty;
    var selected: usize = 0;
    for (anisotropy_levels) |level| {
        if (level > max and level != value.*) continue;
        if (level == value.*) selected = names.items.len;
        const label = if (level == 1) "Off" else std.fmt.allocPrint(arena, "{d}x", .{level}) catch return;
        names.append(arena, label) catch return;
        levels.append(arena, level) catch return;
    }
    if (context.select("##anisotropy", names.items, &selected)) value.* = levels.items[selected];
}

/// Open a card: its `title` and `note` on the left; its control follows, then `endCard`.
fn beginCard(context: *ui.Context, title: []const u8, note: []const u8) void {
    context.begin(.card);
    context.begin(.row);
    context.begin(.column);
    context.text(title);
    context.muted(note);
    context.end();
    if (context.last_added) |element| {
        element.style.grow = 1;
        element.style.gap = 4;
    }
    context.begin(.column);
}

/// Close the card `beginCard` opened, its control right-aligned.
fn endCard(context: *ui.Context) void {
    context.end();
    if (context.last_added) |element| {
        element.style.width = control_width;
        element.style.align_items = .end;
    }
    context.end();
    if (context.last_added) |element| {
        element.style.direction = .row;
        element.style.gap = 20;
        element.style.align_items = .center;
        element.style.wrap = false;
    }
    context.end();
    if (context.last_added) |element| element.style.max_width = null;
}

fn testCapabilities() Capabilities {
    var caps = Capabilities{ .window_settings = true, .frame_limit = true, .max_anisotropy = 8 };
    caps.backends.insert(.vulkan);
    caps.present_modes.insert(.fifo);
    caps.anti_aliasing.insert(.msaa_4x);
    caps.adapter_count = 1;
    const name = "Test GPU";
    @memcpy(caps.adapters[0].name[0..name.len], name);
    caps.adapters[0].name_len = name.len;
    return caps;
}

test "the form lays out every option the machine offers and renders" {
    const gpa = std.testing.allocator;
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var form = Form{};
    form.load(.{ .anti_aliasing = .fxaa, .frame_limit = 60, .width = 1280, .height = 720 });
    const caps = testCapabilities();
    context.newFrame(.{ .x = 0, .y = 0, .w = 720, .h = 2400 });
    try std.testing.expect(!form.build(&context, .{ .caps = &caps }));
    _ = form.buttons(&context, "Cancel");
    try std.testing.expect((try context.render()).len > 0);
}

test "the form reads its number fields back, and refuses text that is not a number" {
    var form = Form{};
    form.load(.{ .width = 1280, .height = 720, .frame_limit = 144 });
    const read = try form.read();
    try std.testing.expectEqual(@as(u32, 1280), read.width);
    try std.testing.expectEqual(@as(u16, 144), read.frame_limit);

    try form.width.set("wide");
    try std.testing.expectError(error.InvalidWindowSize, form.read());
    try form.width.set("1280");
    try form.frame_limit.set("fast");
    try std.testing.expectError(error.InvalidFrameLimit, form.read());
}

test "the form shows why an apply failed, and that a restart is needed" {
    var form = Form{};
    form.report(error.UnsupportedBackend);
    try std.testing.expect(form.message_kind == .failed);
    try std.testing.expect(std.mem.indexOf(u8, form.message[0..form.message_len], "isn't available") != null);
    form.report(.restart_required);
    try std.testing.expect(form.message_kind == .restart);
    form.report(.queued);
    try std.testing.expect(form.message_kind == .saved);
}

test "every settings error has a message of its own" {
    const bad = [_]render_settings.Settings{
        .{ .width = 10 },
        .{ .frame_limit = 1001 },
        .{ .render_scale = 3 },
        .{ .anisotropy = 3 },
        .{ .anisotropy = 2, .texture_filter = .nearest },
    };
    var form = Form{};
    for (bad) |settings| {
        const err = if (settings.validateValues()) unreachable else |e| e;
        form.report(err);
        try std.testing.expect(form.message_kind == .failed);
        try std.testing.expect(std.mem.indexOf(u8, form.message[0..form.message_len], @errorName(err)) == null);
    }
}

test "loading settings restores the draft and its number fields, and clears the message" {
    var form = Form{};
    form.load(.{ .width = 1280, .height = 720, .frame_limit = 60, .mipmaps = false });
    try form.width.set("5");
    form.report(error.InvalidWindowSize);

    // What Restore defaults and Revert do.
    form.load(.{});
    try std.testing.expect(form.message_kind == .none);
    try std.testing.expectEqual(render_settings.Settings{}, try form.read());
    try std.testing.expectEqualStrings("900", form.width.text());
}

test "restart notices appear only for the settings that need one" {
    const live = render_settings.Settings{ .mipmaps = false, .render_scale = 0.5 };
    try std.testing.expect(!live.requiresRestart(.{}));
    try std.testing.expect((render_settings.Settings{ .backend = .vulkan }).requiresRestart(.{}));
    try std.testing.expect((render_settings.Settings{ .present_mode = .mailbox }).requiresRestart(.{}));
    try std.testing.expect((render_settings.Settings{ .adapter_index = 1 }).requiresRestart(.{}));
}

test "a GPU is offered only for the backend its list belongs to" {
    const caps = testCapabilities();
    const vulkan_list = Options{ .caps = &caps, .adapters_backend = .vulkan };
    try std.testing.expect(adaptersFit(vulkan_list, .vulkan));
    try std.testing.expect(!adaptersFit(vulkan_list, .dx12));
    try std.testing.expect(adaptersFit(.{ .caps = &caps }, .dx12));

    // A draft on another backend still renders, and building it leaves its settings alone.
    const gpa = std.testing.allocator;
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var form = Form{};
    form.load(.{ .backend = .dx12, .adapter_index = null });
    context.newFrame(.{ .x = 0, .y = 0, .w = 720, .h = 2400 });
    try std.testing.expect(!form.build(&context, vulkan_list));
    try std.testing.expectEqual(@as(?u16, null), form.draft.adapter_index);
    try std.testing.expect((try context.render()).len > 0);
}

fn testFrame(context: *ui.Context, form: *Form, caps: *const Capabilities) !void {
    context.newFrame(.{ .x = 0, .y = 0, .w = 720, .h = 2400 });
    _ = form.build(context, .{ .caps = caps });
    _ = try context.render();
}

fn testTap(context: *ui.Context, widget: u32) !void {
    const at = context.last_bounds.get(widget).?.rect.center();
    context.handle(.{ .pointer_move = at });
    context.handle(.{ .pointer_down = .{ .position = at, .button = .left, .clicks = 1 } });
    context.handle(.{ .pointer_up = .{ .position = at, .button = .left } });
}

test "opening one dropdown does not stop another from opening" {
    const gpa = std.testing.allocator;
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var form = Form{};
    var caps = testCapabilities();
    caps.present_modes.insert(.mailbox);
    try testFrame(&context, &form, &caps);
    // The API dropdown, and the vertical sync one after the card, window mode and size fields.
    const backend = context.last_focusables.items[0];
    const sync = context.last_focusables.items[5];

    // Open the first dropdown.
    try testTap(&context, backend);
    try testFrame(&context, &form, &caps);
    try std.testing.expectEqual(backend, context.open_popup);

    // One click on another dropdown switches to it.
    try testTap(&context, sync);
    try testFrame(&context, &form, &caps);
    try std.testing.expectEqual(sync, context.open_popup);

    // Escape closes it.
    context.handle(.{ .key_down = .{ .key = .escape, .modifiers = .{}, .repeat = false } });
    try testFrame(&context, &form, &caps);
    try std.testing.expectEqual(@as(u32, 0), context.open_popup);
}

test "the choice labels cover every enum value in order" {
    try std.testing.expectEqual(@typeInfo(render_settings.Backend).@"enum".fields.len, backend_labels.len);
    try std.testing.expectEqual(@typeInfo(render_settings.PresentMode).@"enum".fields.len, present_mode_labels.len);
    try std.testing.expectEqual(@typeInfo(render_settings.AntiAliasing).@"enum".fields.len, anti_aliasing_labels.len);
    try std.testing.expectEqual(@typeInfo(render_settings.TextureFilter).@"enum".fields.len, texture_filter_labels.len);
    try std.testing.expectEqual(@typeInfo(render_settings.WindowMode).@"enum".fields.len, window_mode_labels.len);
}
