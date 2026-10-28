//! The commands every game's console has before its own: help, and looking at and changing the world.
const std = @import("std");
const App = @import("../app.zig").App;
const ecs = @import("clutch");
const scene = @import("../scene.zig");
const commands = @import("commands.zig");
const Command = commands.Command;
const Call = commands.Call;

/// Eggy's commands, in the order `help` lists them.
pub const Builtin = enum { help, clear, run, entities, get, set, timescale };

/// What each `Builtin` is, as `help` shows it.
pub const list = [_]Command{
    .{ .name = "help", .help = "List the commands, or say what one does", .usage = "[command]" },
    .{ .name = "clear", .help = "Clear the console" },
    .{ .name = "run", .help = "Run a Buzz script file; what it declares stays for later lines", .usage = "<path.buzz>" },
    .{ .name = "entities", .help = "List the named entities, or those whose name holds some text", .usage = "[text]" },
    .{ .name = "get", .help = "Show a component's field as ZON", .usage = "<entity> <Component.field>" },
    .{ .name = "set", .help = "Set a component's field from ZON", .usage = "<entity> <Component.field> <zon>" },
    .{ .name = "timescale", .help = "Show or set how fast game time passes (1 is normal)", .usage = "[scale]" },
};

/// Run `builtin` (all but `clear` and `run`, which the console carries out) on `app`. `game_commands` are
/// the game's and plugins', for `help`. Bad words are reported in `call`, not returned.
pub fn run(builtin: Builtin, app: *App, call: *Call, game_commands: []const Command) !void {
    switch (builtin) {
        .help => help(call, game_commands),
        .clear, .run => {},
        .entities => try listEntities(app, call),
        .get, .set => {
            const access = app.scene_access orelse return call.print("there is no game running to look into", .{});
            const name = call.arg(0) orelse return usage(call, builtin);
            const path = call.arg(1) orelse return usage(call, builtin);
            const entity = find(app, access, name) orelse return call.print("no entity is named {s}", .{name});
            const component, const field = locate(access, path) orelse return call.print("no component field {s} (write it as Component.field)", .{path});
            if (builtin == .get) {
                const text = access.readFieldAlloc(call.arena, &app.world, entity, component, field) catch |err| switch (err) {
                    error.NoComponent, error.NoSuchComponent => return call.print("{s} has no {s}", .{ name, access.types()[component].name }),
                    error.OutOfMemory => return err,
                };
                return call.print("{s}", .{text});
            }
            const value = call.rest(2);
            if (value.len == 0) return usage(call, builtin);
            if (!access.has(&app.world, entity, component)) return call.print("{s} has no {s}", .{ name, access.types()[component].name });
            if (!access.writeField(&app.world, entity, component, field, try call.arena.dupeSentinel(u8, value, 0))) return call.print("{s} isn't a value {s} can take", .{ value, path });
        },
        .timescale => {
            const text = call.arg(0) orelse return call.print("{d}", .{app.time.scale});
            const scale = std.fmt.parseFloat(f32, text) catch return usage(call, builtin);
            if (!std.math.isFinite(scale) or scale < 0) return call.print("the scale can't be negative", .{});
            app.time.scale = scale;
        },
    }
}

fn usage(call: *Call, builtin: Builtin) void {
    const command = list[@backingInt(builtin)];
    call.print("usage: {s} {s}", .{ command.name, command.usage });
}

fn help(call: *Call, game_commands: []const Command) void {
    // One command in full, when named.
    if (call.arg(0)) |name| {
        for ([_][]const Command{ &list, game_commands }) |group| for (group) |command| if (std.mem.eql(u8, command.name, name)) {
            call.print("{s} {s}", .{ command.name, command.usage });
            if (command.help.len != 0) call.print("  {s}", .{command.help});
            return;
        };
        return call.print("there is no command {s}", .{name});
    }
    // Eggy's, then the game's; anything else typed runs as Buzz.
    for ([_][]const Command{ &list, game_commands }) |group| for (group) |command| {
        call.print("{s} {s}  {s}", .{ command.name, command.usage, command.help });
    };
    call.print("Anything else runs as Buzz: print(\"hi\"), run(\"timescale 0.5\").", .{});
}

fn listEntities(app: *App, call: *Call) !void {
    const access = app.scene_access orelse return call.print("there is no game running to look into", .{});
    const filter = call.arg(0) orelse "";
    var shown: usize = 0;
    var buffer: [256]u8 = undefined;
    for (app.world.slots.items, 0..) |slot, index| {
        if (!slot.alive) continue;
        const entity = ecs.EntityId.init(@intCast(index), slot.generation);
        const name = access.name(&app.world, entity, &buffer) orelse continue;
        if (std.ascii.findIgnoreCase(name, filter) == null) continue;
        call.print("#{d}  {s}", .{ index, name });
        shown += 1;
    }
    if (shown == 0) call.print("no named entities{s}{s}", .{ if (filter.len != 0) " hold " else "", filter });
}

/// The entity `reference` names: `#<id>`, or the first whose name it is.
fn find(app: *App, access: scene.Access, reference: []const u8) ?ecs.EntityId {
    if (reference.len > 1 and reference[0] == '#') {
        const index = std.fmt.parseInt(u32, reference[1..], 10) catch return null;
        if (index >= app.world.slots.items.len or !app.world.slots.items[index].alive) return null;
        return ecs.EntityId.init(index, app.world.slots.items[index].generation);
    }
    // By name, through the game's own `Name` (the editor's world types live in the game's library).
    var buffer: [256]u8 = undefined;
    for (app.world.slots.items, 0..) |slot, index| {
        if (!slot.alive) continue;
        const entity = ecs.EntityId.init(@intCast(index), slot.generation);
        const name = access.name(&app.world, entity, &buffer) orelse continue;
        if (std.mem.eql(u8, name, reference)) return entity;
    }
    return null;
}

/// The component and field `path` (`Component.field`) names, as indices into `access.types()`.
fn locate(access: scene.Access, path: []const u8) ?struct { usize, usize } {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return null;
    for (access.types(), 0..) |info, component| {
        if (!std.mem.eql(u8, info.name, path[0..dot])) continue;
        for (info.fields, 0..) |field, index| if (std.mem.eql(u8, field.name, path[dot + 1 ..])) return .{ component, index };
    }
    return null;
}

/// Each component's fields as `Component.field`, for completion, in `arena`.
pub fn fieldPaths(arena: std.mem.Allocator, access: ?scene.Access) ![]const []const u8 {
    const through = access orelse return &.{};
    var paths: std.ArrayList([]const u8) = .empty;
    for (through.types()) |info| for (info.fields) |field| {
        try paths.append(arena, try std.fmt.allocPrint(arena, "{s}.{s}", .{ info.name, field.name }));
    };
    return paths.toOwnedSlice(arena);
}

/// Folders `run` doesn't look for scripts in: build output, caches and the editor's own.
const unscripted = [_][]const u8{ "zig-out", ".zig-cache", ".git", ".eggy", "node_modules" };
/// The most script paths offered to complete `run`.
const max_scripts = 200;

/// The `.buzz` files under the working directory, as `run` takes them, for completion, in
/// `arena`. Unreadable folders are skipped.
pub fn scriptPaths(arena: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch null) |entry| switch (entry.kind) {
        .directory => {
            for (unscripted) |name| {
                if (std.mem.eql(u8, entry.basename, name)) break;
            } else walker.enter(io, entry) catch {};
        },
        .file => if (std.mem.endsWith(u8, entry.basename, ".buzz")) {
            try paths.append(arena, try arena.dupe(u8, entry.path));
            if (paths.items.len == max_scripts) break;
        },
        else => {},
    };
    return paths.toOwnedSlice(arena);
}

/// The names of `app`'s named entities, for completion, in `arena`.
pub fn entityNames(arena: std.mem.Allocator, app: *App) ![]const []const u8 {
    const access = app.scene_access orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    for (app.world.slots.items, 0..) |slot, index| {
        if (!slot.alive) continue;
        const name = try access.nameAlloc(arena, &app.world, ecs.EntityId.init(@intCast(index), slot.generation)) orelse continue;
        try names.append(arena, name);
    }
    return names.toOwnedSlice(arena);
}

test "every builtin is listed in its enum's order" {
    inline for (@typeInfo(Builtin).@"enum".field_names, 0..) |name, index| try std.testing.expectEqualStrings(name, list[index].name);
}

test "help lists Eggy's commands and the game's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var call = Call{ .line = "help", .args = &.{}, .out = &out.writer, .arena = arena.allocator() };
    help(&call, &.{.{ .name = "god", .help = "Never die" }});
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "timescale") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "god   Never die") != null);
}
