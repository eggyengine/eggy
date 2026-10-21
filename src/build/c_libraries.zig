//! How the C libraries Eggy builds (SDL, assimp) are optimized: never as Debug, as stepping
//! into them is rare and their unoptimized code slows the whole editor down.
const std = @import("std");

/// The mode to build a C library in for a build in `mode`: Debug builds get ReleaseFast C
/// libraries; release builds keep their own mode (ReleaseSmall stays small for the web).
pub fn optimize(mode: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    return if (mode == .Debug) .ReleaseFast else mode;
}
