const std = @import("std");
const vit = @import("vitellus");

const log = std.log.scoped(.slang);

const SlangSession = opaque {};
const SlangCompileRequest = opaque {};

extern fn spCreateSession(deprecated: ?[*:0]const u8) ?*SlangSession;
extern fn spDestroySession(session: *SlangSession) void;
extern fn spCreateCompileRequest(session: *SlangSession) ?*SlangCompileRequest;
extern fn spDestroyCompileRequest(request: *SlangCompileRequest) void;
extern fn spSetCodeGenTarget(request: *SlangCompileRequest, target: c_int) void;
extern fn spSetTargetProfile(request: *SlangCompileRequest, target_index: c_int, profile: u32) void;
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

pub const SlangShaderModule = struct {
    pub const Descriptor = struct {
        code: []const u8,
        entry_point: []const u8 = "main",
        source_path: []const u8 = "shader.slang",
        profile: ?[]const u8 = null,

        pub fn compile(
            self: *const Descriptor,
            allocator: std.mem.Allocator,
            request: vit.hal.shader.ShaderCompileRequest,
        ) !vit.hal.shader.CompiledShader {
            const target: c_int, const format: vit.hal.shader.ShaderBinaryFormat, const default_profile: []const u8 = switch (request.backend) {
                .vulkan => .{ 6, .spirv, "spirv_1_5" },
                .dx12 => .{ 10, .dxil, "sm_6_6" },
                .metal => .{ 25, .metallib, "metal_2_4" },
                .custom => return error.UnsupportedShaderBackend,
            };
            const profile_name = self.profile orelse default_profile;
            log.debug("compiling {s}:{s} ({s}) for {s} with profile {s} ({d} source bytes)", .{
                self.source_path,
                self.entry_point,
                @tagName(request.stage),
                request.backend.name(),
                profile_name,
                self.code.len,
            });

            const session = spCreateSession(null) orelse return error.ShaderCompilerUnavailable;
            defer spDestroySession(session);
            const compile_request = spCreateCompileRequest(session) orelse return error.ShaderCompilerUnavailable;
            defer spDestroyCompileRequest(compile_request);

            const profile = try allocator.dupeZ(u8, profile_name);
            defer allocator.free(profile);
            const profile_id = spFindProfile(session, profile.ptr);
            if (profile_id == 0) return error.InvalidShaderProfile;

            const source = try allocator.dupeZ(u8, self.code);
            defer allocator.free(source);
            const source_path = try allocator.dupeZ(u8, self.source_path);
            defer allocator.free(source_path);
            const entry_point = try allocator.dupeZ(u8, self.entry_point);
            defer allocator.free(entry_point);

            spSetCodeGenTarget(compile_request, target);
            spSetTargetProfile(compile_request, 0, profile_id);
            const translation_unit = spAddTranslationUnit(compile_request, 1, "module");
            if (translation_unit < 0) return error.ShaderCompilationFailed;
            spAddTranslationUnitSourceString(compile_request, translation_unit, source_path.ptr, source.ptr);
            const entry_point_index = spAddEntryPoint(compile_request, translation_unit, entry_point.ptr, slangStage(request.stage));
            if (entry_point_index < 0) return error.ShaderCompilationFailed;

            const result = spCompile(compile_request);
            logDiagnostics(compile_request, result < 0);
            if (result < 0) return error.ShaderCompilationFailed;

            var byte_count: usize = 0;
            const data = spGetEntryPointCode(compile_request, entry_point_index, &byte_count) orelse
                return error.InvalidShaderCompilerOutput;
            if (byte_count == 0) return error.InvalidShaderCompilerOutput;

            const bytes = try allocator.alloc(u8, byte_count);
            @memcpy(bytes, @as([*]const u8, @ptrCast(data))[0..byte_count]);
            log.debug("compiled {s}:{s} to {s} ({d} bytes)", .{
                self.source_path,
                self.entry_point,
                @tagName(format),
                byte_count,
            });
            return .{ .format = format, .bytes = bytes, .entry_point = self.entry_point };
        }
    };

    pub fn init(desc: Descriptor) vit.ShaderModule {
        return vit.ShaderModule.init(desc);
    }
};

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

test "Slang compiles source to SPIR-V" {
    const module = SlangShaderModule.init(.{
        .code = "[shader(\"compute\")] [numthreads(1, 1, 1)] void main() {}",
    });
    var compiled = try module.compile(std.testing.allocator, .{ .backend = .vulkan, .stage = .compute });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(compiled.format.eql(.spirv));
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, compiled.bytes[0..4]);
}
