//! The pipelines a renderer made from project shaders, by shader key and variant (a renderer's
//! own number for how it draws with it), dropped when the shaders they were made from are
//! (`ShaderCache.revision`).
const std = @import("std");
const vit = @import("vitellus");

// ponytail: a fixed handful per renderer, refused past that; grow it if scenes use more shaders.
const capacity = 64;

pub const ShaderPipelines = struct {
    keys: [capacity]u64 = undefined,
    pipelines: [capacity]vit.GraphicsPipeline = undefined,
    len: usize = 0,
    /// The shader cache's revision they were made at.
    revision: u64 = 0,
    /// Whether running out of room was reported, so it is logged once.
    full_reported: bool = false,

    /// The pipeline made for shader `key` as `variant`, or null; forgets them all first when
    /// `revision` (the shader cache's) moved on, which only happens once the GPU is idle.
    pub fn get(self: *ShaderPipelines, key: []const u8, variant: u32, revision: u64) ?vit.GraphicsPipeline {
        if (revision != self.revision) {
            self.deinit();
            self.revision = revision;
        }
        const hash = std.hash.Wyhash.hash(variant, key);
        for (self.keys[0..self.len], self.pipelines[0..self.len]) |known, pipeline| if (known == hash) return pipeline;
        return null;
    }

    /// Keep `pipeline` for `key` as `variant`, returning it; when there's no room it is freed
    /// (the GPU never saw it) and null returned, logged once.
    pub fn put(self: *ShaderPipelines, key: []const u8, variant: u32, pipeline: vit.GraphicsPipeline) ?vit.GraphicsPipeline {
        if (self.len == capacity) {
            pipeline.deinit();
            if (!self.full_reported) std.log.err("more than {d} project shader pipelines in one view: the rest are drawn without theirs", .{capacity});
            self.full_reported = true;
            return null;
        }
        self.keys[self.len] = std.hash.Wyhash.hash(variant, key);
        self.pipelines[self.len] = pipeline;
        self.len += 1;
        return pipeline;
    }

    /// Free every pipeline. The GPU must be done with them.
    pub fn deinit(self: *ShaderPipelines) void {
        for (self.pipelines[0..self.len]) |pipeline| pipeline.deinit();
        self.len = 0;
        self.full_reported = false;
    }
};
