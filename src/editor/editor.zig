//! The `eggy_editor` module: a game's scene with Weeoui tooling drawn over it. Desktop only.
const builtin = @import("builtin");
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const weeoui_vitellus = @import("weeoui_vitellus");
const workspace_zig = @import("workspace.zig");
const Workspace = workspace_zig.Workspace;
const Slot = workspace_zig.Slot;
const main_slot = workspace_zig.main_slot;
const PopOut = @import("popout.zig").PopOut;
const icon = @import("icon.zig");

/// The editor for `project` (see `eggy_runtime.Runtime`). The game and its plugins run as they
/// do in the runtime, inside a window of dockable panels; each can add to the Inspector through
/// `editorUi`.
pub fn Editor(comptime project: type) type {
    const Plugins = eggy.plugins.Set(project.plugins);
    return struct {
        gpa: std.mem.Allocator,
        app: eggy.App,
        plugins: Plugins,
        /// The Inspector's UI (the game's and plugins' `editorUi`), and the font every page shares.
        ui: ui.Context,
        /// A UI of its own for each plugin panel (`Plugins.editor_panels`), drawing with `ui`'s font.
        plugin_pages: [Plugins.editor_panels.len]ui.Context,
        /// The page (see `page`) that last took a press, which gets keyboard input.
        focused_page: usize = 0,
        /// The title bar, menus and dockable panels of every window.
        workspace: Workspace,
        /// Where the main window's drawn title bar is; SDL's hit test keeps a pointer to it.
        frame: *weeoui_sdl3.Frame,
        /// The game's scene, rendered offscreen and drawn into the Scene panel.
        scene: eggy.SceneTexture,
        /// Draws the main window's UI into the frame `Graphics` already started.
        overlay: weeoui_vitellus.Renderer,
        /// The OS window for each of the dock's pop-out windows that is open.
        popouts: [ui.dock.max_windows]?PopOut = @splat(null),
        /// When the main title bar was last pressed, to spot a double-click; see `titlebarPressed`.
        titlebar_press_ns: u64 = 0,

        const Self = @This();
        /// SDL's default double-click time.
        const double_click_ns = 500 * std.time.ns_per_ms;
        const title = project.name ++ " - eggy editor";
        /// Pages: the Inspector, then each plugin panel.
        const page_count = 1 + Plugins.editor_panels.len;

        pub fn init(gpa: std.mem.Allocator) !Self {
            var app = try eggy.App.init(gpa, title);
            errdefer app.deinit();
            app.window.window.maximize() catch |err| std.log.warn("cannot maximize the editor: {t}", .{err});
            icon.apply(app.window.window);
            var context = try ui.Context.init(gpa);
            errdefer context.deinit();
            context.srgb_target = weeoui_vitellus.isSrgb(app.graphics.color_format);
            context.theme = weeoui_sdl3.systemTheme();
            var plugin_pages: [Plugins.editor_panels.len]ui.Context = undefined;
            for (&plugin_pages) |*page_ui| page_ui.* = ui.Context.initWithFont(gpa, context.font);
            errdefer for (&plugin_pages) |*page_ui| page_ui.deinit();
            var overlay = try weeoui_vitellus.Renderer.init(app.graphics.device, app.graphics.color_format, context.font);
            errdefer overlay.deinit();
            var scene = try eggy.SceneTexture.init(&app.graphics);
            errdefer scene.deinit();

            // Draw the title bar ourselves, with the menus on it, laid out like the desktop's.
            var threaded: std.Io.Threaded = .init_single_threaded;
            var workspace = try Workspace.init(gpa, weeoui_sdl3.buttonLayout(gpa, threaded.io()), Plugins.editor_panels);
            errdefer workspace.deinit();
            const frame = try gpa.create(weeoui_sdl3.Frame);
            errdefer gpa.destroy(frame);
            frame.* = .{};
            weeoui_sdl3.useCustomFrame(app.window.window, frame) catch |err| {
                std.log.warn("custom title bar unavailable: {t}", .{err});
                workspace.custom_frame = false;
            };

            var plugins = try Plugins.init(gpa, &app);
            errdefer plugins.deinit();
            try app.startWorld();
            return .{ .gpa = gpa, .plugins = plugins, .app = app, .ui = context, .plugin_pages = plugin_pages, .workspace = workspace, .frame = frame, .scene = scene, .overlay = overlay };
        }

        pub fn deinit(self: *Self) void {
            self.plugins.deinit();
            for (&self.popouts) |*popout| if (popout.*) |*open| {
                open.close(&self.app.graphics);
                popout.* = null;
            };
            // The overlay's and scene's GPU resources must outlive any frame still in flight.
            self.app.graphics.queue.waitIdle() catch {};
            self.scene.deinit();
            self.overlay.deinit();
            self.workspace.deinit();
            for (&self.plugin_pages) |*page_ui| page_ui.deinit();
            self.ui.deinit();
            self.app.deinit();
            self.gpa.destroy(self.frame);
        }

        pub fn iterate(self: *Self) !sdl3.AppResult {
            try self.app.graphics.syncSize(self.app.window);
            const viewport = try self.uiViewport() orelse return .run; // minimized
            try self.plugins.update(&self.app);
            try self.app.updateWorld();
            try self.syncPopOuts();

            // Lay out every window, then tell the OS where the main title bar is.
            const flags = self.app.window.window.getFlags();
            self.workspace.window_state = .{ .maximized = flags.maximized, .focused = flags.input_focus };
            var window_viewports: [ui.dock.max_windows]?ui.Rect = @splat(null);
            for (self.popouts, &window_viewports) |popout, *area| if (popout) |open| {
                area.* = try open.viewport();
            };
            try self.workspace.build(viewport, window_viewports, self.ui.font);
            self.frame.* = self.workspace.titlebarFrame();

            // Build each page's UI into its panel, wherever that is.
            var pages: [page_count][]const ui.Vertex = @splat(&.{});
            for (&pages, 0..) |*vertices, index| {
                const placed = self.workspace.placed.pages[index] orelse continue;
                const page_ui = self.page(index);
                page_ui.theme = self.ui.theme;
                page_ui.pixel_scale = self.ui.pixel_scale;
                page_ui.srgb_target = self.ui.srgb_target;
                page_ui.newFrame(placed.rect);
                page_ui.time_ms = sdl3.timer.getMillisecondsSinceInit();
                if (index == 0) self.buildInspector() else self.plugins.editorPanelUi(index - 1, page_ui);
                vertices.* = try page_ui.render();
            }

            // Draw each window.
            try self.present(main_slot, &self.app.graphics.surface, &self.overlay, viewport, &pages);
            for (&self.popouts, 0..) |*popout, i| if (popout.*) |*open| {
                const area = window_viewports[i] orelse continue;
                try open.surface.syncSize(self.app.graphics.queue, open.window);
                try self.present(workspace_zig.windowSlot(i), &open.surface, &open.overlay, area, &pages);
            };
            const pointer = self.workspace.pointer;
            const hovered = self.pageAt(self.workspace.pointer_slot, pointer.x, pointer.y);
            weeoui_sdl3.setCursor(self.workspace.dock.cursor() orelse if (hovered) |index| self.page(index).cursor else .default);
            return .run;
        }

        /// Draw window `slot` into `surface`: its UI with the pages' (`pages`) in their panels,
        /// and the scene texture inside the Scene panel if that's in this window.
        fn present(self: *Self, slot: Slot, surface: *eggy.Surface, overlay: *weeoui_vitellus.Renderer, viewport: ui.Rect, pages: []const []const ui.Vertex) !void {
            const drawn = try self.workspace.draw(slot, &self.ui, pages);

            // Render the scene offscreen at the Scene panel's pixel size.
            const frame = try surface.beginFrame();
            const scene_px = if (self.workspace.placed.scene) |placed| if (placed.slot == slot) self.toPixels(placed.rect) else null else null;
            if (scene_px) |rect| try self.scene.render(&self.app.graphics, frame.cmd, .{ .width = @intFromFloat(@round(rect.w)), .height = @intFromFloat(@round(rect.h)) });

            // The UI under the Scene panel, the scene texture, then the UI over it.
            try overlay.upload(frame.cmd, self.ui.font, drawn.vertices, viewport);
            try frame.cmd.beginRenderPass(.{ .label = "editor ui", .color_attachments = &.{.{ .view = frame.target, .load_op = .load, .store_op = .store }} });
            overlay.draw(frame.cmd, frame.extent, 0, drawn.scene_at);
            if (scene_px) |rect| self.scene.draw(frame.cmd, rect, frame.extent);
            overlay.draw(frame.cmd, frame.extent, drawn.scene_at, drawn.vertices.len - drawn.scene_at);
            frame.cmd.endRenderPass();
            try surface.endFrame(self.app.graphics.queue, frame);
        }

        /// Open an OS window for each panel the dock has popped out, and close those it took back.
        fn syncPopOuts(self: *Self) !void {
            for (self.workspace.dock.windows, &self.popouts, 0..) |wanted, *popout, i| {
                if (wanted == null) {
                    if (popout.*) |*open| open.close(&self.app.graphics);
                    popout.* = null;
                } else if (popout.* == null) {
                    popout.* = try PopOut.open(&self.app.graphics, self.ui.font, self.workspace.windowTitle(i), wanted.?.size);
                    icon.apply(popout.*.?.window.window);
                }
            }
        }

        pub fn event(self: *Self, curr_event: sdl3.events.Event) !sdl3.AppResult {
            const slot = self.slotOf(curr_event);

            // A pop-out window's close button docks its panels back into the main window.
            if (slot != main_slot and curr_event == .window_close_requested) {
                self.workspace.dock.redock(.{ .window = @intCast(slot - 1) });
                return .run;
            }

            // The title bar, menus and dock take their own input first.
            // Double-clicking the drawn title bar maximizes or restores, as a system one would.
            if (slot == main_slot and self.titlebarPressed(curr_event)) {
                const now = sdl3.timer.getNanosecondsSinceInit();
                if (now - self.titlebar_press_ns < double_click_ns) {
                    _ = weeoui_sdl3.windowAction(self.app.window.window, .maximize);
                    self.titlebar_press_ns = 0;
                } else self.titlebar_press_ns = now;
            }

            const outcome: workspace_zig.Outcome = if (weeoui_sdl3.translate(curr_event)) |input| self.workspace.handle(slot, input) else .ignored;
            switch (outcome) {
                .quit => return .success,
                .window => |button| if (weeoui_sdl3.windowAction(self.app.window.window, button)) return .success,
                else => {},
            }
            if (curr_event == .system_theme_changed) self.ui.theme = weeoui_sdl3.systemTheme();

            // The pages get the rest, and every pointer move so their hover state stays current.
            if (outcome == .ignored or curr_event == .mouse_motion) self.routeToPages(slot, curr_event);
            try self.plugins.event(&self.app, curr_event);
            return self.app.event(curr_event);
        }

        /// Hand `curr_event` from window `slot` to the pages in that window that want it: pointer
        /// moves and releases to all of them, presses and wheels to the one they land on (a press
        /// also gives it the keyboard), keys and text to the focused one.
        fn routeToPages(self: *Self, slot: Slot, curr_event: sdl3.events.Event) void {
            const input = weeoui_sdl3.translate(curr_event) orelse {
                // Window events: the Inspector's handler attaches screen reader support with them.
                const inspector = self.workspace.placed.pages[0] orelse return;
                if (inspector.slot == slot) weeoui_sdl3.handleEvent(&self.ui, curr_event);
                return;
            };
            if (input == .pointer_down) {
                const at = input.pointer_down.position;
                if (self.pageAt(slot, at.x, at.y)) |index| self.focused_page = index;
            }
            for (0..page_count) |index| {
                const placed = self.workspace.placed.pages[index] orelse continue;
                if (placed.slot != slot) continue;
                const wanted = switch (input) {
                    .pointer_move, .pointer_up => true,
                    .pointer_down => |down| placed.rect.contains(down.position.x, down.position.y),
                    .wheel => |wheel| placed.rect.contains(wheel.position.x, wheel.position.y),
                    .key_down, .text, .composition => index == self.focused_page,
                };
                if (!wanted) continue;
                // ponytail: only the Inspector is exposed to screen readers; give plugin pages AccessKit too once one adapter can serve several contexts.
                if (index == 0) weeoui_sdl3.handleEvent(&self.ui, curr_event) else self.page(index).handle(input);
            }
        }

        /// Page `index`'s UI: the Inspector for 0, else plugin panel `index - 1`.
        fn page(self: *Self, index: usize) *ui.Context {
            if (index == 0 or Plugins.editor_panels.len == 0) return &self.ui;
            return &self.plugin_pages[index - 1];
        }

        /// The page whose panel holds (x, y) in window `slot`.
        fn pageAt(self: *const Self, slot: Slot, x: f32, y: f32) ?usize {
            for (self.workspace.placed.pages[0..page_count], 0..) |placement, index| {
                const placed = placement orelse continue;
                if (placed.slot == slot and placed.rect.contains(x, y)) return index;
            }
            return null;
        }

        /// Whether `curr_event` is a press on the main title bar's draggable part. SDL hands such
        /// presses to the OS to move the window instead of to the app, so they show up only
        /// indirectly: X11 and macOS send `window_hit_test`, and on Wayland the move's pointer
        /// grab sends `window_mouse_leave` while the pointer was last over the bar. Windows
        /// handles caption double-clicks itself.
        // ponytail: the Wayland signal is a heuristic; replace it if SDL starts reporting these presses.
        fn titlebarPressed(self: *const Self, curr_event: sdl3.events.Event) bool {
            if (builtin.os.tag == .windows or !self.workspace.custom_frame) return false;
            const press = switch (curr_event) {
                .window_hit_test => true,
                .window_mouse_leave => std.mem.eql(u8, sdl3.video.getCurrentDriverName() orelse "", "wayland"),
                else => false,
            };
            if (!press) return false;
            const p = self.workspace.pointer;
            if (self.workspace.pointer_slot != main_slot or !self.frame.bar.contains(p.x, p.y)) return false;
            for (self.frame.buttons[0..self.frame.button_count]) |button| if (button.contains(p.x, p.y)) return false;
            return !self.frame.controls.contains(p.x, p.y);
        }

        /// Which of the editor's windows `curr_event` came from; the main window for events
        /// without one.
        fn slotOf(self: *const Self, curr_event: sdl3.events.Event) Slot {
            const id: sdl3.video.WindowId = switch (curr_event) {
                inline else => |payload| blk: {
                    const T = @TypeOf(payload);
                    if (T == sdl3.events.Window) break :blk payload.id;
                    if (@typeInfo(T) == .@"struct" and @hasField(T, "window_id")) {
                        const window_id: ?sdl3.video.WindowId = payload.window_id;
                        break :blk window_id orelse return main_slot;
                    }
                    return main_slot;
                },
            };
            for (self.popouts, 0..) |popout, i| if (popout) |open| if (open.id == id) return workspace_zig.windowSlot(i);
            return main_slot;
        }

        /// The Inspector panel: the project's name, then whatever the game and plugins add.
        fn buildInspector(self: *Self) void {
            self.ui.heading(3, project.name);
            self.plugins.editorUi(&self.ui);
        }

        /// `rect` (in UI points) in window pixels.
        // ponytail: uses the main window's pixel density for pop-outs too; read each window's if they sit on screens with different scales.
        fn toPixels(self: *const Self, rect: ui.Rect) ui.Rect {
            const sx, const sy = self.ui.pixel_scale;
            return .{ .x = rect.x * sx, .y = rect.y * sy, .w = rect.w * sx, .h = rect.h * sy };
        }

        /// The window in points, which is where SDL reports the pointer; null while minimized.
        /// Also points `ui` at the window's pixel density so text stays crisp.
        // ponytail: ignores the display's content scale (Windows 125%+); copy weeoui_sdl3.run's scaling if UI looks small there.
        fn uiViewport(self: *Self) !?ui.Rect {
            const width, const height = try self.app.window.window.getSize();
            if (width == 0 or height == 0) return null;
            const pixel_width, const pixel_height = try self.app.window.window.getSizeInPixels();
            const viewport = ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) };
            self.ui.pixel_scale = .{ @as(f32, @floatFromInt(pixel_width)) / viewport.w, @as(f32, @floatFromInt(pixel_height)) / viewport.h };
            self.ui.font.dpi_scale = self.ui.pixel_scale[0];
            return viewport;
        }
    };
}

test {
    _ = @import("workspace.zig");
    _ = @import("menus.zig");
    _ = @import("panels.zig");
}

test "the editor compiles for a project" {
    const project = struct {
        pub const name = "test";
        pub const plugins = .{struct {}};
    };
    std.testing.refAllDecls(Editor(project));
}

test "the editor compiles for a project whose plugins add panels" {
    const project = struct {
        pub const name = "test";
        pub const plugins = .{ struct {}, struct {
            pub const editor_panels = [_]eggy.plugins.EditorPanel{ .{ .title = "One" }, .{ .title = "Two" } };
            pub fn editorPanelUi(_: *@This(), _: usize, _: *ui.Context) void {}
        } };
    };
    std.testing.refAllDecls(Editor(project));
}
