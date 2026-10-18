//! C-callable input requests; Zig errors never cross separately compiled game libraries.
const types = @import("types.zig");
pub const Operation = enum(u32) {
    controller_count,
    controllers,
    controller_state,
    rumble,
    touch_count,
    touches,
    register_controls,
    set_bindings,
    set_trigger,
    reset_bindings,
    get_bindings,
    control_state,
    control_value,
    map_enabled,
    map_priority,
    game_event,
    suppress_event,
    buttons_changed,
    end_frame,
    cancel,
    release_all,
};
pub const Status = enum(u32) {
    ok,
    no_device,
    unknown_control,
    buffer_too_small,
    invalid_binding,
    transient_device,
    duplicate_controls,
    out_of_memory,
    unsupported,
    io_failed,
    sdl_failed,
    wrong_thread,
    wrong_kind,
    invalid_trigger,
};
pub const Request = extern struct {
    operation: Operation,
    control: types.ControlId = .{ .type_marker = 0, .tag = 0 },
    device: u32 = 0,
    data: ?*const anyopaque = null,
    /// Null probes the required element count for controllers, touches, or get_bindings.
    output: ?*anyopaque = null,
    count: usize = 0,
    low: u16 = 0,
    high: u16 = 0,
    duration_ms: u32 = 0,
    priority: i32 = 0,
};
pub const Response = extern struct { count: usize = 0 };
pub const Bridge = extern struct {
    context: *anyopaque,
    request: *const fn (*anyopaque, *const Request, *Response) callconv(.c) Status,
};

/// Host/library bridge helper: translate a stable C status into this compilation's Zig error.
/// `.ok` succeeds; no allocation or state change occurs. Call after a synchronous request,
/// rather than passing compilation-local error numbers across the library boundary.
///
/// ```zig
/// // With a live bridge, initialized request and response:
/// try check(bridge.request(bridge.context, &request, &response));
/// ```
pub fn check(status: Status) !void {
    return switch (status) {
        .ok => {},
        .no_device => error.ControllerDisconnected,
        .unknown_control => error.UnknownControl,
        .buffer_too_small => error.BufferTooSmall,
        .invalid_binding => error.InvalidBinding,
        .transient_device => error.TransientControllerBinding,
        .duplicate_controls => error.DuplicateControls,
        .out_of_memory => error.OutOfMemory,
        .unsupported => error.UnsupportedDeviceFeature,
        .io_failed => error.InputSettingsFailed,
        .sdl_failed => error.SdlError,
        .wrong_thread => error.WrongThread,
        .wrong_kind => error.WrongControlKind,
        .invalid_trigger => error.InvalidTrigger,
    };
}
