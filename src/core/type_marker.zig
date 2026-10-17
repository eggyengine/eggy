//! Compilation-local type identities; forget them before unloading their library.
pub fn of(comptime T: type) usize {
    const Marker = struct {
        const Type = T;
        var byte: u8 = 0;
    };
    _ = Marker.Type;
    return @intFromPtr(&Marker.byte);
}
