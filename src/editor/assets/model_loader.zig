//! Model files as the editor draws them: imported straight from the project's file through
//! assimp (`eggy_model_import`), with its descriptor's settings, whenever the scene's model cache
//! asks for one. (The runtime loads what packaging made of them instead.)
const std = @import("std");
const eggy = @import("eggy");
const model_import = @import("eggy_model_import");
const log = std.log.scoped(.models);

pub const ProjectModels = struct {
    /// The project's folder; the model files' paths are relative to it.
    project_dir: []const u8,

    /// A loader for `eggy.model_cache.ModelCache`; `self` must outlive it.
    pub fn loader(self: *ProjectModels) eggy.model_cache.Loader {
        return .{ .context = self, .load = load };
    }

    fn load(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?eggy.assets.Model {
        const self: *ProjectModels = @ptrCast(@alignCast(context));
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        // Its import settings, from its descriptor (the defaults until it has one).
        var project = std.Io.Dir.cwd().openDir(io, self.project_dir, .{}) catch |err| {
            log.err("cannot open {s}: {t}", .{ self.project_dir, err });
            return null;
        };
        defer project.close(io);
        const found = eggy.assets.descriptor.read(arena.allocator(), io, project, path) catch |err| blk: {
            log.warn("{s}'s descriptor doesn't read ({t}): importing it as it is", .{ path, err });
            break :blk null;
        };
        const settings = if (found) |descriptor| descriptor.model else eggy.assets.descriptor.ModelImport{};

        const full_path = std.fs.path.joinZ(arena.allocator(), &.{ self.project_dir, path }) catch return null;
        return model_import.import(gpa, full_path, settings) catch |err| {
            log.err("cannot import {s}: {s} ({t})", .{ path, model_import.lastError(), err });
            return null;
        };
    }
};
