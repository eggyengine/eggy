//! Explicit networking contracts with no transport, sockets, or replication.
const api = @import("support.zig");
pub const support: api.Support = .not_implemented;
pub const Peer = enum(u32) { _ };
pub const Address = struct { host: []const u8, port: u16 };
/// A poll result would borrow bytes from the caller's receive buffer.
pub const Message = struct { peer: Peer, bytes: []const u8 };

// ponytail: networking has no transport, choose and implement one before opening sessions.
pub const Network = struct {
    /// Request a connection to the borrowed host name and numeric port in `address`.
    /// Currently returns `NotImplemented`: no DNS lookup, socket or peer handle is created.
    ///
    /// ```zig
    /// const peer = try app.network.connect(.{ .host = "localhost", .port = 9000 });
    /// // Currently returns NotImplemented, not a placeholder peer.
    /// ```
    pub fn connect(_: Network, address: Address) api.Error!Peer {
        return api.notImplemented(address);
    }
    /// Request a listener at `address`. Currently returns `NotImplemented`, without
    /// reserving a port or retaining the borrowed host name.
    ///
    /// ```zig
    /// try app.network.listen(.{ .host = "127.0.0.1", .port = 9000 }); // NotImplemented.
    /// ```
    pub fn listen(_: Network, address: Address) api.Error!void {
        return api.notImplemented(address);
    }
    /// Request transmission of the caller's borrowed bytes to an existing peer.
    /// Currently returns `NotImplemented`; no bytes are retained, queued or delivered.
    ///
    /// ```zig
    /// try app.network.send(peer, "ping"); // Backend-issued peer; currently NotImplemented.
    /// ```
    pub fn send(_: Network, peer: Peer, bytes: []const u8) api.Error!void {
        return api.notImplemented(.{ peer, bytes });
    }
    /// Request the next message using caller-owned receive storage. A future success would
    /// return a view into `buffer` or null when idle; currently returns `NotImplemented`,
    /// not a successful empty poll, and leaves the buffer untouched.
    ///
    /// ```zig
    /// var buffer: [4096]u8 = undefined;
    /// const message = try app.network.poll(&buffer); // Currently NotImplemented.
    /// ```
    pub fn poll(_: Network, buffer: []u8) api.Error!?Message {
        return api.notImplemented(buffer);
    }
    /// Request closure of a backend-issued peer. Currently returns `NotImplemented`;
    /// no successful disconnection or resource release is implied.
    ///
    /// ```zig
    /// try app.network.disconnect(peer); // Currently NotImplemented.
    /// ```
    pub fn disconnect(_: Network, peer: Peer) api.Error!void {
        return api.notImplemented(peer);
    }
};
