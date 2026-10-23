//! How the C libraries Eggy builds (SDL, assimp) are optimized: never as debug, as stepping
//! into them is rare and their unoptimized code slows the whole editor down.
const std = @import("std");

/// The mode to build a C library in for a build in `mode`: Debug builds get `.fast` C
/// libraries; release builds keep their own mode (`.small` stays small for the web).
pub fn optimize(mode: std.builtin.Optimize) std.builtin.Optimize {
    return if (mode == .debug) .fast else mode;
}
