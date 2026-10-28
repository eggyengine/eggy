//! One Buzz REPL that lasts across the dev console's lines, so what one line declares the next can use.
const std = @import("std");
const buzz = @import("buzz");

/// Whether this build can run Buzz (see `src/build/buzz.zig`).
pub const available = buzz.available;

/// What a session's scripts reach through Eggy's natives, `print` and `run`.
pub const Host = struct {
    context: *anyopaque,
    /// Show `text` as a line of output.
    print: *const fn (context: *anyopaque, text: []const u8) void,
    /// Run `line` as a console command; false if there is no such command or it failed.
    run: *const fn (context: *anyopaque, line: []const u8) bool,
};

/// Buzz's keywords, for completion; none where it isn't built in.
pub fn keywords() []const []const u8 {
    return if (available) buzz.Token.keywords.keys() else &.{};
}

/// A running REPL, or where Buzz isn't built in, a stand-in that says so.
pub const Session = if (available) Repl else Unavailable;

const Unavailable = struct {
    pub fn init(_: std.mem.Allocator, _: std.process.Init) !*Unavailable {
        return error.ScriptingUnavailable;
    }
    pub fn deinit(_: *Unavailable) void {}
    pub fn run(_: *Unavailable, _: []const u8, _: []const u8, _: Host, _: *std.Io.Writer) error{LineFailed}!void {}
    pub fn globalNames(_: *Unavailable, _: std.mem.Allocator) ![]const []const u8 {
        return &.{};
    }
};

/// The natives every session declares before its first line.
const prelude =
    \\extern fun print(value: str) > void;
    \\extern fun run(command: str) > bool;
;
/// The script name Eggy's natives are looked up under (`native_name` in Buzz's parser).
const natives_script = "eggy";
/// The script name each typed line runs as, which errors show.
pub const line_name = "console";

/// The host of the line being run, which the natives call. One line runs at a time, on the
/// main thread.
var running_host: ?Host = null;

const Repl = struct {
    /// Everything Buzz allocates, which it never fully frees itself, freed at once by `deinit`.
    // ponytail: memory Buzz's GC frees is only reclaimed when the session ends; give it the gpa
    // once Buzz frees its REPL state cleanly.
    arena: std.heap.ArenaAllocator,
    vm: *buzz.vm.VM,
    parser: *buzz.Parser,
    codegen: *buzz.CodeGen,
    /// The globals (indices into the parser's) each script file last declared, by its name, so
    /// running it again replaces them rather than clashing with them.
    declared: std.StringHashMapUnmanaged([]const usize),

    /// Start a session, running the prelude that declares Eggy's natives. `process` must outlive it.
    pub fn init(gpa: std.mem.Allocator, process: std.process.Init) !*Repl {
        const self = try gpa.create(Repl);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();

        // Buzz's compiler and VM, as its own REPL makes them.
        const gc = try allocator.create(buzz.GC);
        gc.* = try buzz.GC.init(allocator);
        gc.type_registry = try buzz.TypeRegistry.init(gc);
        const import_registry = try allocator.create(buzz.vm.ImportRegistry);
        import_registry.* = .{};
        const imports = try allocator.create(std.StringHashMapUnmanaged(buzz.Parser.ScriptImport));
        imports.* = .empty;
        const dlibs = try allocator.create(std.StringHashMapUnmanaged(buzz.Parser.Dlib));
        dlibs.* = .empty;
        // Eggy's natives stand in for the dynamic library Buzz would open for `natives_script`.
        try dlibs.put(allocator, natives_script, .{ .dynlib = undefined, .lookup_fn = lookupNative });

        self.vm = try allocator.create(buzz.vm.VM);
        self.vm.* = try buzz.vm.VM.init(process, gc, import_registry, .Repl, null);
        self.parser = try allocator.create(buzz.Parser);
        self.parser.* = buzz.Parser.init(process, gc, imports, dlibs, false, .Repl);
        self.codegen = try allocator.create(buzz.CodeGen);
        self.codegen.* = buzz.CodeGen.init(process, gc, self.parser, .Repl, null, false);
        // Reports are kept, to show in the console, rather than written to stderr.
        self.parser.reporter.collect = true;
        self.codegen.reporter.collect = true;
        self.vm.reporter.collect = true;
        self.declared = .empty;

        _ = try self.evaluate(prelude, natives_script);
        if (self.parser.reporter.last_error != null or self.codegen.reporter.last_error != null) return error.PreludeFailed;
        return self;
    }

    pub fn deinit(self: *Repl) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Run `source` (a typed line, or a whole script file) as the session's next line, named
    /// `name` in its errors: its errors, or the value it ends with, are written to `out`, and its
    /// `print`s and `run`s go to `host`. A script run again first retires what it declared last
    /// time, so it can be edited and rerun. A line that fails leaves the session as it was before
    /// it and returns `error.LineFailed`, once its errors are written.
    pub fn run(self: *Repl, source: []const u8, name: []const u8, host: Host, out: *std.Io.Writer) !void {
        const allocator = self.arena.allocator();
        // What the line may add to, put back if it fails (as Buzz's own REPL does).
        const global_count = self.vm.globals_count;
        const parser_globals = try self.parser.globals.clone(allocator);
        const parser_lookup = try self.parser.globals_lookup.cloneContext(allocator, buzz.Ast.QualifiedName.Context{ .ast = &self.parser.ast });
        const vm_globals = try self.vm.globals.clone(allocator);
        const types = try self.vm.gc.type_registry.registry.clone(allocator);

        // A script's last run steps aside for this one; the lines typed are never retired.
        const is_script = !std.mem.eql(u8, name, line_name);
        if (is_script) if (self.declared.get(name)) |indices| for (indices) |index| self.retire(index);
        const first_declared = self.parser.globals.items.len;

        // Buzz keeps the source in its tokens, and the line in the console is reused.
        const owned = try allocator.dupe(u8, source);
        running_host = host;
        defer running_host = null;
        const result = self.evaluate(owned, try allocator.dupe(u8, name)) catch |err| switch (err) {
            error.RuntimeError, error.Recoverable => null,
            else => return err,
        };

        const failed = self.parser.reporter.last_error != null or self.codegen.reporter.last_error != null or self.vm.reporter.last_error != null;
        try self.writeReports(out);
        if (failed) {
            self.parser.globals = parser_globals;
            self.parser.globals_lookup = parser_lookup;
            self.vm.globals = vm_globals;
            self.vm.globals_count = global_count;
            self.vm.gc.type_registry.registry = types;
            return error.LineFailed;
        }
        if (is_script) {
            const indices = try allocator.alloc(usize, self.parser.globals.items.len - first_declared);
            for (indices, first_declared..) |*index, declared| index.* = declared;
            try self.declared.put(allocator, try allocator.dupe(u8, name), indices);
        }
        if (result) |value| {
            var state = buzz.disassembler.DumpState{ .vm = self.vm };
            state.valueDump(value, out, false);
            try out.writeByte('\n');
        }
    }

    /// Hide the parser's global `index` from lookups, so a new declaration of its name stands
    /// alone. Code compiled against it keeps using it.
    fn retire(self: *Repl, index: usize) void {
        const global = &self.parser.globals.items[index];
        if (global.hidden) return;
        global.hidden = true;
        _ = self.parser.globals_lookup.removeContext(global.qualified_name, .{ .ast = &self.parser.ast });
    }

    /// The names the session's lines have declared (and its natives), for completion, in `arena`.
    pub fn globalNames(self: *Repl, arena: std.mem.Allocator) ![]const []const u8 {
        const lexemes = self.parser.ast.tokens.items(.lexeme);
        var names: std.ArrayList([]const u8) = .empty;
        for (self.parser.globals.items) |global| {
            if (global.hidden or global.qualified_name.namespace.len != 0) continue;
            const name = lexemes[global.qualified_name.name];
            if (name.len == 0 or name[0] == '$') continue;
            try names.append(arena, name);
        }
        return names.toOwnedSlice(arena);
    }

    /// Parse, compile and run `source`, returning the value of a lone expression it ends with.
    fn evaluate(self: *Repl, source: []const u8, name: []const u8) !?buzz.value.Value {
        const ast = try self.parser.parse(source, &.{}, null, name) orelse return error.Recoverable;
        const slice = ast.slice();
        const function = try self.codegen.generate(slice) orelse return error.Recoverable;
        try self.vm.interpret(slice, function, null);

        const components = slice.nodes.items(.components);
        const statements = components[components[ast.root.?].Function.body.?].Block;
        if (statements.len == 0 or slice.nodes.items(.tag)[statements[statements.len - 1]] != .Expression) return null;
        // The REPL returns the expression's value even when it has none, such as `print`'s.
        const value = self.vm.pop();
        const type_def = slice.nodes.items(.type_def)[statements[statements.len - 1]];
        return if (type_def != null and type_def.?.def_type == .Void) null else value;
    }

    /// Write and clear what the compiler and VM reported, a line each with its notes, then ready
    /// them for the next line. Buzz's own layout quotes the source in box-drawing characters,
    /// which a one-line console doesn't need.
    fn writeReports(self: *Repl, out: *std.Io.Writer) !void {
        for ([_]*buzz.Reporter{ &self.parser.reporter, &self.codegen.reporter, &self.vm.reporter }) |reporter| {
            for (reporter.reports.items) |report| {
                try out.writeAll(report.message);
                // A script's errors say where in the file; a typed line has only the one.
                if (report.items.len != 0) {
                    const at = report.items[0].location;
                    if (std.mem.eql(u8, at.script_name, line_name)) try out.print(" (column {d})", .{at.column + 1}) else try out.print(" ({s}:{d}:{d})", .{ at.script_name, at.line + 1, at.column + 1 });
                }
                try out.writeByte('\n');
                for (report.notes) |note| try out.print("  {s}\n", .{note.message});
            }
            reporter.reports.clearRetainingCapacity();
            reporter.last_error = null;
            reporter.panic_mode = false;
        }
    }
};

/// Buzz's lookup of a native in `natives_script`'s library.
fn lookupNative(symbol: [*:0]const u8) callconv(.c) ?buzz.obj.NativeFn {
    const name = std.mem.span(symbol);
    if (std.mem.eql(u8, name, "print")) return &printNative;
    if (std.mem.eql(u8, name, "run")) return &runNative;
    return null;
}

fn printNative(ctx: *buzz.obj.NativeCtx) callconv(.c) c_int {
    if (running_host) |host| host.print(host.context, stringArg(ctx.vm.peek(0)));
    return 0;
}

fn runNative(ctx: *buzz.obj.NativeCtx) callconv(.c) c_int {
    const ran = if (running_host) |host| host.run(host.context, stringArg(ctx.vm.peek(0))) else false;
    ctx.vm.push(.fromBoolean(ran));
    return 1;
}

fn stringArg(value: buzz.value.Value) []const u8 {
    if (!value.isObj()) return "";
    const string = buzz.obj.ObjString.cast(value.obj()) orelse return "";
    return string.string;
}

/// A process for tests (the console's too): the test runner's I/O and environment, and an empty environment map.
pub const TestProcess = struct {
    arena: std.heap.ArenaAllocator,
    environ_map: std.process.Environ.Map,

    pub fn init(self: *TestProcess) std.process.Init {
        self.* = .{ .arena = .init(std.testing.allocator), .environ_map = .init(std.testing.allocator) };
        return .{
            .minimal = .{ .environ = std.testing.environ, .args = undefined },
            .arena = &self.arena,
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .environ_map = &self.environ_map,
            .preopens = .empty,
        };
    }
    pub fn deinit(self: *TestProcess) void {
        self.environ_map.deinit();
        self.arena.deinit();
    }
};

const Captured = struct {
    printed: std.ArrayList(u8) = .empty,
    ran: std.ArrayList(u8) = .empty,

    fn host(self: *Captured) Host {
        return .{ .context = self, .print = print, .run = runCommand };
    }
    fn print(context: *anyopaque, text: []const u8) void {
        const self: *Captured = @ptrCast(@alignCast(context));
        self.printed.appendSlice(std.testing.allocator, text) catch {};
    }
    fn runCommand(context: *anyopaque, line: []const u8) bool {
        const self: *Captured = @ptrCast(@alignCast(context));
        self.ran.appendSlice(std.testing.allocator, line) catch {};
        return std.mem.eql(u8, line, "known");
    }
    fn deinit(self: *Captured) void {
        self.printed.deinit(std.testing.allocator);
        self.ran.deinit(std.testing.allocator);
    }
};

test "a session keeps what one line declares for the next, and shows the value a line ends with" {
    if (!available) return error.SkipZigTest;
    var process: TestProcess = undefined;
    defer process.deinit();
    var session = try Session.init(std.testing.allocator, process.init());
    defer session.deinit();
    var captured: Captured = .{};
    defer captured.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try session.run("var speed = 3;", line_name, captured.host(), &out.writer);
    try session.run("speed * 2", line_name, captured.host(), &out.writer);
    try std.testing.expectEqualStrings("6\n", out.written());
}

test "a line's errors are written out, and what it declared is forgotten" {
    if (!available) return error.SkipZigTest;
    var process: TestProcess = undefined;
    defer process.deinit();
    var session = try Session.init(std.testing.allocator, process.init());
    defer session.deinit();
    var captured: Captured = .{};
    defer captured.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.LineFailed, session.run("var broken: int = \"text\";", line_name, captured.host(), &out.writer));
    try std.testing.expect(out.written().len != 0);
    out.clearRetainingCapacity();
    try session.run("var broken = 1;", line_name, captured.host(), &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "scripts reach the console through print and run" {
    if (!available) return error.SkipZigTest;
    var process: TestProcess = undefined;
    defer process.deinit();
    var session = try Session.init(std.testing.allocator, process.init());
    defer session.deinit();
    var captured: Captured = .{};
    defer captured.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try session.run("print(\"hello\")", line_name, captured.host(), &out.writer);
    try session.run("run(\"known\")", line_name, captured.host(), &out.writer);
    try std.testing.expectEqualStrings("hello", captured.printed.items);
    try std.testing.expectEqualStrings("known", captured.ran.items);
    try std.testing.expectEqualStrings("true\n", out.written());
}

test "a script file runs whole, and what it declares stays for later lines" {
    if (!available) return error.SkipZigTest;
    var process: TestProcess = undefined;
    defer process.deinit();
    var session = try Session.init(std.testing.allocator, process.init());
    defer session.deinit();
    var captured: Captured = .{};
    defer captured.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const script =
        \\fun twice(value: int) > int {
        \\    return value * 2;
        \\}
        \\print("loaded");
    ;
    try session.run(script, "mod.buzz", captured.host(), &out.writer);
    try session.run("twice(21)", line_name, captured.host(), &out.writer);
    try std.testing.expectEqualStrings("loaded", captured.printed.items);
    try std.testing.expectEqualStrings("42\n", out.written());
}

test "running a script again replaces what it declared, and a failed rerun keeps the old" {
    if (!available) return error.SkipZigTest;
    var process: TestProcess = undefined;
    defer process.deinit();
    var session = try Session.init(std.testing.allocator, process.init());
    defer session.deinit();
    var captured: Captured = .{};
    defer captured.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try session.run("fun speed() > int { return 1; }", "mod.buzz", captured.host(), &out.writer);
    try session.run("fun speed() > int { return 2; }", "mod.buzz", captured.host(), &out.writer);
    try session.run("speed()", line_name, captured.host(), &out.writer);
    try std.testing.expectEqualStrings("2\n", out.written());

    out.clearRetainingCapacity();
    try std.testing.expectError(error.LineFailed, session.run("fun speed() > int { return \"3\"; }", "mod.buzz", captured.host(), &out.writer));
    out.clearRetainingCapacity();
    try session.run("speed()", line_name, captured.host(), &out.writer);
    try std.testing.expectEqualStrings("2\n", out.written());
}

test "a script's errors say which file, line and column" {
    if (!available) return error.SkipZigTest;
    var process: TestProcess = undefined;
    defer process.deinit();
    var session = try Session.init(std.testing.allocator, process.init());
    defer session.deinit();
    var captured: Captured = .{};
    defer captured.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.LineFailed, session.run("var fine = 1;\nvar broken: int = \"text\";", "mod.buzz", captured.host(), &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(mod.buzz:2:") != null);
}
