//! Support reporting for developer-facing capabilities.
pub const Support = enum { available, not_implemented, unsupported_platform };
pub const Error = error{NotImplemented};

/// Consume a request without effects while retaining meaningful public parameter names.
/// Internal helper for capability contracts: returns `error.NotImplemented` directly,
/// not an error union or a fabricated result; never retains or validates `request`.
///
/// ```zig
/// // Inside a capability implementation returning an error union:
/// return api.notImplemented(.{ entity, options });
/// ```
pub fn notImplemented(request: anytype) Error {
    _ = request;
    return error.NotImplemented;
}
