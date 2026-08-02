const std = @import("std");
const vit = @import("vitellus");

const log = std.log.scoped(.slang);

const SlangSession = opaque {};
const SlangCompileRequest = opaque {};
const SlangReflection = opaque {};

const slang_ok: i32 = 0;
const slang_container_module: c_int = 1;
const slang_language_slang: c_int = 1;
const slang_target_spirv: c_int = 6;
const slang_target_dxil: c_int = 10;
const slang_target_metallib: c_int = 25;

extern fn spCreateSession(deprecated: ?[*:0]const u8) ?*SlangSession;
extern fn spDestroySession(session: *SlangSession) void;
extern fn spCreateCompileRequest(session: *SlangSession) ?*SlangCompileRequest;
extern fn spDestroyCompileRequest(request: *SlangCompileRequest) void;
extern fn spSetCodeGenTarget(request: *SlangCompileRequest, target: c_int) void;
extern fn spSetTargetProfile(request: *SlangCompileRequest, target_index: c_int, profile: u32) void;
extern fn spSetOutputContainerFormat(request: *SlangCompileRequest, format: c_int) void;
extern fn spProcessCommandLineArguments(
    request: *SlangCompileRequest,
    args: [*]const [*:0]const u8,
    arg_count: c_int,
) i32;
extern fn spAddSearchPath(request: *SlangCompileRequest, search_dir: [*:0]const u8) void;
extern fn spFindProfile(session: *SlangSession, name: [*:0]const u8) u32;
extern fn spAddTranslationUnit(request: *SlangCompileRequest, language: c_int, name: [*:0]const u8) c_int;
extern fn spAddTranslationUnitSourceString(
    request: *SlangCompileRequest,
    translation_unit_index: c_int,
    path: [*:0]const u8,
    source: [*:0]const u8,
) void;
extern fn spAddEntryPoint(
    request: *SlangCompileRequest,
    translation_unit_index: c_int,
    name: [*:0]const u8,
    stage: u32,
) c_int;
extern fn spCompile(request: *SlangCompileRequest) i32;
extern fn spGetDiagnosticOutput(request: *SlangCompileRequest) ?[*:0]const u8;
extern fn spGetEntryPointCode(
    request: *SlangCompileRequest,
    entry_point_index: c_int,
    size: *usize,
) ?*const anyopaque;
extern fn spGetContainerCode(request: *SlangCompileRequest, out_blob: *?*ISlangBlob) i32;
extern fn spGetReflection(request: *SlangCompileRequest) ?*SlangReflection;
extern fn spReflection_GetParameterCount(reflection: *SlangReflection) c_uint;
extern fn spReflection_GetParameterByIndex(reflection: *SlangReflection, index: c_uint) ?*SlangReflectionParameter;
extern fn spReflectionVariableLayout_GetVariable(parameter: *SlangReflectionParameter) ?*SlangReflectionVariable;
extern fn spReflectionVariable_GetName(variable: *SlangReflectionVariable) ?[*:0]const u8;
extern fn spReflectionParameter_GetBindingIndex(parameter: *SlangReflectionParameter) c_uint;
extern fn spReflectionParameter_GetBindingSpace(parameter: *SlangReflectionParameter) c_uint;

const SlangReflectionParameter = opaque {};
const SlangReflectionVariable = opaque {};

const ISlangBlob = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        queryInterface: *const fn (*ISlangBlob, *const anyopaque, *?*anyopaque) callconv(.c) i32,
        addRef: *const fn (*ISlangBlob) callconv(.c) u32,
        release: *const fn (*ISlangBlob) callconv(.c) u32,
        getBufferPointer: *const fn (*ISlangBlob) callconv(.c) ?*const anyopaque,
        getBufferSize: *const fn (*ISlangBlob) callconv(.c) usize,
    };

    fn release(self: *ISlangBlob) void {
        _ = self.vtable.release(self);
    }

    fn bytes(self: *ISlangBlob) ![]const u8 {
        const size = self.vtable.getBufferSize(self);
        if (size == 0) return error.InvalidShaderCompilerOutput;
        const ptr = self.vtable.getBufferPointer(self) orelse return error.InvalidShaderCompilerOutput;
        return @as([*]const u8, @ptrCast(ptr))[0..size];
    }
};

/// Precompiled Slang module/library blob, equivalent to `slangc -r`.
///
/// `path` is the on-disk module name used for `import` resolution (typically
/// `"tint.slang-module"`). The blob is staged into a temporary search path and
/// referenced with `-r` during compile.
pub const Library = struct {
    path: []const u8,
    data: []const u8,
};

pub const SlangShaderModule = struct {
    pub const Descriptor = struct {
        code: []const u8,
        entry_point: []const u8 = "main",
        source_path: []const u8 = "shader.slang",
        profile: ?[]const u8 = null,
        /// Optional precompiled Slang libraries linked into this compile (`-r`).
        libraries: []const Library = &.{},

        pub fn compile(
            self: *const Descriptor,
            allocator: std.mem.Allocator,
            request: vit.hal.shader.ShaderCompileRequest,
        ) !vit.hal.shader.CompiledShader {
            const target: c_int, const format: vit.hal.shader.ShaderBinaryFormat, const default_profile: []const u8 = switch (request.backend) {
                .vulkan => .{ slang_target_spirv, .spirv, "spirv_1_5" },
                .dx12 => .{ slang_target_dxil, .dxil, "sm_6_6" },
                .metal => .{ slang_target_metallib, .metallib, "metal_2_4" },
                .custom => return error.UnsupportedShaderBackend,
            };
            const profile_name = self.profile orelse default_profile;

            var compiled = try compileKernel(self, allocator, .{
                .target = target,
                .profile = profile_name,
                .stage = request.stage,
            });
            errdefer compiled.deinit(allocator);

            // DX12/Metal consume non-SPIR-V kernels; keep SPIR-V alongside for
            // vitellus bind-group reflection (`CompiledShader.reflection_spirv`).
            if (format != .spirv) {
                var reflection = try compileKernel(self, allocator, .{
                    .target = slang_target_spirv,
                    .profile = "spirv_1_5",
                    .stage = request.stage,
                });
                errdefer reflection.deinit(allocator);
                compiled.reflection_spirv = reflection.bytes;
                reflection.bytes = &.{};
            }

            log.debug("compiled {s}:{s} to {s} ({d} bytes, reflection={s})", .{
                self.source_path,
                self.entry_point,
                @tagName(format),
                compiled.bytes.len,
                if (compiled.reflection_spirv != null) "spirv" else "inline",
            });

            const result: vit.hal.shader.CompiledShader = .{
                .format = format,
                .bytes = compiled.bytes,
                .entry_point = self.entry_point,
                .reflection_spirv = compiled.reflection_spirv,
            };
            compiled.bytes = &.{};
            compiled.reflection_spirv = null;
            return result;
        }

        /// Compiles this source into a `.slang-module` container suitable for
        /// later `Library.data` use (linked via staged `-r` / search path).
        ///
        /// Matches `slangc <file> -o <file>.slang-module`.
        pub fn compileLibrary(self: *const Descriptor, allocator: std.mem.Allocator) ![]u8 {
            const session = spCreateSession(null) orelse return error.ShaderCompilerUnavailable;
            defer spDestroySession(session);
            const compile_request = spCreateCompileRequest(session) orelse return error.ShaderCompilerUnavailable;
            defer spDestroyCompileRequest(compile_request);

            const source = try allocator.dupeZ(u8, self.code);
            defer allocator.free(source);
            const source_path = try allocator.dupeZ(u8, self.source_path);
            defer allocator.free(source_path);

            // Library modules are IR containers, not target kernels — no codegen
            // target / entry point. `-emit-ir` is required for getContainerCode
            // to populate a SlangModule artifact (same as slangc -o *.slang-module).
            const emit_ir_args = [_][*:0]const u8{"-emit-ir"};
            if (spProcessCommandLineArguments(compile_request, &emit_ir_args, emit_ir_args.len) < slang_ok) {
                return error.ShaderCompilationFailed;
            }
            spSetOutputContainerFormat(compile_request, slang_container_module);

            var staged = try stageLibraries(allocator, compile_request, self.libraries);
            defer staged.deinit(allocator);

            const translation_unit = spAddTranslationUnit(compile_request, slang_language_slang, "module");
            if (translation_unit < 0) return error.ShaderCompilationFailed;
            spAddTranslationUnitSourceString(compile_request, translation_unit, source_path.ptr, source.ptr);

            const result = spCompile(compile_request);
            logDiagnostics(compile_request, result < 0);
            if (result < 0) return error.ShaderCompilationFailed;

            var blob: ?*ISlangBlob = null;
            const get_hr = spGetContainerCode(compile_request, &blob);
            const owned = blob orelse return error.InvalidShaderCompilerOutput;
            defer owned.release();
            if (get_hr < slang_ok) return error.InvalidShaderCompilerOutput;

            const data = try owned.bytes();
            // RIFF "SLmc" slang-module header (same as slangc -o *.slang-module).
            if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "SLmc")) {
                return error.InvalidShaderCompilerOutput;
            }
            return try allocator.dupe(u8, data);
        }
    };

    pub fn init(desc: Descriptor) vit.ShaderModule {
        return vit.ShaderModule.init(desc);
    }
};

const CompileOptions = struct {
    target: c_int,
    profile: []const u8,
    stage: vit.hal.shader.ShaderStage,
};

const KernelOutput = struct {
    bytes: []u8,
    reflection_spirv: ?[]u8 = null,

    fn deinit(self: KernelOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        if (self.reflection_spirv) |spirv| allocator.free(spirv);
    }
};

fn compileKernel(
    desc: *const SlangShaderModule.Descriptor,
    allocator: std.mem.Allocator,
    options: CompileOptions,
) !KernelOutput {
    log.debug("compiling {s}:{s} ({s}) target={d} profile={s} ({d} source bytes, {d} libs)", .{
        desc.source_path,
        desc.entry_point,
        @tagName(options.stage),
        options.target,
        options.profile,
        desc.code.len,
        desc.libraries.len,
    });

    const session = spCreateSession(null) orelse return error.ShaderCompilerUnavailable;
    defer spDestroySession(session);
    const compile_request = spCreateCompileRequest(session) orelse return error.ShaderCompilerUnavailable;
    defer spDestroyCompileRequest(compile_request);

    const source = try allocator.dupeZ(u8, desc.code);
    defer allocator.free(source);
    const source_path = try allocator.dupeZ(u8, desc.source_path);
    defer allocator.free(source_path);
    const entry_point = try allocator.dupeZ(u8, desc.entry_point);
    defer allocator.free(entry_point);

    const profile = try allocator.dupeZ(u8, options.profile);
    defer allocator.free(profile);
    const profile_id = spFindProfile(session, profile.ptr);
    if (profile_id == 0) return error.InvalidShaderProfile;
    spSetCodeGenTarget(compile_request, options.target);
    spSetTargetProfile(compile_request, 0, profile_id);

    var staged = try stageLibraries(allocator, compile_request, desc.libraries);
    defer staged.deinit(allocator);

    const translation_unit = spAddTranslationUnit(compile_request, slang_language_slang, "module");
    if (translation_unit < 0) return error.ShaderCompilationFailed;
    spAddTranslationUnitSourceString(compile_request, translation_unit, source_path.ptr, source.ptr);

    const entry_point_index = spAddEntryPoint(compile_request, translation_unit, entry_point.ptr, slangStage(options.stage));
    if (entry_point_index < 0) return error.ShaderCompilationFailed;

    const result = spCompile(compile_request);
    logDiagnostics(compile_request, result < 0);
    if (result < 0) return error.ShaderCompilationFailed;

    if (spGetReflection(compile_request)) |reflection| {
        const count = spReflection_GetParameterCount(reflection);
        log.debug("reflection parameters={d}", .{count});
        var i: c_uint = 0;
        while (i < count) : (i += 1) {
            const param = spReflection_GetParameterByIndex(reflection, i) orelse continue;
            const name = blk: {
                const variable = spReflectionVariableLayout_GetVariable(param) orelse break :blk "<anon>";
                break :blk if (spReflectionVariable_GetName(variable)) |n| std.mem.span(n) else "<anon>";
            };
            log.debug("  param[{d}] {s} binding={d} space={d}", .{
                i,
                name,
                spReflectionParameter_GetBindingIndex(param),
                spReflectionParameter_GetBindingSpace(param),
            });
        }
    }

    var byte_count: usize = 0;
    const data = spGetEntryPointCode(compile_request, entry_point_index, &byte_count) orelse
        return error.InvalidShaderCompilerOutput;
    if (byte_count == 0) return error.InvalidShaderCompilerOutput;
    const bytes = try allocator.alloc(u8, byte_count);
    @memcpy(bytes, @as([*]const u8, @ptrCast(data))[0..byte_count]);
    return .{ .bytes = bytes };
}

fn slangStage(stage: vit.hal.shader.ShaderStage) u32 {
    return switch (stage) {
        .vertex => 1,
        .fragment => 5,
        .compute => 6,
    };
}

fn logDiagnostics(request: *SlangCompileRequest, failed: bool) void {
    const diagnostics = spGetDiagnosticOutput(request) orelse return;
    const message = std.mem.trim(u8, std.mem.span(diagnostics), "\x00\r\n");
    if (message.len == 0) return;
    if (failed) log.err("compilation failed: {s}", .{message}) else log.warn("compilation diagnostics: {s}", .{message});
}

/// Stages library blobs onto disk and wires them with `spAddSearchPath` + `-r`,
/// matching how `slangc -r` / `-I` resolve `import` of precompiled modules.
///
/// In-memory `spAddLibraryReference` loads IR but does not satisfy `import`
/// resolution the same way the file-backed `-r` path does.
const StagedLibraries = struct {
    dir_rel: ?[]u8 = null,

    fn deinit(self: *StagedLibraries, allocator: std.mem.Allocator) void {
        if (self.dir_rel) |dir| {
            var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            std.Io.Dir.cwd().deleteTree(io, dir) catch {};
            allocator.free(dir);
            self.dir_rel = null;
        }
    }
};

var slang_lib_stage_counter: std.atomic.Value(u64) = .init(0);

fn stageLibraries(
    allocator: std.mem.Allocator,
    request: *SlangCompileRequest,
    libraries: []const Library,
) !StagedLibraries {
    if (libraries.len == 0) return .{};

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const stamp = slang_lib_stage_counter.fetchAdd(1, .monotonic);
    const dir_rel = try std.fmt.allocPrint(allocator, ".zig-cache/slang-lib-stage/{d}-{d}", .{ std.Thread.getCurrentId(), stamp });
    errdefer allocator.free(dir_rel);

    try cwd.createDirPath(io, dir_rel);
    var staged: StagedLibraries = .{ .dir_rel = dir_rel };
    errdefer staged.deinit(allocator);

    const dir_z = try allocator.dupeZ(u8, dir_rel);
    defer allocator.free(dir_z);
    spAddSearchPath(request, dir_z.ptr);

    var tmp_dir = try cwd.openDir(io, dir_rel, .{});
    defer tmp_dir.close(io);

    for (libraries) |library| {
        if (library.data.len == 0) return error.InvalidShaderLibrary;
        if (library.path.len == 0) return error.InvalidShaderLibrary;

        var file_name_buf: [std.fs.max_name_bytes]u8 = undefined;
        const file_name = try libraryFileName(library.path, &file_name_buf);
        try tmp_dir.writeFile(io, .{ .sub_path = file_name, .data = library.data });

        const abs_or_rel = try std.fs.path.join(allocator, &.{ dir_rel, file_name });
        defer allocator.free(abs_or_rel);
        const path_z = try allocator.dupeZ(u8, abs_or_rel);
        defer allocator.free(path_z);

        const args = [_][*:0]const u8{ "-r", path_z.ptr };
        if (spProcessCommandLineArguments(request, &args, args.len) < slang_ok) {
            return error.ShaderLibraryLinkFailed;
        }
    }

    return staged;
}

fn libraryFileName(path: []const u8, buf: *[std.fs.max_name_bytes]u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".slang-module") or std.mem.endsWith(u8, base, ".slang-lib")) {
        return base;
    }
    return std.fmt.bufPrint(buf, "{s}.slang-module", .{base});
}

test "Slang compiles source to SPIR-V" {
    const module = SlangShaderModule.init(.{
        .code = "[shader(\"compute\")] [numthreads(1, 1, 1)] void main() {}",
    });
    var compiled = try module.compile(std.testing.allocator, .{ .backend = .vulkan, .stage = .compute });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(compiled.format.eql(.spirv));
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, compiled.bytes[0..4]);
    try std.testing.expect(compiled.reflection_spirv == null);
}

test "Slang DXIL compile retains SPIR-V reflection" {
    const module = SlangShaderModule.init(.{
        .code =
            \\[[vk::binding(0, 0)]]
            \\ConstantBuffer<float4> color;
            \\[shader("fragment")]
            \\float4 main() : SV_Target { return color; }
        ,
        .entry_point = "main",
    });
    var compiled = try module.compile(std.testing.allocator, .{ .backend = .dx12, .stage = .fragment });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(compiled.format.eql(.dxil));
    const spirv = compiled.reflection_spirv orelse return error.MissingReflectionSpirv;
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, spirv[0..4]);
}

test "Slang compiles a reusable module library" {
    const lib_desc = SlangShaderModule.Descriptor{
        .code =
            \\module tint;
            \\public float4 apply(float4 c) { return c * 0.5; }
        ,
        .source_path = "tint.slang",
    };
    const library = try lib_desc.compileLibrary(std.testing.allocator);
    defer std.testing.allocator.free(library);
    try std.testing.expect(library.len > 12);
    try std.testing.expectEqualSlices(u8, "RIFF", library[0..4]);
    try std.testing.expectEqualSlices(u8, "SLmc", library[8..12]);

    const module = SlangShaderModule.init(.{
        .code =
            \\import tint;
            \\[shader("compute")]
            \\[numthreads(1, 1, 1)]
            \\void main() { float4 x = apply(float4(1, 1, 1, 1)); }
        ,
        .libraries = &.{.{ .path = "tint.slang-module", .data = library }},
    });
    var compiled = try module.compile(std.testing.allocator, .{ .backend = .vulkan, .stage = .compute });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(compiled.format.eql(.spirv));
}
