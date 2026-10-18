//! Support reporting for developer-facing capabilities.
pub const Support = enum { available, not_implemented, unsupported_platform };
pub const Error = error{NotImplemented};

/// Consume a request without effects while retaining meaningful public parameter names.
pub fn notImplemented(request: anytype) Error {
    _ = request;
    return error.NotImplemented;
}
