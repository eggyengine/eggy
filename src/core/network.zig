//! Explicit networking contracts with no transport, sockets, or replication.
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;
pub const Peer = enum(u32) { _ };
pub const Address = struct { host: []const u8, port: u16 };
/// A poll result would borrow bytes from the caller's receive buffer.
pub const Message = struct { peer: Peer, bytes: []const u8 };

// ponytail: networking has no transport, choose and implement one before opening sessions.
pub const Network = struct {
    pub fn connect(_: Network, address: Address) api.Error!Peer {
        return api.notImplemented(address);
    }
    pub fn listen(_: Network, address: Address) api.Error!void {
        return api.notImplemented(address);
    }
    pub fn send(_: Network, peer: Peer, bytes: []const u8) api.Error!void {
        return api.notImplemented(.{ peer, bytes });
    }
    pub fn poll(_: Network, buffer: []u8) api.Error!?Message {
        return api.notImplemented(buffer);
    }
    pub fn disconnect(_: Network, peer: Peer) api.Error!void {
        return api.notImplemented(peer);
    }
};
