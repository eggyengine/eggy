//! In-process Slang compiler, backed by the bundled shared library.
const std = @import("std");
const builtin = @import("builtin");

pub const Stage = enum(u32) { vertex = 1, fragment = 5, compute = 6 };

/// Compile Slang source to SPIR-V. Caller owns the returned bytes.
pub fn compileSpirv(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entry: []const u8, stage: Stage) ![]u8 {
    const dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(dir);
    const rel = switch (builtin.os.tag) {
        .linux => "../lib/libslang-compiler.so",
        .macos => "../lib/libslang-compiler.dylib",
        .windows => "slang-compiler.dll",
        else => return error.UnsupportedPlatform,
    };
    const path = try std.fs.path.join(allocator, &.{ dir, rel });
    defer allocator.free(path);
    return compileSpirvFromLibrary(allocator, path, source, entry, stage);
}

/// Use an explicit Slang library path, useful for tools and tests.
pub fn compileSpirvFromLibrary(allocator: std.mem.Allocator, library_path: []const u8, source: []const u8, entry: []const u8, stage: Stage) ![]u8 {
    var lib = try std.DynLib.open(library_path);
    defer lib.close();
    // ponytail: Slang's compatibility C ABI keeps this Zig wrapper small; switch to a C++ bridge if Slang removes it.
    const create_session = try symbol(*const fn (?[*:0]const u8) callconv(.c) ?*anyopaque, &lib, "spCreateSession");
    const destroy_session = try symbol(*const fn (*anyopaque) callconv(.c) void, &lib, "spDestroySession");
    const create_request = try symbol(*const fn (*anyopaque) callconv(.c) ?*anyopaque, &lib, "spCreateCompileRequest");
    const destroy_request = try symbol(*const fn (*anyopaque) callconv(.c) void, &lib, "spDestroyCompileRequest");
    const set_target = try symbol(*const fn (*anyopaque, u32) callconv(.c) void, &lib, "spSetCodeGenTarget");
    const add_unit = try symbol(*const fn (*anyopaque, u32, ?[*:0]const u8) callconv(.c) c_int, &lib, "spAddTranslationUnit");
    const add_source = try symbol(*const fn (*anyopaque, c_int, [*:0]const u8, [*:0]const u8) callconv(.c) void, &lib, "spAddTranslationUnitSourceString");
    const add_entry = try symbol(*const fn (*anyopaque, c_int, [*:0]const u8, u32) callconv(.c) c_int, &lib, "spAddEntryPoint");
    const compile = try symbol(*const fn (*anyopaque) callconv(.c) c_int, &lib, "spCompile");
    const diagnostics = try symbol(*const fn (*anyopaque) callconv(.c) ?[*:0]const u8, &lib, "spGetDiagnosticOutput");
    const get_code = try symbol(*const fn (*anyopaque, c_int, *usize) callconv(.c) ?*const anyopaque, &lib, "spGetEntryPointCode");

    const session = create_session(null) orelse return error.SlangInitializationFailed;
    defer destroy_session(session);
    const request = create_request(session) orelse return error.SlangInitializationFailed;
    defer destroy_request(request);
    set_target(request, 6); // SLANG_SPIRV
    const unit = add_unit(request, 1, null); // SLANG_SOURCE_LANGUAGE_SLANG
    if (unit < 0) return error.ShaderCompilationFailed;
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);
    const entry_z = try allocator.dupeZ(u8, entry);
    defer allocator.free(entry_z);
    add_source(request, unit, "shader.slang", source_z);
    const index = add_entry(request, unit, entry_z, @intFromEnum(stage));
    if (index < 0) return error.ShaderCompilationFailed;
    if (compile(request) < 0) {
        if (diagnostics(request)) |message| std.log.err("Slang: {s}", .{std.mem.span(message)});
        return error.ShaderCompilationFailed;
    }
    var len: usize = 0;
    const ptr = get_code(request, index, &len) orelse return error.InvalidSpirv;
    const bytes: [*]const u8 = @ptrCast(ptr);
    if (len < 20 or !std.mem.eql(u8, bytes[0..4], &.{ 0x03, 0x02, 0x23, 0x07 })) return error.InvalidSpirv;
    return allocator.dupe(u8, bytes[0..len]);
}

fn symbol(comptime T: type, lib: *std.DynLib, comptime name: [:0]const u8) !T {
    return lib.lookup(T, name) orelse error.MissingSlangSymbol;
}

test "runtime compiler returns valid SPIR-V" {
    const library = @import("slang_library").library;
    const source = @embedFile("shaders/ui.slang");
    const vertex = try compileSpirvFromLibrary(std.testing.allocator, library, source, "vertexMain", .vertex);
    defer std.testing.allocator.free(vertex);
    const fragment = try compileSpirvFromLibrary(std.testing.allocator, library, source, "fragmentMain", .fragment);
    defer std.testing.allocator.free(fragment);
    try std.testing.expect(vertex.len > 20 and fragment.len > 20);
}
