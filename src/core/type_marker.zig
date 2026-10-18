//! Compilation-local type identities; forget them before unloading their library.
/// Return an opaque identity for `T` within this loaded compilation.
/// Do not persist it or compare identities across separately compiled/reloaded libraries.
///
/// ```zig
/// const marker = of(@import("transform.zig").Transform);
/// ```
pub fn of(comptime T: type) usize {
    const Marker = struct {
        const Type = T;
        var byte: u8 = 0;
    };
    _ = Marker.Type;
    return @intFromPtr(&Marker.byte);
}
