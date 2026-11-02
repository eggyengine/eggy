//! The graphics options as a list of setting rows (`setting_rows.zig`), shared by the player's
//! graphics menu, the editor's Graphics preferences and the Project section's defaults. It edits
//! a draft `Settings`; whoever shows it decides when the draft is applied.
const std = @import("std");
const ui = @import("weeoui");
const render_settings = @import("../render_settings.zig");
const setting_rows = @import("setting_rows.zig");
const SettingRows = setting_rows.SettingRows;

const Settings = render_settings.Settings;
const Capabilities = render_settings.Capabilities;
const NumberEdit = ui.TextEdit(12);
const render_scale_step: f32 = 0.05;
// ponytail: the slider stops at 1000 m though settings accept 10000, raise it if games need farther shadows.
const shadow_distance_slider_max: f32 = 1000;
const shadow_bias_step: f32 = 0.0005;

const backend_labels = [_][]const u8{ "Automatic", "Vulkan", "Direct3D 12", "WebGPU" };
const present_mode_labels = [_][]const u8{ "Automatic", "On (VSync)", "Adaptive VSync", "Low latency (triple buffered)", "Off (may tear)" };
const anti_aliasing_labels = [_][]const u8{ "Off", "2x MSAA", "4x MSAA", "8x MSAA", "FXAA" };
const texture_filter_labels = [_][]const u8{ "Nearest (pixelated)", "Linear (smooth)" };
const shadow_quality_labels = [_][]const u8{ "Off", "Low (1024)", "Medium (2048)", "High (4096)" };
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
    /// What each row is compared with. A row that differs gets a dot, `baseline_label` and the
    /// baseline's value under its control, and a button setting it back. Null leaves rows
    /// unmarked, as the player's menu has them.
    baseline: ?Settings = null,
    /// The words before the baseline's value: "Game ships", "Default is".
    baseline_label: []const u8 = "Default is",
    /// Only rows whose title or note has this in them are shown; empty shows all.
    query: []const u8 = "",
    /// Put the rows in cards of their own (display, detail, shadows) rather than leaving the
    /// caller to put them in one.
    cards: bool = false,
};

/// Each row's title and note, which a search looks through.
const row_texts = struct {
    const backend = RowText{ .title = "Graphics API", .note = "" };
    const adapter_elsewhere = RowText{ .title = "Graphics card", .note = "Restart with this graphics API to choose one." };
    const adapter = RowText{ .title = "Graphics card", .note = "" };
    const window_mode = RowText{ .title = "Window mode", .note = "Borderless fills the screen at its own resolution." };
    const width = RowText{ .title = "Window size", .note = "" };
    const present_mode = RowText{ .title = "Vertical sync", .note = "No tearing, but a little more delay." };
    const frame_limit = RowText{ .title = "Frame rate limit", .note = "0 is unlimited." };
    const render_scale = RowText{ .title = "Render scale", .note = "Below 1 is faster, above 1 sharper. The interface stays sharp." };
    const anti_aliasing = RowText{ .title = "Antialiasing", .note = "MSAA is sharper; FXAA is cheaper." };
    const mipmaps = RowText{ .title = "Mipmapping", .note = "Less shimmer on distant surfaces." };
    const texture_filter = RowText{ .title = "Texture filtering", .note = "Nearest keeps pixel art crisp." };
    const anisotropy = RowText{ .title = "Anisotropic filtering", .note = "Keeps textures sharp at a slant." };
    const shadow_quality = RowText{ .title = "Shadow quality", .note = "" };
    const shadow_distance_m = RowText{ .title = "Shadow distance", .note = "Shorter looks sharper." };
    const shadow_bias = RowText{ .title = "Shadow bias", .note = "Raise it if surfaces speckle, lower it if shadows float." };
};
const RowText = struct { title: []const u8, note: []const u8 };
const all_row_texts = [_]RowText{ row_texts.backend, row_texts.adapter_elsewhere, row_texts.adapter, row_texts.window_mode, row_texts.width, row_texts.present_mode, row_texts.frame_limit, row_texts.render_scale, row_texts.anti_aliasing, row_texts.mipmaps, row_texts.texture_filter, row_texts.anisotropy, row_texts.shadow_quality, row_texts.shadow_distance_m, row_texts.shadow_bias };

/// Whether any graphics row's title or note has `query` in it, as `Options.query` filters them.
///
/// ```zig
/// const listed = graphics_form.anyRowMatches("shadow"); // true
/// ```
pub fn anyRowMatches(query: []const u8) bool {
    for (all_row_texts) |text| {
        if (setting_rows.matches(query, text.title, text.note)) return true;
    }
    return false;
}

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

    /// Set the settings named in `fields` back to `baseline`'s, with their number fields.
    fn reset(self: *Form, comptime fields: anytype, baseline: Settings) void {
        inline for (fields) |field| @field(self.draft, field) = @field(baseline, field);
        setNumber(&self.width, self.draft.width);
        setNumber(&self.height, self.draft.height);
        setNumber(&self.frame_limit, self.draft.frame_limit);
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

    /// Declare a row per option the machine offers, editing the draft. Returns whether the
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
        var row = RowBuilder{ .form = self, .rows = .{ .query = options.query }, .context = context, .options = options };
        defer row.finish();

        if (row.open(.{"backend"}, row_texts.backend, true)) {
            // A GPU chosen for the old backend means nothing on the new one.
            if (pick(context, "##graphics api", render_settings.Backend, &draft.backend, &backend_labels, caps.backends)) draft.adapter_index = null;
            row.close(.{"backend"}, "graphics api");
        }

        const adapters_listed = adaptersFit(options, draft.backend);
        if (options.adapter and caps.adapter_count > 0 and !adapters_listed) {
            if (row.open(.{"adapter_index"}, row_texts.adapter_elsewhere, true)) {
                context.muted(if (draft.adapter_index == null) "Automatic" else "Chosen earlier, for the next start");
                row.close(.{"adapter_index"}, "graphics card");
            }
        } else if (options.adapter and caps.adapter_count > 0) {
            if (row.open(.{"adapter_index"}, row_texts.adapter, true)) {
                // Names live in the frame's arena: the caller's capabilities may not outlive it.
                const names = arena.alloc([]const u8, caps.adapter_count + 1) catch return false;
                names[0] = "Automatic";
                for (caps.adapters[0..caps.adapter_count], names[1..]) |*adapter, *name| name.* = arena.dupe(u8, adapter.nameSlice()) catch return false;
                var selected: usize = if (draft.adapter_index) |index| @min(@as(usize, index) + 1, caps.adapter_count) else 0;
                if (context.select("##graphics card", names, &selected)) draft.adapter_index = if (selected == 0) null else @intCast(selected - 1);
                row.close(.{"adapter_index"}, "graphics card");
            }
        }

        if (caps.window_settings) {
            if (row.open(.{"window_mode"}, row_texts.window_mode, false)) {
                _ = pick(context, "##window mode", render_settings.WindowMode, &draft.window_mode, &window_mode_labels, .full);
                row.close(.{"window_mode"}, "window mode");
            }
            if (draft.window_mode == .windowed) if (row.open(.{ "width", "height" }, row_texts.width, false)) {
                // Both numbers on one line, each just wide enough for a resolution.
                context.begin(.row);
                _ = context.textInput("##window width", &self.width, "900");
                if (context.last_added) |element| element.style.width = 96;
                context.text("×");
                _ = context.textInput("##window height", &self.height, "675");
                if (context.last_added) |element| element.style.width = 96;
                context.end();
                if (context.last_added) |element| {
                    element.style.wrap = false;
                    element.style.align_items = .center;
                    element.style.gap = 6;
                }
                row.close(.{ "width", "height" }, "window size");
            };
        }

        if (row.open(.{"present_mode"}, row_texts.present_mode, true)) {
            _ = pick(context, "##present mode", render_settings.PresentMode, &draft.present_mode, &present_mode_labels, caps.present_modes);
            row.close(.{"present_mode"}, "present mode");
        }

        if (caps.frame_limit) if (row.open(.{"frame_limit"}, row_texts.frame_limit, false)) {
            _ = context.textInput("##frame limit", &self.frame_limit, "0");
            row.close(.{"frame_limit"}, "frame limit");
        };

        if (row.open(.{"render_scale"}, row_texts.render_scale, false)) {
            var scale = draft.render_scale;
            if (context.slider("##render scale", &scale, 0.25, 2)) draft.render_scale = @round(scale / render_scale_step) * render_scale_step;
            context.muted(std.fmt.allocPrint(arena, "{d:.2}×", .{draft.render_scale}) catch "");
            row.close(.{"render_scale"}, "render scale");
        }

        if (row.open(.{"anti_aliasing"}, row_texts.anti_aliasing, false)) {
            _ = pick(context, "##anti aliasing", render_settings.AntiAliasing, &draft.anti_aliasing, &anti_aliasing_labels, caps.anti_aliasing);
            row.close(.{"anti_aliasing"}, "anti aliasing");
        }

        if (row.open(.{"mipmaps"}, row_texts.mipmaps, false)) {
            _ = context.toggle("##mipmaps", &draft.mipmaps);
            row.close(.{"mipmaps"}, "mipmaps");
        }

        if (row.open(.{"texture_filter"}, row_texts.texture_filter, false)) {
            if (pick(context, "##texture filter", render_settings.TextureFilter, &draft.texture_filter, &texture_filter_labels, .full)) {
                // Anisotropic filtering works only on smoothed textures.
                if (draft.texture_filter == .nearest) draft.anisotropy = 1;
            }
            row.close(.{"texture_filter"}, "texture filter");
        }

        if (caps.max_anisotropy > 1 and draft.texture_filter == .linear) if (row.open(.{"anisotropy"}, row_texts.anisotropy, false)) {
            pickAnisotropy(context, &draft.anisotropy, caps.max_anisotropy);
            row.close(.{"anisotropy"}, "anisotropy");
        };

        if (row.open(.{"shadow_quality"}, row_texts.shadow_quality, false)) {
            _ = pick(context, "##shadow quality", render_settings.ShadowQuality, &draft.shadow_quality, &shadow_quality_labels, shadowQualities(caps));
            row.close(.{"shadow_quality"}, "shadow quality");
        }

        if (draft.shadow_quality != .off) {
            if (row.open(.{"shadow_distance_m"}, row_texts.shadow_distance_m, false)) {
                var distance = draft.shadow_distance_m;
                if (context.slider("##shadow distance", &distance, 1, shadow_distance_slider_max)) draft.shadow_distance_m = @round(distance);
                context.muted(std.fmt.allocPrint(arena, "{d:.0} m", .{draft.shadow_distance_m}) catch "");
                row.close(.{"shadow_distance_m"}, "shadow distance");
            }

            if (row.open(.{"shadow_bias"}, row_texts.shadow_bias, false)) {
                var bias = draft.shadow_bias;
                if (context.slider("##shadow bias", &bias, 0, 0.1)) draft.shadow_bias = @round(bias / shadow_bias_step) * shadow_bias_step;
                context.muted(std.fmt.allocPrint(arena, "{d:.4}", .{draft.shadow_bias}) catch "");
                row.close(.{"shadow_bias"}, "shadow bias");
            }
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

/// How many of the rows showing `settings` differ from `baseline` (the window's size is one).
///
/// ```zig
/// const changed = graphics_form.changedRows(app.graphics_options.requested, app.graphics_options.defaults);
/// ```
pub fn changedRows(settings: Settings, baseline: Settings) usize {
    var count: usize = 0;
    inline for (row_fields) |fields| {
        if (differs(fields, settings, baseline)) count += 1;
    }
    return count;
}

/// The settings each row shows, for counting the rows that changed.
const row_fields = .{ .{"backend"}, .{"adapter_index"}, .{"present_mode"}, .{"frame_limit"}, .{"window_mode"}, .{ "width", "height" }, .{"render_scale"}, .{"anti_aliasing"}, .{"mipmaps"}, .{"texture_filter"}, .{"anisotropy"}, .{"shadow_quality"}, .{"shadow_distance_m"}, .{"shadow_bias"} };

/// Builds one form's rows: plain, or marked against `Options.baseline`, and with
/// `Options.cards` in cards of their own.
const RowBuilder = struct {
    form: *Form,
    rows: SettingRows,
    context: *ui.Context,
    options: Options,
    /// The card open, with `Options.cards`.
    card: ?Card = null,

    /// Open the row for the settings named in `fields`, unless the search leaves it out.
    fn open(self: *RowBuilder, comptime fields: anytype, text: RowText, restart: bool) bool {
        if (!self.rows.shows(text.title, text.note)) return false;
        // A card opens with its first row shown, so a search leaves no empty ones.
        if (self.options.cards and self.card != comptime cardOf(fields[0])) {
            if (self.card != null) setting_rows.endGroup(self.context);
            setting_rows.beginGroup(self.context);
            self.card = comptime cardOf(fields[0]);
            self.rows.count = 0;
        }
        const changed = if (self.options.baseline) |baseline| differs(fields, self.form.draft, baseline) else false;
        self.rows.beginMarked(self.context, text.title, text.note, .{ .changed = changed, .restart = restart });
        return true;
    }

    /// Close the row `open` opened: with the baseline's value and a reset when it differs.
    fn close(self: *RowBuilder, comptime fields: anytype, id: []const u8) void {
        const baseline = self.options.baseline orelse return self.rows.end(self.context);
        const changed = differs(fields, self.form.draft, baseline);
        const arena = self.context.builder().allocator;
        const note = if (changed) std.fmt.allocPrint(arena, "{s} {s}", .{ self.options.baseline_label, valueText(arena, fields[0], baseline, self.options.caps) }) catch "" else "";
        if (self.rows.endResettable(self.context, note, changed, id)) self.form.reset(fields, baseline);
    }

    /// Close the last card, if one is open.
    fn finish(self: *RowBuilder) void {
        if (self.card != null) setting_rows.endGroup(self.context);
        self.card = null;
    }
};

/// The cards `Options.cards` puts rows in.
const Card = enum { display, detail, shadows };

/// The card the row for `field` goes in.
fn cardOf(comptime field: []const u8) Card {
    const detail = [_][]const u8{ "render_scale", "anti_aliasing", "mipmaps", "texture_filter", "anisotropy" };
    inline for (detail) |name| if (comptime std.mem.eql(u8, name, field)) return .detail;
    return if (comptime std.mem.startsWith(u8, field, "shadow_")) .shadows else .display;
}

/// Whether any of the settings named in `fields` differ between `a` and `b`.
fn differs(comptime fields: anytype, a: Settings, b: Settings) bool {
    inline for (fields) |field| {
        if (!std.meta.eql(@field(a, field), @field(b, field))) return true;
    }
    return false;
}

/// `field` of `settings` as its row shows it, in `arena`.
fn valueText(arena: std.mem.Allocator, comptime field: []const u8, settings: Settings, caps: *const Capabilities) []const u8 {
    const value = @field(settings, field);
    if (comptime std.mem.eql(u8, field, "backend")) return backend_labels[@backingInt(value)];
    if (comptime std.mem.eql(u8, field, "present_mode")) return present_mode_labels[@backingInt(value)];
    if (comptime std.mem.eql(u8, field, "anti_aliasing")) return anti_aliasing_labels[@backingInt(value)];
    if (comptime std.mem.eql(u8, field, "texture_filter")) return texture_filter_labels[@backingInt(value)];
    if (comptime std.mem.eql(u8, field, "shadow_quality")) return shadow_quality_labels[@backingInt(value)];
    if (comptime std.mem.eql(u8, field, "window_mode")) return window_mode_labels[@backingInt(value)];
    if (comptime std.mem.eql(u8, field, "adapter_index")) {
        const index = value orelse return "Automatic";
        return if (index < caps.adapter_count) arena.dupe(u8, caps.adapters[index].nameSlice()) catch "" else "another card";
    }
    if (comptime std.mem.eql(u8, field, "width")) return std.fmt.allocPrint(arena, "{d} × {d}", .{ settings.width, settings.height }) catch "";
    if (comptime std.mem.eql(u8, field, "frame_limit")) return if (value == 0) "no limit" else std.fmt.allocPrint(arena, "{d} fps", .{value}) catch "";
    if (comptime std.mem.eql(u8, field, "render_scale")) return std.fmt.allocPrint(arena, "{d:.2}×", .{value}) catch "";
    if (comptime std.mem.eql(u8, field, "mipmaps")) return if (value) "On" else "Off";
    if (comptime std.mem.eql(u8, field, "anisotropy")) return if (value <= 1) "Off" else std.fmt.allocPrint(arena, "{d}x", .{value}) catch "";
    if (comptime std.mem.eql(u8, field, "shadow_distance_m")) return std.fmt.allocPrint(arena, "{d:.0} m", .{value}) catch "";
    if (comptime std.mem.eql(u8, field, "shadow_bias")) return std.fmt.allocPrint(arena, "{d:.4}", .{value}) catch "";
    @compileError("no text for graphics setting " ++ field);
}

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
        error.UnsupportedShadowQuality => "this shadow quality is too large for this GPU.",
        error.InvalidShadowDistance => "the shadow distance must be from 1 to 10000 metres.",
        error.InvalidShadowBias => "the shadow bias must be from 0 to 0.1.",
        else => @errorName(err),
    };
}

/// The shadow qualities whose map fits this GPU; Off always does.
fn shadowQualities(caps: *const Capabilities) std.enums.EnumSet(render_settings.ShadowQuality) {
    var allowed: std.enums.EnumSet(render_settings.ShadowQuality) = .initOne(.off);
    for (std.enums.values(render_settings.ShadowQuality)) |quality| {
        if (quality.resolution() <= caps.max_shadow_resolution) allowed.insert(quality);
    }
    return allowed;
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
        const label = labels[@backingInt(choice)];
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

test "rows that differ from the baseline are counted, and reset sets them back" {
    var form = Form{};
    form.load(.{ .anti_aliasing = .msaa_4x, .width = 1280, .height = 720 });
    const baseline = Settings{ .anti_aliasing = .fxaa };
    try std.testing.expectEqual(@as(usize, 2), changedRows(form.draft, baseline));
    form.reset(.{ "width", "height" }, baseline);
    try std.testing.expectEqual(@as(usize, 1), changedRows(form.draft, baseline));
    try std.testing.expectEqual(baseline.width, (try form.read()).width);
}

test "a marked form renders, and a search leaves out the rows it doesn't match" {
    const gpa = std.testing.allocator;
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var form = Form{};
    form.load(.{ .anti_aliasing = .msaa_4x });
    const caps = testCapabilities();
    context.newFrame(.{ .x = 0, .y = 0, .w = 720, .h = 2400 });
    setting_rows.beginGroup(&context);
    _ = form.build(&context, .{ .caps = &caps, .baseline = .{}, .query = "shadow" });
    setting_rows.endGroup(&context);
    // Shadow quality, distance and bias, with hairlines between.
    try std.testing.expectEqual(@as(usize, 5), context.last_added.?.children.len);
    try std.testing.expect((try context.render()).len > 0);
}

test "rows go in cards by kind, and a search finds rows by their words" {
    try std.testing.expectEqual(Card.detail, cardOf("mipmaps"));
    try std.testing.expectEqual(Card.shadows, cardOf("shadow_bias"));
    try std.testing.expectEqual(Card.display, cardOf("backend"));
    try std.testing.expect(anyRowMatches("SHIMMER"));
    try std.testing.expect(!anyRowMatches("autosave"));
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
        .{ .shadow_distance_m = 0 },
        .{ .shadow_bias = 0.5 },
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
    try std.testing.expectEqual(@typeInfo(render_settings.Backend).@"enum".field_names.len, backend_labels.len);
    try std.testing.expectEqual(@typeInfo(render_settings.PresentMode).@"enum".field_names.len, present_mode_labels.len);
    try std.testing.expectEqual(@typeInfo(render_settings.AntiAliasing).@"enum".field_names.len, anti_aliasing_labels.len);
    try std.testing.expectEqual(@typeInfo(render_settings.TextureFilter).@"enum".field_names.len, texture_filter_labels.len);
    try std.testing.expectEqual(@typeInfo(render_settings.ShadowQuality).@"enum".field_names.len, shadow_quality_labels.len);
    try std.testing.expectEqual(@typeInfo(render_settings.WindowMode).@"enum".field_names.len, window_mode_labels.len);
}

test "shadow quality offers only the maps the GPU can hold" {
    var caps = Capabilities{ .max_shadow_resolution = 2048 };
    const allowed = shadowQualities(&caps);
    try std.testing.expect(allowed.contains(.off) and allowed.contains(.medium));
    try std.testing.expect(!allowed.contains(.high));
}
