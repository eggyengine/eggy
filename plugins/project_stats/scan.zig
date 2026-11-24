//! What the project is made of, counted from its files: Zig code by files and lines, and every
//! other file by the kind of asset it is, with their sizes. Build output, packages, Eggy's own
//! `.eggy/` folder and hidden files are left out, as are asset descriptors.
const std = @import("std");
const eggy = @import("eggy");
const Kind = eggy.assets.Kind;
const descriptor = eggy.assets.descriptor;

pub const Count = struct { files: u32 = 0, bytes: u64 = 0 };

pub const Scan = struct {
    /// Lines in the project's `.zig` files (its `code` kind).
    code_lines: u64 = 0,
    kinds: std.EnumArray(Kind, Count) = .initFill(.{}),

    /// Every file's size together.
    pub fn totalBytes(self: *const Scan) u64 {
        var total: u64 = 0;
        for (self.kinds.values) |count| total += count.bytes;
        return total;
    }
};

/// Folders no project's content is in.
const skipped = [_][]const u8{ "zig-out", "zig-pkg", "node_modules" };

/// Count the files in `project`.
// ponytail: walks the whole project on the main thread every few seconds while the panel shows; move to a job if big projects stutter.
pub fn scan(gpa: std.mem.Allocator, io: std.Io, project: std.Io.Dir) !Scan {
    var result = Scan{};
    var walker = try project.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.basename[0] == '.') continue;
        if (entry.kind == .directory) {
            if (!isSkipped(entry.basename)) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file or descriptor.isDescriptor(entry.basename)) continue;
        const kind = Kind.of(entry.basename);
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        const count = result.kinds.getPtr(kind);
        count.files += 1;
        count.bytes += stat.size;
        if (kind == .code) result.code_lines += countLines(gpa, io, entry.dir, entry.basename) catch 0;
    }
    return result;
}

fn isSkipped(name: []const u8) bool {
    for (skipped) |folder| if (std.mem.eql(u8, name, folder)) return true;
    return false;
}

fn countLines(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !u64 {
    const text = try dir.readFileAlloc(io, name, gpa, .limited(64 << 20));
    defer gpa.free(text);
    if (text.len == 0) return 0;
    const breaks = std.mem.count(u8, text, "\n");
    return breaks + @intFromBool(text[text.len - 1] != '\n');
}
