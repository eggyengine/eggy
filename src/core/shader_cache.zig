//! A project's shaders on the GPU, by asset identity: each loaded through `loader` the first
//! time a material or post pass uses it, then kept. The editor's loader composes and compiles the
//! `.slang` while running; the runtime's reads what the build compiled (`src/build/shaders.zig`).
const std = @import("std");
const vit = @import("vitellus");
const Role = @import("shaders/compose.zig").Role;
const log = std.log.scoped(.shaders);

/// A shader compiled for the GPU in use (SPIR-V, or WGSL on the web), entry `Role.entry_point`.
pub const Compiled = struct {
    /// Owned by the loader's caller.
    bytes: []u8,
    role: Role,
};

/// How a shader's identity key becomes compiled code.
pub const Loader = struct {
    context: *anyopaque,
    load: *const fn (context: *anyopaque, gpa: std.mem.Allocator, key: []const u8) anyerror!Compiled,
};

/// A loaded shader: its fragment stage, which renderers make pipelines with.
pub const Gpu = struct {
    fragment: vit.Shader,
    role: Role,
};

pub const ShaderCache = struct {
    gpa: std.mem.Allocator,
    device: vit.Device,
    shaderSource: *const fn ([]const u8, []const u8) vit.ShaderModule,
    /// Where shaders come from; none (every custom shader is left out) until set.
    loader: ?Loader = null,
    /// By key, which the map owns; null for one that didn't load, so it isn't tried again.
    entries: std.StringHashMapUnmanaged(?Gpu) = .empty,
    /// Changes whenever shaders are forgotten, so renderers remake the pipelines they made.
    revision: u64 = 0,

    /// Free every shader. The GPU must be done with them.
    pub fn deinit(self: *ShaderCache) void {
        self.forgetAll();
        self.entries.deinit(self.gpa);
    }

    /// Forget every shader, so each loads again when next used: its file may have changed.
    /// The GPU must be done with them; pipelines made from them must be remade (`revision`).
    pub fn forgetAll(self: *ShaderCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |loaded| loaded.fragment.deinit();
            self.gpa.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
        self.revision +%= 1;
    }

    /// The shader `key` names, loading it the first time; null if it can't be (logged once).
    pub fn get(self: *ShaderCache, key: []const u8) ?Gpu {
        if (self.entries.get(key)) |known| return known;
        const loaded = self.load(key) catch |err| blk: {
            log.err("shader {s} can't be used: {t}", .{ key, err });
            break :blk null;
        };
        const owned = self.gpa.dupe(u8, key) catch {
            if (loaded) |made| made.fragment.deinit();
            return null;
        };
        self.entries.put(self.gpa, owned, loaded) catch {
            self.gpa.free(owned);
            if (loaded) |made| made.fragment.deinit();
            return null;
        };
        return loaded;
    }

    fn load(self: *ShaderCache, key: []const u8) !Gpu {
        const loader = self.loader orelse return error.NoShaderLoader;
        const compiled = try loader.load(loader.context, self.gpa, key);
        defer self.gpa.free(compiled.bytes);
        const fragment = try vit.Shader.init(self.device, .{ .label = "project shader", .stage = .fragment, .source = self.shaderSource(compiled.bytes, Role.entry_point) });
        return .{ .fragment = fragment, .role = compiled.role };
    }
};
