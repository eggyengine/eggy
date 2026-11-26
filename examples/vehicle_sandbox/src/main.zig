//! Vehicle physics sandbox: a four-wheel truck towing a two-wheel trailer with a hinged rear ramp
//! and a motorized sliding deck section over a heightfield with a ramp, a 15° slope and rolling
//! bumps.
const std = @import("std");
const eggy = @import("eggy");

const math = eggy.math;
const physics = eggy.physics;
const EntityId = eggy.ecs.EntityId;
const World = eggy.ecs.World;

const grid_columns: u32 = 65;
const grid_rows: u32 = 65;
const grid_cell_m: f32 = 2.0;

const hitch_anchor_trailer = math.Vec3.init(0, -0.15, -3.8);
const hitch_anchor_truck = math.Vec3.init(0, -0.15, 2.85);
const ramp_raised_deg: f32 = 0;
const ramp_lowered_deg: f32 = 105;
const slider_retracted_m: f32 = 0;
const slider_extended_m: f32 = 1.5;

pub const Game = struct {
    truck: EntityId = undefined,
    trailer: EntityId = undefined,
    ramp: EntityId = undefined,
    slider: EntityId = undefined,
    camera: EntityId = undefined,

    camera_pos: math.Vec3 = .init(0, 5.5, 11),
    hitched: bool = true,
    trailer_static: bool = false,
    ramp_lowered: bool = false,
    slider_extended: bool = false,
    handbrake: bool = false,

    /// Spawn the terrain heightfield, lighting, truck, hitched trailer, ramp, slider deck and chase
    /// camera.
    pub fn init(gpa: std.mem.Allocator, app: *eggy.App) !Game {
        // 120 Hz physics for stable vehicle suspension, tyres and joints.
        _ = try app.world.spawn(.{
            eggy.Name.init("Scene"),
            eggy.SceneRoot{ .dimension = .three },
            physics.PhysicsSettings{ .steps_per_second = 120 },
        });

        // Sun light and ambient environment.
        _ = try app.world.spawn(.{
            eggy.Name.init("Environment"),
            eggy.lighting.Environment{ .ambient_intensity = 0.08, .default_light = false },
        });
        _ = try app.world.spawn(.{
            eggy.Name.init("Sun"),
            eggy.Transform{ .rotation_deg = .init(-42, 32, 0) },
            eggy.SceneLight{ .kind = .directional, .color = .{ 1.0, 0.97, 0.9 }, .illuminance_lux = 1500, .casts_shadows = true },
        });

        try spawnTerrain(gpa, app);

        const truck = try spawnTruck(&app.world);
        const trailer = try spawnTrailer(&app.world, truck);
        const ramp = try spawnRamp(&app.world, trailer);
        const slider = try spawnSlider(&app.world, trailer);
        const camera = try app.world.spawn(.{
            eggy.Name.init("Chase Camera"),
            eggy.Camera{ .fov_deg = 60, .far = 400 },
            eggy.Transform{ .position = .init(0, 5.5, 11), .rotation_deg = .init(-16, 0, 0) },
        });

        return .{
            .truck = truck,
            .trailer = trailer,
            .ramp = ramp,
            .slider = slider,
            .camera = camera,
        };
    }

    /// Read driving and mechanism controls, and smoothly follow the truck with the chase camera.
    pub fn update(self: *Game, app: *eggy.App) !void {
        const input = &app.input;

        if (input.pressed(.r)) {
            self.ramp_lowered = !self.ramp_lowered;
            self.applyRampMotor(&app.world);
        }
        if (input.pressed(.e)) {
            self.slider_extended = !self.slider_extended;
            self.applySliderMotor(&app.world);
        }
        if (input.pressed(.h)) {
            self.hitched = !self.hitched;
            try self.applyHitch(&app.world);
        }
        if (input.pressed(.p)) {
            self.trailer_static = !self.trailer_static;
            if (app.world.get(self.trailer, physics.RigidBody)) |body| {
                body.kind = if (self.trailer_static) .static else .dynamic;
            }
        }
        if (input.pressed(.f)) {
            app.physics_debug.vehicles = !app.physics_debug.vehicles;
        }
        if (input.pressed(.b)) {
            self.handbrake = !self.handbrake;
        }

        const brake_val: f32 = if (input.held(.left_shift) or input.held(.right_shift)) 1 else 0;
        const handbrake_on = self.handbrake or input.held(.space);

        if (app.world.get(self.truck, physics.VehicleInput)) |drive| {
            drive.throttle = input.axis(.s, .w);
            drive.steer = input.axis(.a, .d);
            drive.brake = brake_val;
            drive.handbrake = handbrake_on;
        }
        if (app.world.get(self.trailer, physics.VehicleInput)) |trailer_drive| {
            trailer_drive.throttle = 0;
            trailer_drive.steer = 0;
            trailer_drive.brake = brake_val;
            trailer_drive.handbrake = handbrake_on;
        }

        self.updateCamera(&app.world, app.time.delta_s);
    }

    /// Minimal HUD showing vehicle telemetry and sandbox controls.
    pub fn gameUi(self: *Game, app: *eggy.App, ui: *eggy.ui.Context) !void {
        ui.theme = .dark;
        const speed_mps = if (app.world.get(self.truck, physics.VehicleState)) |s| s.speed_mps else 0;
        const speed_kmh = speed_mps * 3.6;
        const hitch_force_n = if (app.world.get(self.trailer, physics.JointState)) |s| s.force_n else 0;

        ui.label("Speed: {d:.1} m/s ({d:.0} km/h)", .{ speed_mps, speed_kmh });
        ui.label("Handbrake: {s} | Hitch: {s} ({d:.0} N)", .{
            if (self.handbrake) "on" else "off",
            if (self.hitched) "coupled" else "unhitched",
            hitch_force_n,
        });
        ui.label("Trailer: {s} | Ramp: {s} | Slider: {s}", .{
            if (self.trailer_static) "static" else "dynamic",
            if (self.ramp_lowered) "lowered" else "raised",
            if (self.slider_extended) "extended" else "retracted",
        });
        ui.muted("WASD drive | Shift brake | Space/B handbrake | R ramp | E slider | H hitch | P trailer static | F debug");
    }

    fn applyRampMotor(self: *Game, world: *World) void {
        const joint = world.get(self.ramp, physics.Joint) orelse return;
        joint.kind.hinge.motor = .{ .position = .{
            .target = if (self.ramp_lowered) ramp_lowered_deg else ramp_raised_deg,
            .speed = 65,
            .max = 8000,
        } };
    }

    fn applySliderMotor(self: *Game, world: *World) void {
        const joint = world.get(self.slider, physics.Joint) orelse return;
        joint.kind.slider.motor = .{ .position = .{
            .target = if (self.slider_extended) slider_extended_m else slider_retracted_m,
            .speed = 1.2,
            .max = 6000,
        } };
    }

    fn applyHitch(self: *Game, world: *World) !void {
        if (self.hitched) {
            try world.addComponent(self.trailer, trailerHitchJoint(self.truck));
        } else {
            try world.removeComponent(self.trailer, physics.Joint);
        }
    }

    fn updateCamera(self: *Game, world: *World, dt_s: f32) void {
        const truck_tf = world.get(self.truck, eggy.Transform) orelse return;
        const cam_tf = world.get(self.camera, eggy.Transform) orelse return;

        // Truck faces -Z, so +Z in truck space is behind the vehicle.
        const orient = truck_tf.orientation();
        var back = orient.rotateVector(math.Vec3.init(0, 0, 1));
        back.y = 0;
        const back_len = back.length();
        back = if (back_len > 1e-4) back.scale(1.0 / back_len) else math.Vec3.init(0, 0, 1);

        const desired = truck_tf.position.add(back.scale(11.5)).add(math.Vec3.init(0, 4.8, 0));
        const alpha = 1.0 - @exp(-5.5 * dt_s);
        self.camera_pos = self.camera_pos.lerp(desired, alpha);

        const look_target = truck_tf.position.add(math.Vec3.init(0, 1.2, 0));
        const to_target = look_target.sub(self.camera_pos);
        const horiz = @sqrt(to_target.x * to_target.x + to_target.z * to_target.z);
        const yaw_rad = std.math.atan2(-to_target.x, -to_target.z);
        const pitch_rad = std.math.atan2(to_target.y, @max(horiz, 1e-4));

        cam_tf.position = self.camera_pos;
        cam_tf.rotation_deg = math.Vec3.init(
            pitch_rad * (180.0 / std.math.pi),
            yaw_rad * (180.0 / std.math.pi),
            0,
        );
        world.markChanged(self.camera, eggy.Transform);
    }
};

/// Build a 128 m × 128 m heightfield with a flat spawn pad, a ramp ahead (-Z), a 15° parking slope
/// (+X) and rolling bumps (-X).
fn spawnTerrain(gpa: std.mem.Allocator, app: *eggy.App) !void {
    const total = @as(usize, grid_columns) * @as(usize, grid_rows);
    const heights = try gpa.alloc(f32, total);
    defer gpa.free(heights);

    const half_x = @as(f32, @floatFromInt(grid_columns - 1)) * grid_cell_m * 0.5;
    const half_z = @as(f32, @floatFromInt(grid_rows - 1)) * grid_cell_m * 0.5;

    for (0..grid_rows) |row| {
        for (0..grid_columns) |col| {
            const x = @as(f32, @floatFromInt(col)) * grid_cell_m - half_x;
            const z = @as(f32, @floatFromInt(row)) * grid_cell_m - half_z;
            heights[row * grid_columns + col] = terrainHeight(x, z);
        }
    }

    try app.heightfields().set("sandbox_ground", heights, grid_columns, grid_cell_m);
    _ = try app.world.spawn(.{
        eggy.Name.init("Terrain"),
        eggy.Transform{ .position = .init(-half_x, 0, -half_z) },
        eggy.Terrain{ .heights = .init("sandbox_ground") },
        physics.Collider{ .shape = .{ .heightfield = .init("sandbox_ground") } },
    });
}

fn terrainHeight(x: f32, z: f32) f32 {
    var h: f32 = 0;

    // Ramp ahead along -Z: rises smoothly from z = -16 to -30, flat top to -36, descends to -44.
    const ramp_lat = 1.0 - smoothstep(5.0, 8.0, @abs(x));
    if (ramp_lat > 0 and z < -16 and z > -44) {
        const up = smoothstep(-16.0, -30.0, z);
        const down = 1.0 - smoothstep(-36.0, -44.0, z);
        h = @max(h, 3.2 * up * down * ramp_lat);
    }

    // 15° test slope on +X (tan 15° ≈ 0.268): rises over x = 16..36, plateau 36..44, drops 44..52.
    const slope_lat = 1.0 - smoothstep(10.0, 14.0, @abs(z));
    if (slope_lat > 0 and x > 16 and x < 52) {
        const rise = std.math.clamp((x - 16.0) / 20.0, 0.0, 1.0);
        const drop = 1.0 - smoothstep(44.0, 52.0, x);
        h = @max(h, 5.36 * rise * drop * slope_lat);
    }

    // Rolling bumps on -X to exercise suspension and hitched towing.
    const bump_mask = smoothstep(-14.0, -18.0, x) * (1.0 - smoothstep(-46.0, -52.0, x)) * (1.0 - smoothstep(20.0, 26.0, @abs(z)));
    if (bump_mask > 0) {
        h += bump_mask * (0.45 * @sin(z * 0.42) * @cos(x * 0.22) + 0.45);
    }

    return h;
}

fn smoothstep(edge0: f32, edge1: f32, value: f32) f32 {
    const t = std.math.clamp((value - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn spawnTruck(world: *World) !EntityId {
    const truck = try world.spawn(.{
        eggy.Name.init("Truck"),
        eggy.Transform{ .position = .init(0, 1.15, 0) },
        eggy.Mesh{
            .shape = .cube,
            .color = .{ 0.78, 0.24, 0.16 },
            .local_transform = .{ .scale = .init(2.1, 0.7, 5.0) },
        },
        physics.RigidBody{ .mass_kg = 3000, .center_of_mass_m = .init(0, -0.35, 0) },
        physics.Collider{ .shape = .{ .cuboid = .{ .half_extents_m = .init(1.05, 0.35, 2.5) } } },
        physics.Vehicle{},
        physics.VehicleInput{},
        physics.VehicleState{},
    });

    // Cab as a child collider on the same compound body.
    const cab = try world.spawn(.{
        eggy.Name.init("Truck Cab"),
        eggy.Transform{ .position = .init(0, 0.75, -0.95) },
        eggy.Mesh{
            .shape = .cube,
            .color = .{ 0.86, 0.32, 0.2 },
            .local_transform = .{ .scale = .init(1.9, 0.9, 1.9) },
        },
        physics.Collider{ .shape = .{ .cuboid = .{ .half_extents_m = .init(0.95, 0.45, 0.95) } }, .mass_kg = 250 },
    });
    try world.setParent(cab, truck);

    const WheelSpec = struct { name: []const u8, pos: math.Vec3, steers: bool, driven: bool, handbrake: bool, axle: u8, anti_roll: f32 };
    const specs = [_]WheelSpec{
        .{ .name = "Wheel FL", .pos = .init(-1.05, -0.2, -1.65), .steers = true, .driven = true, .handbrake = false, .axle = 0, .anti_roll = 12000 },
        .{ .name = "Wheel FR", .pos = .init(1.05, -0.2, -1.65), .steers = true, .driven = true, .handbrake = false, .axle = 0, .anti_roll = 12000 },
        .{ .name = "Wheel RL", .pos = .init(-1.05, -0.2, 1.65), .steers = false, .driven = true, .handbrake = true, .axle = 1, .anti_roll = 14000 },
        .{ .name = "Wheel RR", .pos = .init(1.05, -0.2, 1.65), .steers = false, .driven = true, .handbrake = true, .axle = 1, .anti_roll = 14000 },
    };
    for (specs) |spec| {
        try spawnWheel(world, truck, spec.name, spec.pos, .{
            .steers = spec.steers,
            .driven = spec.driven,
            .brakes = true,
            .handbrake = spec.handbrake,
            .axle = spec.axle,
            .anti_roll_n_per_m = spec.anti_roll,
        });
    }

    return truck;
}

fn trailerHitchJoint(truck: EntityId) physics.Joint {
    return .{
        .other = .init(truck),
        .kind = .{ .ball = .{ .axis = .init(0, 0, 1), .cone_limit_deg = 70 } },
        .anchor_m = hitch_anchor_trailer,
        .other_anchor_m = hitch_anchor_truck,
    };
}

fn spawnTrailer(world: *World, truck: EntityId) !EntityId {
    const trailer = try world.spawn(.{
        eggy.Name.init("Trailer"),
        eggy.Transform{ .position = .init(0, 1.15, 6.65) },
        eggy.Mesh{
            .shape = .cube,
            .color = .{ 0.36, 0.42, 0.48 },
            .local_transform = .{ .scale = .init(2.1, 0.5, 5.0) },
        },
        physics.RigidBody{ .mass_kg = 1500, .center_of_mass_m = .init(0, -0.25, 0) },
        physics.Collider{ .shape = .{ .cuboid = .{ .half_extents_m = .init(1.05, 0.25, 2.5) } } },
        physics.Vehicle{ .engine_force_n = 0, .brake_force_n = 15000, .handbrake_force_n = 20000 },
        physics.VehicleInput{},
        physics.VehicleState{},
        trailerHitchJoint(truck),
        physics.JointState{},
    });

    // Drawbar tongue reaching forward to the truck's hitch ball.
    const tongue = try world.spawn(.{
        eggy.Name.init("Trailer Tongue"),
        eggy.Transform{ .position = .init(0, -0.15, -3.15) },
        eggy.Mesh{
            .shape = .cube,
            .color = .{ 0.24, 0.26, 0.28 },
            .local_transform = .{ .scale = .init(0.24, 0.16, 1.3) },
        },
        physics.Collider{ .shape = .{ .cuboid = .{ .half_extents_m = .init(0.12, 0.08, 0.65) } }, .mass_kg = 60 },
    });
    try world.setParent(tongue, trailer);

    // A cargo machine mounted on the trailer deck, adding its mass to the compound body.
    const cargo = try world.spawn(.{
        eggy.Name.init("Deck Machine"),
        eggy.Transform{ .position = .init(0, 0.65, -0.5) },
        eggy.Mesh{
            .shape = .cube,
            .color = .{ 0.22, 0.52, 0.72 },
            .local_transform = .{ .scale = .init(1.1, 0.8, 1.4) },
        },
        physics.Collider{ .shape = .{ .cuboid = .{ .half_extents_m = .init(0.55, 0.4, 0.7) } }, .mass_kg = 350 },
    });
    try world.setParent(cargo, trailer);

    for ([_]struct { name: []const u8, x: f32 }{
        .{ .name = "Trailer Wheel L", .x = -1.05 },
        .{ .name = "Trailer Wheel R", .x = 1.05 },
    }) |side| {
        try spawnWheel(world, trailer, side.name, .init(side.x, -0.2, 0.35), .{
            .stiffness_n_per_m = 45000,
            .damping_compression = 3500,
            .damping_rebound = 5000,
            .steers = false,
            .driven = false,
            .brakes = true,
            .handbrake = true,
            .axle = 0,
            .anti_roll_n_per_m = 10000,
        });
    }

    return trailer;
}

fn spawnRamp(world: *World, trailer: EntityId) !EntityId {
    return world.spawn(.{
        eggy.Name.init("Rear Ramp"),
        eggy.Transform{ .position = .init(0, 1.9, 9.27) },
        eggy.Mesh{
            .shape = .cube,
            .color = .{ 0.85, 0.62, 0.16 },
            .local_transform = .{ .scale = .init(2.0, 1.5, 0.14) },
        },
        physics.RigidBody{ .mass_kg = 100 },
        physics.Collider{ .shape = .{ .cuboid = .{ .half_extents_m = .init(1.0, 0.75, 0.07) } } },
        physics.Joint{
            .other = .init(trailer),
            // -X axis makes positive angles swing the ramp down toward +Z.
            .kind = .{ .hinge = .{
                .axis = .init(-1, 0, 0),
                .limits_deg = .{ .lower = -5, .upper = 115 },
                .motor = .{ .position = .{ .target = ramp_raised_deg, .speed = 65, .max = 8000 } },
            } },
            .anchor_m = .init(0, -0.75, -0.07),
            .other_anchor_m = .init(0, 0, 2.55),
        },
        physics.JointState{},
    });
}

fn spawnSlider(world: *World, trailer: EntityId) !EntityId {
    return world.spawn(.{
        eggy.Name.init("Slider Deck"),
        eggy.Transform{ .position = .init(0.55, 1.46, 7.6) },
        eggy.Mesh{
            .shape = .cube,
            .color = .{ 0.28, 0.66, 0.36 },
            .local_transform = .{ .scale = .init(1.2, 0.12, 2.0) },
        },
        physics.RigidBody{ .mass_kg = 120 },
        physics.Collider{ .shape = .{ .cuboid = .{ .half_extents_m = .init(0.6, 0.06, 1.0) } } },
        physics.Joint{
            .other = .init(trailer),
            // -X axis makes positive offsets extend the deck outward along +X.
            .kind = .{ .slider = .{
                .axis = .init(-1, 0, 0),
                .limits_m = .{ .lower = 0, .upper = 1.6 },
                .motor = .{ .position = .{ .target = slider_retracted_m, .speed = 1.2, .max = 6000 } },
            } },
            .anchor_m = .zero,
            .other_anchor_m = .init(0.55, 0.31, 0.95),
        },
        physics.JointState{},
    });
}

fn spawnWheel(world: *World, chassis: EntityId, name: []const u8, mount: math.Vec3, wheel_cfg: physics.Wheel) !void {
    const visual = try world.spawn(.{
        eggy.Name.init(name),
        eggy.Transform{ .position = mount },
        eggy.Mesh{
            .shape = .cylinder,
            .color = .{ 0.14, 0.14, 0.16 },
            .local_transform = .{
                .rotation_deg = .init(0, 0, 90),
                .scale = .init(wheel_cfg.radius_m * 2.0, 0.36, wheel_cfg.radius_m * 2.0),
            },
        },
    });
    // Spoke bar so wheel spin is visible while driving.
    const spoke = try world.spawn(.{
        eggy.Name.init("Hub"),
        eggy.Transform{},
        eggy.Mesh{
            .shape = .cube,
            .color = .{ 0.72, 0.74, 0.78 },
            .local_transform = .{ .scale = .init(0.4, 0.14, wheel_cfg.radius_m * 1.4) },
        },
    });
    try world.setParent(spoke, visual);

    var cfg = wheel_cfg;
    cfg.visual = .init(visual);
    const wheel = try world.spawn(.{
        eggy.Name.init(name),
        eggy.Transform{ .position = mount },
        cfg,
        physics.WheelState{},
    });
    try world.setParent(wheel, chassis);
}
