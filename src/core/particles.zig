//! Particles: emitters that send out short-lived points, moved on game time and drawn each frame
//! as camera-facing world sprites (`draw2d.zig`), fading out as they age. Bursts send out a
//! number at once; a rate keeps sending until stopped. No collision: they fly through things.
const std = @import("std");
const api = @import("support.zig");
const math = @import("eggenvector");
const AssetRef = @import("refs.zig").AssetRef;
const Draw2d = @import("draw2d.zig").Draw2d;
pub const support: api.Support = .available;

/// Names one `emit` call, to stop it.
pub const Emitter = enum(u32) { _ };

/// The most particles alive at once; emitters send out no more past it.
// ponytail: a fixed cap drawn as world sprites; draw them instanced on the GPU if games need more.
pub const max_particles = 10_000;

pub const Options = struct {
    /// Where they start, in metres.
    position_m: math.Vec3,
    /// How many to send out at once, or with `rate_per_s` the most it sends before stopping
    /// itself (0: until `stop`).
    count: u32 = 1,
    /// Particles sent out each second, for as long as it runs; 0 sends `count` at once.
    rate_per_s: f32 = 0,
    /// How long each lives, in seconds.
    lifetime_s: f32 = 1,
    /// How each starts moving, in metres per second, and how far off that it may start, at
    /// random, in any direction.
    velocity_m_per_s: math.Vec3 = .zero,
    spread_m_per_s: f32 = 0,
    /// Pulled along this way as they fly, in metres per second per second (as gravity would).
    acceleration_m_per_s2: math.Vec3 = .zero,
    /// How big each is, across, in metres.
    size_m: f32 = 0.1,
    /// Its colour (RGBA, 0 to 1), times the image's; it fades to clear as it ages when `fade`.
    color: [4]f32 = @splat(1),
    fade: bool = true,
    /// An image each is drawn with; none draws plain squares of `color`.
    image: AssetRef(.image) = .{},
};

pub const Particles = struct {
    gpa: std.mem.Allocator = std.heap.c_allocator,
    emitters: std.ArrayList(Source) = .empty,
    alive: std.ArrayList(Particle) = .empty,
    next_emitter: u32 = 1,
    random: std.Random.DefaultPrng = .init(0x6567_6779),

    /// One emitter: what it sends out, how many so far, and the part of one it is owed.
    const Source = struct {
        id: Emitter,
        options: Options,
        sent: u32 = 0,
        owed: f32 = 0,
        stopped: bool = false,
    };

    const Particle = struct {
        emitter: Emitter,
        position_m: math.Vec3,
        velocity_m_per_s: math.Vec3,
        age_s: f32 = 0,
    };

    pub fn deinit(self: *Particles) void {
        self.emitters.deinit(self.gpa);
        self.alive.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa, .next_emitter = self.next_emitter };
    }

    /// Start sending out particles as `options` say: `count` at once, or `rate_per_s` each second
    /// until `stop` (or `count` sent, when given). They move from the next update on, by game
    /// time. Returns the emitter, to stop it. Fails with `InvalidParticleOptions` for a negative
    /// or non-finite lifetime, rate or spread, a size that isn't positive, a colour outside 0 to
    /// 1, or a burst of none.
    ///
    /// ```zig
    /// const sparks = try app.particles.emit(.{
    ///     .position_m = .init(0, 1, 0), .count = 20, .lifetime_s = 0.5, .spread_m_per_s = 2,
    /// });
    /// ```
    pub fn emit(self: *Particles, options: Options) !Emitter {
        for ([_]f32{ options.lifetime_s, options.rate_per_s, options.spread_m_per_s }) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidParticleOptions;
        }
        for (options.color) |channel| if (!std.math.isFinite(channel) or channel < 0 or channel > 1) return error.InvalidParticleOptions;
        if (!std.math.isFinite(options.size_m) or options.size_m <= 0) return error.InvalidParticleOptions;
        if (options.rate_per_s == 0 and options.count == 0) return error.InvalidParticleOptions;
        const id: Emitter = @fromBackingInt(@intCast(self.next_emitter));
        self.next_emitter +%= 1;
        try self.emitters.append(self.gpa, .{ .id = id, .options = options });
        return id;
    }

    /// Stop `emitter` sending out more; those already out live their time. Stopping one that has
    /// already finished does nothing.
    ///
    /// ```zig
    /// try app.particles.stop(sparks);
    /// ```
    pub fn stop(self: *Particles, emitter: Emitter) !void {
        if (@backingInt(emitter) == 0 or @backingInt(emitter) >= self.next_emitter) return error.UnknownEmitter;
        if (self.find(emitter)) |source| source.stopped = true;
    }

    /// How many particles are out now.
    pub fn count(self: *const Particles) usize {
        return self.alive.items.len;
    }

    /// Move every particle on by `delta_s` of game time, send out what each emitter owes, and let
    /// go of particles past their lifetime and of emitters done with theirs. Host-only: once
    /// an update, after the game's systems.
    pub fn step(self: *Particles, delta_s: f32) void {
        // The old ones move and age, and those past their time go.
        var kept: usize = 0;
        for (self.alive.items) |particle| {
            const source = self.find(particle.emitter) orelse continue;
            var moved = particle;
            moved.age_s += delta_s;
            if (moved.age_s >= source.options.lifetime_s) continue;
            moved.velocity_m_per_s = moved.velocity_m_per_s.add(source.options.acceleration_m_per_s2.scale(delta_s));
            moved.position_m = moved.position_m.add(moved.velocity_m_per_s.scale(delta_s));
            self.alive.items[kept] = moved;
            kept += 1;
        }
        self.alive.shrinkRetainingCapacity(kept);

        // Then each emitter sends out what it owes.
        for (self.emitters.items) |*source| {
            if (source.stopped) continue;
            const due: u32 = if (source.options.rate_per_s == 0) source.options.count else blk: {
                source.owed += source.options.rate_per_s * delta_s;
                const whole: u32 = @intFromFloat(@floor(source.owed));
                source.owed -= @floatFromInt(whole);
                break :blk if (source.options.count == 0) whole else @min(whole, source.options.count - source.sent);
            };
            for (0..due) |_| {
                if (self.alive.items.len >= max_particles) break;
                self.alive.append(self.gpa, self.spawn(source)) catch break;
            }
            source.sent += due;
            if (source.options.rate_per_s == 0 or (source.options.count != 0 and source.sent >= source.options.count)) source.stopped = true;
        }

        // Emitters stopped with nothing left out are done.
        var kept_emitters: usize = 0;
        for (self.emitters.items) |source| {
            const has_alive = for (self.alive.items) |particle| {
                if (particle.emitter == source.id) break true;
            } else false;
            if (source.stopped and !has_alive) continue;
            self.emitters.items[kept_emitters] = source;
            kept_emitters += 1;
        }
        self.emitters.shrinkRetainingCapacity(kept_emitters);
    }

    /// Ask `world` to draw every particle this frame, facing the camera. Running out of memory
    /// is an error; a particle that flew off to infinity is left undrawn.
    pub fn draw(self: *Particles, world: *Draw2d) !void {
        for (self.alive.items) |particle| {
            const source = self.find(particle.emitter) orelse continue;
            const options = source.options;
            var tint = options.color;
            if (options.fade and options.lifetime_s > 0) tint[3] *= 1 - particle.age_s / options.lifetime_s;
            world.sprite(.{
                .image = options.image,
                .position = particle.position_m.xy(),
                .depth_m = particle.position_m.z,
                .size = .splat(options.size_m),
                .tint = tint,
                .billboard = true,
            }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
        }
    }

    fn spawn(self: *Particles, source: *const Source) Particle {
        const random = self.random.random();
        var velocity = source.options.velocity_m_per_s;
        if (source.options.spread_m_per_s > 0) {
            // A random direction, as far as the spread at most.
            const direction = math.Vec3.init(random.float(f32) * 2 - 1, random.float(f32) * 2 - 1, random.float(f32) * 2 - 1);
            velocity = velocity.add(direction.scale(source.options.spread_m_per_s));
        }
        return .{ .emitter = source.id, .position_m = source.options.position_m, .velocity_m_per_s = velocity };
    }

    fn find(self: *Particles, emitter: Emitter) ?*Source {
        for (self.emitters.items) |*source| if (source.id == emitter) return source;
        return null;
    }
};

test "a burst sends its count at once, they fly and fall, and go when their time is up" {
    var particles = Particles{ .gpa = std.testing.allocator };
    defer particles.deinit();
    _ = try particles.emit(.{ .position_m = .zero, .count = 5, .lifetime_s = 1, .velocity_m_per_s = .unit_x, .acceleration_m_per_s2 = .init(0, -10, 0) });
    particles.step(0);
    try std.testing.expectEqual(@as(usize, 5), particles.count());
    particles.step(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), particles.alive.items[0].position_m.x, 0.001);
    try std.testing.expect(particles.alive.items[0].position_m.y < 0);
    particles.step(0.6);
    try std.testing.expectEqual(@as(usize, 0), particles.count());
    try std.testing.expectEqual(@as(usize, 0), particles.emitters.items.len);
}

test "a rate keeps sending until stopped, and bad options are refused" {
    var particles = Particles{ .gpa = std.testing.allocator };
    defer particles.deinit();
    const stream = try particles.emit(.{ .position_m = .zero, .count = 0, .rate_per_s = 10, .lifetime_s = 5 });
    particles.step(0.5);
    try std.testing.expectEqual(@as(usize, 5), particles.count());
    try particles.stop(stream);
    particles.step(0.5);
    try std.testing.expectEqual(@as(usize, 5), particles.count());
    try std.testing.expectError(error.UnknownEmitter, particles.stop(@fromBackingInt(@intCast(99))));
    try std.testing.expectError(error.InvalidParticleOptions, particles.emit(.{ .position_m = .zero, .lifetime_s = -1 }));
}
