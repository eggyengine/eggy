//! The C-callable boundary between the editor and a game's library: what each gives the other.
//! `library.zig` is the library's side, `hot_reload.zig` the editor's. Eggy's own types cross it
//! as pointers; both sides compile them from the same source with the same options, so they agree
//! on their layout. Errors don't cross (Zig numbers them per compilation): the library logs its
//! own and reports failure.
const std = @import("std");
const eggy = @import("eggy");

/// Bumped whenever these types change, so an editor refuses a library built for another.
pub const version: u32 = 28;

/// The library's one exported function: `fn () callconv(.c) *const Game`.
pub const entry_symbol = "eggy_game";
pub const Entry = *const fn () callconv(.c) *const Game;

/// What the editor gives the library.
pub const Host = extern struct {
    /// Log a line through the editor (its Console). `level` is a `std.log.Level`.
    log: *const fn (level: u8, scope_ptr: [*]const u8, scope_len: usize, text_ptr: [*]const u8, text_len: usize) callconv(.c) void,
};

/// A panel the game or a plugin adds to the editor's dock (`eggy.plugins.EditorPanel`).
pub const Panel = extern struct {
    key: [*:0]const u8,
    title: [*:0]const u8,
};
pub const Command = extern struct { key: [*:0]const u8, title: [*:0]const u8 };
pub const FileType = extern struct {
    key: [*:0]const u8,
    title: [*:0]const u8,
    extension: [*:0]const u8,
    contents: [*]const u8,
    contents_len: usize,
};

/// A field of a plugin's preferences (`eggy.preferences.Field`).
pub const PreferenceField = extern struct {
    name: [*:0]const u8,
    /// An `eggy.preferences.Kind`.
    kind: u8,
    default: [*:0]const u8,
    options: [*]const [*:0]const u8,
    option_count: usize,
    description: [*:0]const u8,
};

/// A plugin's preferences (`eggy.preferences.Manifest`).
pub const Preferences = extern struct {
    key: [*:0]const u8,
    fields: [*]const PreferenceField,
    field_count: usize,
};

/// A field of a component type (`eggy.components.Field`).
pub const ComponentField = extern struct {
    name: [*:0]const u8,
    /// An `eggy.components.Kind`.
    kind: u8,
    options: [*]const [*:0]const u8,
    option_count: usize,
    editable: bool,
    /// An entity reference's required component (its short name; empty for any).
    requires: [*:0]const u8,
    /// An asset reference's kind of file (an `eggy.refs.AssetKind`).
    accepts: u8,
    /// Its type part by part (`eggy.components.Field.parts`).
    parts: [*]const eggy.components.Part,
    part_count: usize,
};

/// A component type the game or a plugin lists (`eggy.components.Info`).
pub const ComponentType = extern struct {
    name: [*:0]const u8,
    owner: [*:0]const u8,
    fields: [*]const ComponentField,
    field_count: usize,
    addable: bool,
    /// The components it depends on, as indices among these types.
    dependencies: [*]const usize,
    dependency_count: usize,
};

/// An entity of the app's world (`eggy.ecs.EntityId`).
pub const Entity = extern struct { id: u32, generation: u32 };

/// Caller-owned field text and stable failures; Zig error numbers never cross the boundary.
pub const FieldBytes = extern struct { ptr: [*]u8, len: usize };
pub const FieldStatus = enum(u32) { ok, no_component, no_such_component, out_of_memory };

/// What the library gives the editor: the game's and its plugins' hooks (see `eggy.plugins`).
/// `state` is what `start` returned.
pub const Game = extern struct {
    version: u32 = version,
    /// Start the game and the plugins `enabled` has on (one per `plugin_keys`) on `app` (an
    /// `*eggy.App`), allocating with `gpa` (an `*const std.mem.Allocator`) and logging through
    /// `host`, then run the world's Init stages; null when a plugin failed to start.
    start: *const fn (host: *const Host, gpa: *const anyopaque, app: *anyopaque, enabled: [*]const bool) callconv(.c) ?*anyopaque,
    /// The game's and each plugin's key, the game first (see `eggy.plugins.Set`).
    plugin_keys: [*]const [*:0]const u8,
    plugin_count: usize,
    /// Stop them all and free `state`.
    stop: *const fn (state: *anyopaque) callconv(.c) void,
    /// One frame: the plugins' `update`, then the world's Update stages. False when something
    /// failed this frame (logged, once until it changes); the game carries on regardless.
    update: *const fn (state: *anyopaque, app: *anyopaque) callconv(.c) bool,
    has_game_ui: *const fn (state: *anyopaque) callconv(.c) bool,
    has_draw: *const fn (state: *anyopaque) callconv(.c) bool,
    game_ui: *const fn (state: *anyopaque, app: *anyopaque, context: *anyopaque) callconv(.c) bool,
    draw: *const fn (state: *anyopaque, app: *anyopaque, context: *const anyopaque) callconv(.c) bool,
    /// 0 ignored, 1 consumed, -1 failed (logged; consume rather than leaking input).
    ui_event: *const fn (state: *anyopaque, app: *anyopaque, event: *const anyopaque) callconv(.c) i32,
    /// A borrowed `*eggy.editor.Context` while the game isn't playing: `editorUpdate`, not the world's
    /// systems. False when it failed this frame (logged, once until it changes).
    editor_update: *const fn (state: *anyopaque, editor: *anyopaque) callconv(.c) bool,
    /// An `*const eggy.Event`; false when a hook failed (and logged why).
    event: *const fn (state: *anyopaque, app: *anyopaque, event: *const anyopaque) callconv(.c) bool,
    /// The Inspector's part: an `*eggy.ui.Context`.
    editor_ui: *const fn (state: *anyopaque, editor: *anyopaque, context: *anyopaque) callconv(.c) void,
    /// Panel `panel` of `panels`, into an `*eggy.ui.Context`.
    editor_panel_ui: *const fn (state: *anyopaque, panel: usize, editor: *anyopaque, context: *anyopaque) callconv(.c) void,
    panels: [*]const Panel,
    panel_count: usize,
    commands: [*]const Command,
    command_count: usize,
    file_types: [*]const FileType,
    file_type_count: usize,
    editor_command: *const fn (state: *anyopaque, command: usize, editor: *anyopaque) callconv(.c) void,
    /// Each plugin's preferences, for the Preferences window.
    preferences: [*]const Preferences,
    preference_count: usize,
    /// The component types the game and plugins list, for the Hierarchy and Inspector, and what
    /// the editor does with them on `world` (an `*eggy.ecs.World`); `component` indexes them.
    components: [*]const ComponentType,
    component_count: usize,
    has_component: *const fn (world: *anyopaque, entity: Entity, component: usize) callconv(.c) bool,
    /// Add it with its defaults; false if it can't be (logged).
    add_component: *const fn (world: *anyopaque, entity: Entity, component: usize) callconv(.c) bool,
    remove_component: *const fn (world: *anyopaque, entity: Entity, component: usize) callconv(.c) void,
    /// Write a field's value as ZON into `buffer`; returns its length, more than `capacity`
    /// when it didn't fit (and was cut off), or 0 if it couldn't be read.
    read_field: *const fn (world: *anyopaque, entity: Entity, component: usize, field: usize, buffer: [*]u8, capacity: usize) callconv(.c) usize,
    /// Allocate complete field ZON with the caller's `*const std.mem.Allocator`.
    read_field_alloc: *const fn (world: *anyopaque, allocator: *const anyopaque, entity: Entity, component: usize, field: usize, out: *FieldBytes) callconv(.c) FieldStatus,
    /// Set a field from ZON `text`; false if it doesn't parse as the field's type.
    write_field: *const fn (world: *anyopaque, entity: Entity, component: usize, field: usize, text: [*:0]const u8) callconv(.c) bool,
    /// The entity's `eggy.Name` into `buffer`, returning its length; null without one.
    read_name: *const fn (world: *anyopaque, entity: Entity, buffer: [*]u8, capacity: usize) callconv(.c) isize,
    /// Give the entity `eggy.Name` `text` (`len` bytes), or take its name away when empty.
    write_name: *const fn (world: *anyopaque, entity: Entity, text: [*]const u8, len: usize) callconv(.c) void,
    /// The meshes to draw (`eggy.mesh.gather`) into `out` (`eggy.mesh.Drawable`s); returns how
    /// many, at most `capacity`.
    gather_meshes: *const fn (world: *anyopaque, out: [*]eggy.mesh.Drawable, capacity: usize) callconv(.c) usize,
    /// Gather authored lights using library-local component types; false on a logged error.
    gather_lights: *const fn (world: *anyopaque, out: *eggy.lighting.Frame) callconv(.c) bool,
    /// The entity's transform within the world (`eggy.transform.worldMatrix`), as columns, into
    /// `out`; false if it isn't alive.
    world_matrix: *const fn (world: *anyopaque, entity: Entity, out: *[4][4]f32) callconv(.c) bool,
    /// The view through the game's camera (`eggy.camera.find`) into `out`; false without one.
    find_camera: *const fn (world: *anyopaque, out: *eggy.camera.View) callconv(.c) bool,
};
