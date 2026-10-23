//! Edit > Plugins: the project's installed plugins, the plugins that ship inside Eggy, and any
//! other fetched by its `eggy.zon`'s address or path (or dropped on the editor). Opening one shows
//! its read-me, then Install (or Update) adds it to the project's `eggy.zon`, which `addGame`
//! builds the game with. An installed plugin can be turned off and on (its switch, as in
//! Preferences > Plugins), and once off, uninstalled: taken out of `eggy.zon`, with its package
//! out of `build.zig.zon` unless another installed plugin comes from it. Each is a step to undo.
const std = @import("std");
const eggy = @import("eggy");
const sdl3 = eggy.sdl_adapter.sdl;
const ui = eggy.ui;
const weeoui_sdl3 = @import("weeoui_sdl3");
const build_options = @import("build_options");
const ToolWindow = @import("../tool_window.zig").ToolWindow;
const page_style = @import("../page_style.zig");
const restyle = page_style.restyle;
const smallText = page_style.smallText;
const fetch_zig = @import("fetch.zig");
const install_zig = @import("install.zig");
const source = @import("source.zig");
const package_removal = @import("package_removal.zig");
const Fetched = fetch_zig.Fetched;
const Installed = eggy.plugin_manifest.Installed;
const Manifest = eggy.plugin_manifest.Manifest;
const log = std.log.scoped(.plugins);

const sidebar_width: f32 = 170;
const Location = ui.TextEdit(1024);

/// What the sidebar shows.
const Section = enum {
    installed,
    builtin,
    address,

    fn title(section: Section) []const u8 {
        return switch (section) {
            .installed => "Installed",
            .builtin => "Made by Eggy",
            .address => "From an Address",
        };
    }
};

/// A file's text before and after a change.
pub const Texts = eggy.Action([]u8);

/// An install or uninstall, owned by whoever takes it: `eggy.zon`'s texts, and `build.zig.zon`'s
/// when an uninstall took the plugin's package out too. A step to undo.
pub const Change = struct { project: Texts, package: ?Texts = null };

/// What a frame of the window asks of the editor.
pub const Outcome = struct {
    change: ?Change = null,
    /// A plugin to turn on or off (its module, borrowed until the next frame).
    switched: ?struct { module: []const u8, on: bool } = null,
};

pub const PluginsWindow = struct {
    gpa: std.mem.Allocator,
    window: ToolWindow,
    /// The project's folder, owned.
    project_dir: []u8,
    section: Section = .installed,
    /// The plugins inside Eggy, read from what the editor embeds.
    builtins: []*Fetched = &.{},
    /// The project's `eggy.zon` `.plugins`, as last read (see `reloadInstalled`).
    installed_arena: std.heap.ArenaAllocator,
    installed: []const Installed = &.{},
    location: Location = Location.init("") catch unreachable,
    /// The plugin being read, then the one shown (its read-me) once read.
    fetching: ?*fetch_zig.Fetch = null,
    shown: ?*Fetched = null,
    /// Whether `shown` is one of `builtins` (not owned).
    shown_builtin: bool = false,
    /// Why the last fetch or install failed, owned.
    problem: std.ArrayList(u8) = .empty,
    installing: ?*install_zig.Install = null,
    /// What this frame asks of the editor, for `update` to return.
    outcome: Outcome = .{},
    /// The modules of the plugins turned off, borrowed from the editor for a frame.
    off: []const []const u8 = &.{},
    sidebar_scroll: ui.Layout.ScrollState = .{},
    content_scroll: ui.Layout.ScrollState = .{},

    /// Open the window for the project in `project_dir`. On the heap, as its page keeps a pointer
    /// to it. Allocation and window failures propagate.
    ///
    /// ```zig
    /// const window = try PluginsWindow.open(gpa, graphics, font, project_dir);
    /// defer window.close(graphics);
    /// ```
    pub fn open(gpa: std.mem.Allocator, graphics: *const eggy.Graphics, font: *ui.Font, project_dir: []const u8) !*PluginsWindow {
        const self = try gpa.create(PluginsWindow);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .window = undefined, .project_dir = try gpa.dupe(u8, project_dir), .installed_arena = .init(gpa) };
        errdefer gpa.free(self.project_dir);
        errdefer self.installed_arena.deinit();
        try self.readBuiltins();
        errdefer self.freeBuiltins();
        self.reloadInstalled();
        self.window = try ToolWindow.open(gpa, graphics, font, "Plugins", .{ 820, 600 }, .{ .resizable = true });
        return self;
    }

    /// Close the window, stopping any fetch or install under way, and free it.
    pub fn close(self: *PluginsWindow, graphics: *eggy.Graphics) void {
        const gpa = self.gpa;
        self.window.close(graphics);
        if (self.fetching) |fetch| fetch.destroy();
        if (self.installing) |running| running.destroy();
        self.dropShown();
        self.freeBuiltins();
        self.installed_arena.deinit();
        self.problem.deinit(gpa);
        if (self.outcome.change) |change| freeChange(gpa, change);
        gpa.free(self.project_dir);
        gpa.destroy(self);
    }

    /// Whether `curr_event` asks to close the window: its close button, or Escape.
    pub fn closeRequested(self: *const PluginsWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        if (curr_event == .window_close_requested) return true;
        const input = weeoui_sdl3.translate(curr_event) orelse return false;
        return input == .key_down and input.key_down.key == .escape;
    }

    /// Handle `curr_event` if it is for this window; returns whether it was.
    pub fn handle(self: *PluginsWindow, curr_event: sdl3.events.Event) bool {
        if (!self.window.owns(curr_event)) return false;
        self.window.handle(curr_event);
        return true;
    }

    /// Read the plugin whose `eggy.zon` is at `typed` (an address or a path), then show its
    /// read-me. Failures show in the window.
    ///
    /// ```zig
    /// window.fetchFrom("/home/me/plugins/stats/eggy.zon"); // A dropped file.
    /// ```
    pub fn fetchFrom(self: *PluginsWindow, typed: []const u8) void {
        self.section = .address;
        self.location.set(typed[0..@min(typed.len, 1024)]) catch {};
        self.problem.clearRetainingCapacity();
        if (self.fetching) |fetch| fetch.destroy();
        self.fetching = null;
        self.fetching = fetch_zig.Fetch.start(self.gpa, typed, self.project_dir) catch |err| {
            self.setProblem(if (err == error.EmptyLocation) "Type the address of a plugin's eggy.zon, or a path to it." else "Couldn't start reading the plugin.");
            return;
        };
    }

    /// Read the project's installed plugins again, after its `eggy.zon` changed (an undo, say).
    pub fn reloadInstalled(self: *PluginsWindow) void {
        _ = self.installed_arena.reset(.retain_capacity);
        self.installed = &.{};
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, self.project_dir, .{}) catch return;
        defer dir.close(io);
        const config = eggy.project.load(self.installed_arena.allocator(), io, dir) catch |err| return log.warn("cannot read {s}: {t}", .{ eggy.project.file_name, err });
        self.installed = config.plugins;
    }

    /// Draw a frame, showing the plugins keyed in `off` as off; returns what it asks of the
    /// editor: an install or uninstall (the caller owns its texts and rebuilds the project), or a
    /// plugin to switch.
    pub fn update(self: *PluginsWindow, graphics: *eggy.Graphics, style: *const ui.Context, off: []const []const u8) !Outcome {
        self.collect();
        self.off = off;
        const Page = struct {
            window: *PluginsWindow,
            /// ToolWindow callback for one frame of the Plugins window.
            pub fn build(page: *@This(), context: *ui.Context) void {
                page.window.build(context);
            }
        };
        var page = Page{ .window = self };
        try self.window.present(graphics, style, &page);
        defer self.outcome = .{};
        return self.outcome;
    }

    /// Take what a fetch or install finished with.
    fn collect(self: *PluginsWindow) void {
        if (self.fetching) |fetch| if (fetch.take()) |outcome| {
            fetch.destroy();
            self.fetching = null;
            switch (outcome) {
                .fetched => |fetched| self.show(fetched, false),
                .failed => |why| self.setProblem(why),
            }
        };
        if (self.installing) |running| {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const status = running.status(arena.allocator()) catch return;
            const outcome = status.outcome orelse return;
            running.destroy();
            self.installing = null;
            switch (outcome) {
                .saved => if (self.shown) |fetched| self.record(fetched) catch |err| self.failInstall(err),
                .failed => |why| self.setProblem(why),
            }
        }
    }

    // The page.

    fn build(self: *PluginsWindow, context: *ui.Context) void {
        const pane_height = page_style.pageHeight(context);
        context.begin(.row);
        context.beginScroll(&self.sidebar_scroll, pane_height);
        for (std.enums.values(Section)) |section| self.sidebarItem(context, section);
        context.end();
        restyle(context, .{ .width = sidebar_width, .gap = 2 });
        context.beginScroll(&self.content_scroll, pane_height);
        if (self.shown) |fetched| self.buildReadme(context, fetched) else switch (self.section) {
            .installed => self.buildInstalled(context),
            .builtin => self.buildBuiltins(context),
            .address => self.buildAddress(context),
        }
        context.end();
        restyle(context, .{ .grow = 1, .gap = 14 });
        context.end();
        restyle(context, .{ .direction = .row, .gap = 24, .align_items = .start });
    }

    fn sidebarItem(self: *PluginsWindow, context: *ui.Context, section: Section) void {
        const id = context.idFor(section.title());
        if (context.activated(id)) {
            self.section = section;
            self.dropShown();
            self.content_scroll = .{};
        }
        const row = context.builder().node(id, .{ .height = 30 }, .{ .menu_item = .{ .label = section.title(), .hot = self.section == section and self.shown == null } }, &.{}) catch return;
        row.cursor = .pointer;
        row.accessibility = .{ .role = .tab, .label = section.title() };
        context.element(row);
    }

    fn header(context: *ui.Context, title: []const u8, subtitle: []const u8) void {
        context.heading(3, title);
        context.muted(subtitle);
        smallText(context, 12);
    }

    fn buildInstalled(self: *PluginsWindow, context: *ui.Context) void {
        header(context, "Installed", "The plugins this project installed here, which its game is built with. Plugins its build.zig adds aren't listed. Turn one off to uninstall it.");
        if (self.problem.items.len > 0) context.alert("Couldn't uninstall the plugin", self.problem.items, true);
        if (self.installed.len == 0) {
            context.muted("None yet. Find one in Made by Eggy, or fetch one From an Address.");
            return;
        }
        const arena = context.builder().allocator;
        for (self.installed) |installed| {
            const builtin = self.builtinFor(installed.module);
            page_style.beginSection(context, if (builtin) |found| found.manifest.title else installed.module);
            badges(context, .{ .version = installed.version, .dev = installed.dev, .in_eggy = installed.dependency == null, .off = self.isOff(installed.module) });
            context.muted(if (installed.dependency) |dependency| std.fmt.allocPrint(arena, "Module {s}, from {s}", .{ installed.module, dependency }) catch "" else "Ships inside Eggy");
            smallText(context, 12);
            context.begin(.row);
            if (context.buttonVariant(std.fmt.allocPrint(arena, "Read Me##r{s}", .{installed.module}) catch "Read Me", .outline)) {
                if (builtin) |found| self.show(found, true) else if (installed.source.len > 0) self.fetchFrom(installed.source);
            }
            self.switchButtons(context, installed);
            page_style.endRow(context);
            self.uninstallNote(context, installed);
            page_style.endSection(context);
        }
    }

    fn buildBuiltins(self: *PluginsWindow, context: *ui.Context) void {
        header(context, "Made by Eggy", "Plugins that ship inside Eggy. None is on until you install it.");
        const arena = context.builder().allocator;
        for (self.builtins) |fetched| {
            const manifest = fetched.manifest;
            page_style.beginSection(context, manifest.title);
            badges(context, .{ .version = manifest.version, .dev = manifest.dev, .installed = self.installedFor(manifest.module) != null, .off = self.isOff(manifest.module) });
            if (manifest.description.len > 0) context.muted(manifest.description);
            if (context.buttonVariant(std.fmt.allocPrint(arena, "Read Me##b{s}", .{manifest.module}) catch "Read Me", .outline)) self.show(fetched, true);
            page_style.endSection(context);
        }
    }

    fn buildAddress(self: *PluginsWindow, context: *ui.Context) void {
        header(context, "From an Address", "Fetch a plugin by its eggy.zon: an address (a GitHub page of its folder works too) or a path. You can also drop a plugin's eggy.zon on the editor.");
        context.begin(.row);
        _ = context.textInput("##location", &self.location, "https://raw.githubusercontent.com/me/plugins/main/stats/eggy.zon");
        restyle(context, .{ .grow = 1 });
        if (context.button("Fetch") and self.fetching == null) self.fetchFrom(self.location.text());
        page_style.endRow(context);
        if (self.fetching) |fetch| {
            context.muted(std.fmt.allocPrint(context.builder().allocator, "Reading {s}...", .{fetch.location()}) catch "Reading...");
        }
        if (self.problem.items.len > 0) context.alert("Couldn't fetch the plugin", self.problem.items, true);
    }

    /// The plugin's page: what it is, Install or Update, then its read-me.
    fn buildReadme(self: *PluginsWindow, context: *ui.Context, fetched: *Fetched) void {
        const arena = context.builder().allocator;
        const manifest = fetched.manifest;
        if (context.buttonVariant("Back", .link)) {
            self.dropShown();
            return;
        }
        context.heading(2, manifest.title);
        badges(context, .{ .version = manifest.version, .dev = manifest.dev, .in_eggy = fetched.package == .eggy, .off = self.installedFor(manifest.module) != null and self.isOff(manifest.module) });
        if (manifest.description.len > 0) context.text(manifest.description);
        context.muted(std.fmt.allocPrint(arena, "Repository: {s}", .{manifest.repository}) catch "");
        smallText(context, 12);
        if (!self.shown_builtin) {
            context.muted(std.fmt.allocPrint(arena, "Read from {s}", .{fetched.origin.text()}) catch "");
            smallText(context, 12);
        }
        if (fetched.package == .fetch) {
            context.muted(std.fmt.allocPrint(arena, "Package {s}, fingerprint 0x{x}", .{ fetched.package.fetch.url, manifest.fingerprint }) catch "");
            smallText(context, 12);
        }

        // Install, update, or why not.
        self.buildInstallRow(context, fetched);
        if (self.problem.items.len > 0) context.alert("Not installed", self.problem.items, true);
        if (self.installing) |running| {
            const status = running.status(arena) catch null;
            context.muted(if (status) |known| known.log else "Fetching...");
            smallText(context, 12);
        }

        context.separator();
        if (fetched.readme) |readme| {
            const typeset = ui.widgets.typeset(context.builder(), withoutInlineMarks(arena, readme) catch readme, .{}) catch return;
            fitToTheme(typeset, context.theme.text_size);
            context.element(typeset);
        } else context.muted("No README.md was provided.");
    }

    fn buildInstallRow(self: *PluginsWindow, context: *ui.Context, fetched: *Fetched) void {
        const arena = context.builder().allocator;
        const manifest = fetched.manifest;
        if (manifest.minimum_eggy_version) |minimum| if (eggy.plugin_manifest.compareVersions(minimum, build_options.version) == .gt) {
            context.alert("Needs a newer Eggy", std.fmt.allocPrint(arena, "This plugin needs Eggy {s} or newer; the project is on {s}. Use File > Upgrade Editor first.", .{ minimum, build_options.version }) catch "", false);
            return;
        };
        context.begin(.row);
        const installed = self.installedFor(manifest.module) orelse {
            if (self.installButton(context, "Install")) self.install(fetched);
            page_style.endRow(context);
            return;
        };
        switch (eggy.plugin_manifest.compareVersions(manifest.version, installed.version)) {
            .gt => if (self.installButton(context, std.fmt.allocPrint(arena, "Update to {s}", .{manifest.version}) catch "Update")) self.install(fetched),
            .eq => context.muted(std.fmt.allocPrint(arena, "Version {s} is installed.", .{installed.version}) catch ""),
            .lt => context.muted(std.fmt.allocPrint(arena, "The installed version, {s}, is newer.", .{installed.version}) catch ""),
        }
        self.switchButtons(context, installed);
        page_style.endRow(context);
        self.uninstallNote(context, installed);
    }

    fn installButton(self: *PluginsWindow, context: *ui.Context, label: []const u8) bool {
        if (self.installing != null) {
            context.spinner();
            context.muted("Installing...");
            return false;
        }
        return context.button(label);
    }

    /// An installed plugin's switch, Disable or Enable, and once it is off, Uninstall.
    fn switchButtons(self: *PluginsWindow, context: *ui.Context, installed: Installed) void {
        const arena = context.builder().allocator;
        const off = self.isOff(installed.module);
        if (context.buttonVariant(std.fmt.allocPrint(arena, "{s}##s{s}", .{ if (off) "Enable" else "Disable", installed.module }) catch "Switch", .outline)) {
            self.outcome.switched = .{ .module = installed.module, .on = off };
        }
        if (off and context.buttonVariant(std.fmt.allocPrint(arena, "Uninstall##u{s}", .{installed.module}) catch "Uninstall", .destructive) and self.installing == null) self.uninstall(installed);
    }

    /// What uninstalling an installed plugin that is off leaves behind, when it leaves anything.
    fn uninstallNote(self: *PluginsWindow, context: *ui.Context, installed: Installed) void {
        if (!self.isOff(installed.module)) return;
        const arena = context.builder().allocator;
        const note = if (installed.dependency) |dependency| note: {
            const sharing = self.sharingPackage(installed) orelse break :note null;
            break :note std.fmt.allocPrint(arena, "Its package, {s}, holds {s} too, so uninstalling leaves the package in build.zig.zon: remove it yourself once you no longer want any of them.", .{ dependency, sharing.module }) catch null;
        } else "Uninstalling takes it off this project; Eggy keeps it, to install again.";
        if (note) |text| {
            context.muted(text);
            smallText(context, 12);
        }
    }

    const Marks = struct { version: []const u8, dev: bool, in_eggy: bool = false, installed: bool = false, off: bool = false };

    /// The plugin's version and what kind it is (a library plugin, which ships in the game, or a
    /// dev plugin, which only helps make it), then whether it is inside Eggy, installed or off.
    fn badges(context: *ui.Context, marks: Marks) void {
        const arena = context.builder().allocator;
        context.begin(.row);
        if (marks.version.len > 0) badge(context, std.fmt.allocPrint(arena, "v{s}", .{marks.version}) catch "", .secondary);
        if (marks.dev) badge(context, "Dev plugin: not exported", .outline) else badge(context, "Library plugin", .default);
        if (marks.in_eggy) badge(context, "Inside Eggy", .secondary);
        if (marks.installed) badge(context, "Installed", .secondary);
        if (marks.off) badge(context, "Off", .destructive);
        page_style.endRow(context);
        // Narrow windows put the badges on more lines.
        if (context.last_added) |row| row.style.wrap = true;
    }

    // Installing.

    fn install(self: *PluginsWindow, fetched: *Fetched) void {
        if (self.installing != null) return;
        self.problem.clearRetainingCapacity();
        const manifest = fetched.manifest;
        // An update must be the same package from the same place.
        if (self.installedFor(manifest.module)) |installed| {
            if (installed.fingerprint) |known| if (known != manifest.fingerprint) return self.setProblem("This plugin's fingerprint isn't the installed one's: it is a different package under the same name. Uninstall the installed one first if you mean to replace it.");
            if (installed.repository.len > 0 and !std.mem.eql(u8, installed.repository, manifest.repository)) return self.setProblem("This plugin names another repository than the installed one. Uninstall the installed one first if you mean to replace it.");
        }
        switch (fetched.package) {
            // Eggy's own: nothing to fetch, but this Eggy must have it, with Eggy's fingerprint.
            .eggy => {
                const builtin = self.builtinFor(manifest.module) orelse return self.setProblem("This Eggy doesn't ship that plugin. A newer one might: try File > Upgrade Editor.");
                if (manifest.fingerprint != build_options.fingerprint) return self.setProblem("The plugin says it ships inside Eggy, but its fingerprint isn't Eggy's.");
                self.record(builtin) catch |err| self.failInstall(err);
            },
            .fetch => |package| self.installing = install_zig.Install.start(self.gpa, .{
                .project_dir = self.project_dir,
                .url = package.url,
                .dependency = package.dependency,
                .fingerprint = manifest.fingerprint,
            }) catch |err| blk: {
                self.failInstall(err);
                break :blk null;
            },
        }
    }

    /// List `fetched` in the project's `eggy.zon` (replacing an older entry), for undo.
    fn record(self: *PluginsWindow, fetched: *Fetched) !void {
        const manifest = fetched.manifest;
        const entry = Installed{
            .module = manifest.module,
            .dependency = if (fetched.package == .fetch) fetched.package.fetch.dependency else null,
            .version = manifest.version,
            .dev = manifest.dev,
            .source = if (self.shown_builtin) "" else fetched.origin.text(),
            .repository = manifest.repository,
            .fingerprint = manifest.fingerprint,
        };
        try self.rewritePlugins(entry.module, entry);
        log.info("installed {s} {s}", .{ manifest.module, manifest.version });
    }

    /// Take `installed` out of the project's `eggy.zon`, and its package out of `build.zig.zon`
    /// unless another installed plugin comes from it (or it is Eggy's own).
    fn uninstall(self: *PluginsWindow, installed: Installed) void {
        self.problem.clearRetainingCapacity();
        // Copied, as `rewritePlugins` frees `installed`'s strings.
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const module = arena.dupe(u8, installed.module) catch |err| return self.failInstall(err);
        const package: ?[]const u8 = if (installed.dependency != null and self.sharingPackage(installed) == null)
            arena.dupe(u8, installed.dependency.?) catch |err| return self.failInstall(err)
        else
            null;

        self.rewritePlugins(module, null) catch |err| return self.failInstall(err);
        if (package) |name| self.removePackage(name) catch |err| {
            log.err("cannot take {s} out of build.zig.zon: {t}", .{ name, err });
            self.setProblem("The plugin is uninstalled, but its package is still in build.zig.zon: see the Console.");
        };
        log.info("uninstalled {s}", .{module});
    }

    /// Take dependency `name` out of the project's `build.zig.zon`, as this frame's change's
    /// `package`.
    fn removePackage(self: *PluginsWindow, name: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer dir.close(io);
        const before = try dir.readFileAllocOptions(io, "build.zig.zon", arena, .limited(1 << 20), .of(u8), 0);
        const after = try package_removal.withoutDependency(arena, before, name) orelse return;
        try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = after });
        const before_copy = try self.gpa.dupe(u8, before);
        errdefer self.gpa.free(before_copy);
        self.outcome.change.?.package = .{ .before = before_copy, .after = try self.gpa.dupe(u8, after) };
    }

    /// Write the project's `eggy.zon` with `module`'s entry replaced by `entry` (or removed), as
    /// this frame's `change`.
    fn rewritePlugins(self: *PluginsWindow, module: []const u8, entry: ?Installed) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, self.project_dir, .{});
        defer dir.close(io);
        const before = try dir.readFileAllocOptions(io, eggy.project.file_name, arena, .limited(1 << 20), .of(u8), 0);
        var config = try eggy.project.parse(arena, before);

        var plugins: std.ArrayList(Installed) = .empty;
        var replaced = false;
        for (config.plugins) |installed| {
            if (!std.mem.eql(u8, installed.module, module)) {
                try plugins.append(arena, installed);
            } else if (entry) |new| {
                try plugins.append(arena, new);
                replaced = true;
            }
        }
        if (entry != null and !replaced) try plugins.append(arena, entry.?);
        config.plugins = plugins.items;

        var after: std.Io.Writer.Allocating = .init(arena);
        try eggy.project.write(&after.writer, config);
        try dir.writeFile(io, .{ .sub_path = eggy.project.file_name, .data = after.written() });
        const before_copy = try self.gpa.dupe(u8, before);
        errdefer self.gpa.free(before_copy);
        self.outcome.change = .{ .project = .{ .before = before_copy, .after = try self.gpa.dupe(u8, after.written()) } };
        self.reloadInstalled();
    }

    fn failInstall(self: *PluginsWindow, err: anyerror) void {
        log.err("cannot install the plugin: {t}", .{err});
        self.setProblem("Couldn't change the project's eggy.zon: see the Console.");
    }

    fn setProblem(self: *PluginsWindow, why: []const u8) void {
        self.problem.clearRetainingCapacity();
        self.problem.appendSlice(self.gpa, why) catch {};
    }

    // What is known.

    fn show(self: *PluginsWindow, fetched: *Fetched, builtin: bool) void {
        self.dropShown();
        self.shown = fetched;
        self.shown_builtin = builtin;
        self.problem.clearRetainingCapacity();
        self.content_scroll = .{};
    }

    fn dropShown(self: *PluginsWindow) void {
        if (self.installing != null) return;
        if (self.shown) |fetched| if (!self.shown_builtin) fetched.destroy();
        self.shown = null;
        self.shown_builtin = false;
    }

    fn isOff(self: *const PluginsWindow, module: []const u8) bool {
        for (self.off) |key| if (std.mem.eql(u8, key, module)) return true;
        return false;
    }

    /// Another installed plugin from `installed`'s package, if any.
    fn sharingPackage(self: *const PluginsWindow, installed: Installed) ?Installed {
        const dependency = installed.dependency orelse return null;
        for (self.installed) |other| {
            if (std.mem.eql(u8, other.module, installed.module)) continue;
            if (other.dependency) |name| if (std.mem.eql(u8, name, dependency)) return other;
        }
        return null;
    }

    fn installedFor(self: *const PluginsWindow, module: []const u8) ?Installed {
        for (self.installed) |installed| if (std.mem.eql(u8, installed.module, module)) return installed;
        return null;
    }

    fn builtinFor(self: *const PluginsWindow, module: []const u8) ?*Fetched {
        for (self.builtins) |fetched| if (std.mem.eql(u8, fetched.manifest.module, module)) return fetched;
        return null;
    }

    fn readBuiltins(self: *PluginsWindow) !void {
        const embedded = @import("eggy_builtin_plugins").all;
        var list: std.ArrayList(*Fetched) = .empty;
        errdefer {
            for (list.items) |fetched| fetched.destroy();
            list.deinit(self.gpa);
        }
        for (embedded) |plugin| {
            const path = try std.fmt.allocPrint(self.gpa, "plugins/{s}/eggy.zon", .{plugin.folder});
            defer self.gpa.free(path);
            const fetched = Fetched.create(self.gpa, .{ .path = path }, plugin.manifest, plugin.readme, null) catch |err| {
                log.err("Eggy's plugin {s} has a broken manifest: {t}", .{ plugin.folder, err });
                continue;
            };
            try list.append(self.gpa, fetched);
        }
        self.builtins = try list.toOwnedSlice(self.gpa);
    }

    fn freeBuiltins(self: *PluginsWindow) void {
        for (self.builtins) |fetched| fetched.destroy();
        self.gpa.free(self.builtins);
        self.builtins = &.{};
    }
};

/// Free `change`'s texts.
pub fn freeChange(gpa: std.mem.Allocator, change: Change) void {
    for ([_]?Texts{ change.project, change.package }) |maybe| if (maybe) |texts| {
        gpa.free(texts.before);
        gpa.free(texts.after);
    };
}

/// A small badge, as wide as its text.
fn badge(context: *ui.Context, text: []const u8, variant: anytype) void {
    context.badge(text, variant);
    restyle(context, .{ .width = context.font.measure(text, context.theme.small_text_size) + 20 });
}

/// Shrink `typeset`'s read-me, set for a documentation page (16-point text, headings up to 34),
/// to the editor's text: body text becomes `text_size` and headings keep their order, closer
/// together; its spacing tightens to match.
// ponytail: weeoui's typeset hard-codes its sizes; drop this once it takes the theme's.
fn fitToTheme(element: *ui.Layout.Element, text_size: f32) void {
    const docs_body = 16;
    switch (element.paint_kind) {
        .text => |*text| text.size = text_size * @sqrt(text.size / docs_body),
        else => {},
    }
    const spacing = text_size / docs_body * 0.85;
    element.style.gap *= spacing;
    inline for (.{ "left", "right", "top", "bottom" }) |side| @field(element.style.padding, side) *= spacing;
    for (element.children) |child| fitToTheme(child, text_size);
}

test "a read-me's text is set at the editor's size, headings still larger" {
    var context = try ui.Context.init(std.testing.allocator);
    defer context.deinit();
    context.newFrame(.{ .x = 0, .y = 0, .w = 600, .h = 400 });
    const typeset = try ui.widgets.typeset(context.builder(), "# Title\n\nBody text.", .{});
    fitToTheme(typeset, 14);
    var sizes: [2]f32 = undefined;
    var found: usize = 0;
    var stack: [16]*ui.Layout.Element = @splat(typeset);
    var depth: usize = 1;
    while (depth > 0) {
        depth -= 1;
        const element = stack[depth];
        if (element.paint_kind == .text and found < sizes.len) {
            sizes[found] = element.paint_kind.text.size;
            found += 1;
        }
        for (element.children) |child| {
            stack[depth] = child;
            depth += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), found);
    try std.testing.expectApproxEqAbs(@as(f32, 14), @min(sizes[0], sizes[1]), 0.01);
    try std.testing.expect(@max(sizes[0], sizes[1]) > 18 and @max(sizes[0], sizes[1]) < 22);
}

/// `markdown` without the inline marks `typeset` would show as they are: `**` around bold text,
/// and `[text](address)` links as their text, in `arena`.
// ponytail: drop this once weeoui's typeset styles inline markdown.
fn withoutInlineMarks(arena: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < markdown.len) {
        if (std.mem.startsWith(u8, markdown[at..], "**")) {
            at += 2;
            continue;
        }
        // A link: keep its text, drop its address.
        if (markdown[at] == '[') if (std.mem.indexOfScalarPos(u8, markdown, at, ']')) |close| {
            if (close + 1 < markdown.len and markdown[close + 1] == '(') if (std.mem.indexOfScalarPos(u8, markdown, close, ')')) |end| {
                try out.appendSlice(arena, markdown[at + 1 .. close]);
                at = end + 1;
                continue;
            };
        };
        try out.append(arena, markdown[at]);
        at += 1;
    }
    return out.items;
}

test "a read-me's bold marks and link addresses are dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Open Window > Git, see the docs.\n* a list", try withoutInlineMarks(arena.allocator(), "Open **Window > Git**, see [the docs](https://x.y/z).\n* a list"));
}

/// Whether eggy.zon texts `before` and `after` install different plugins, so the game must be
/// built again. Unreadable texts count as different.
pub fn pluginsDiffer(gpa: std.mem.Allocator, before: []const u8, after: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old = eggy.project.parse(arena, arena.dupeSentinel(u8, before, 0) catch return true) catch return true;
    const new = eggy.project.parse(arena, arena.dupeSentinel(u8, after, 0) catch return true) catch return true;
    if (old.plugins.len != new.plugins.len) return true;
    for (old.plugins, new.plugins) |a, b| {
        if (!std.mem.eql(u8, a.module, b.module) or !std.mem.eql(u8, a.version, b.version) or a.dev != b.dev) return true;
    }
    return false;
}

test {
    _ = source;
    _ = fetch_zig;
    _ = install_zig;
    _ = package_removal;
}

test "Eggy's own plugins have readable manifests that name Eggy" {
    for (@import("eggy_builtin_plugins").all) |plugin| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const manifest = try eggy.plugin_manifest.parse(arena.allocator(), plugin.manifest);
        try std.testing.expect(manifest.inEggy());
        try std.testing.expectEqual(build_options.fingerprint, manifest.fingerprint);
    }
}

test "every page of the Plugins window fits it, narrow or wide" {
    const gpa = std.testing.allocator;
    var context = try ui.Context.init(gpa);
    defer context.deinit();
    var window = PluginsWindow{ .gpa = gpa, .window = undefined, .project_dir = @constCast("/nowhere"), .installed_arena = .init(gpa) };
    defer window.installed_arena.deinit();
    try window.readBuiltins();
    defer window.freeBuiltins();
    defer window.problem.deinit(gpa);
    window.off = &.{ "eggy_git", "a_plugin_with_a_rather_long_module_name" };
    window.installed = &.{
        .{ .module = "eggy_git", .version = "0.1.0", .dev = true },
        .{ .module = "a_second_plugin_from_the_collection", .dependency = "someone_elses_plugin_collection", .version = "1.0.0" },
        .{ .module = "a_plugin_with_a_rather_long_module_name", .dependency = "someone_elses_plugin_collection", .version = "12.0.0-beta.3", .source = "https://raw.githubusercontent.com/someone/plugins/main/x/eggy.zon" },
    };
    // A plugin fetched from elsewhere, without a read-me.
    const elsewhere = try Fetched.create(gpa, .{ .url = "https://raw.githubusercontent.com/someone/eggy-plugins/0123456789abcdef/a/very/deep/folder/eggy.zon" }, ".{ .plugin = .{ .title = \"Elsewhere\", .module = \"elsewhere\", .version = \"2.0.0\", .repository = \"https://github.com/someone/eggy-plugins\", .fingerprint = 1, .minimum_eggy_version = \"99.0.0\" } }", null, null);
    defer elsewhere.destroy();

    for ([_]f32{ 560, 820 }) |width| {
        const viewport = ui.Rect{ .x = 0, .y = 0, .w = width, .h = 600 };
        for (std.enums.values(Section)) |section| for ([_]?*Fetched{ null, window.builtins[0], elsewhere }) |shown| {
            window.section = section;
            window.shown = shown;
            window.shown_builtin = shown != null and shown != elsewhere;
            window.setProblem(if (section == .address) "That eggy.zon is hosted outside the repository it names, so it can't be trusted." else "");
            context.newFrame(viewport);
            window.build(&context);
            _ = try context.render();
            try @import("../ui_checks.zig").expectFits(context.last_root.?, context.font, viewport);
        };
    }
    window.shown = null;
}
