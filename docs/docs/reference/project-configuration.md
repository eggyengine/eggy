---
sidebar_position: 2
title: Project configuration and files
---

# Project configuration and files

## Package layout

| File or directory | Purpose |
| --- | --- |
| `build.zig` | Build definition; `eggy.addGame` builds a game, `eggy.addPlugin` publishes a plugin |
| `build.zig.zon` | Zig package manifest and dependency pins |
| `src/main.zig` | Game entry declaring `pub const Game` |
| `src/root.zig` | Reusable plugin/library declaring `pub const Plugin` |
| `eggy.zon` | Eggy's project settings, beside the Zig manifest |
| `resources/` | Source assets; new scenes go in `resources/scene/` |
| `controls.zon` | Developer input overrides, versioned with the project and embedded in runtime builds |
| `.eggy/` | Project-specific editor state and preferences; `.eggy/assets.zon` is the asset catalog (IDs and model import settings), which belongs in version control |
| `zig-out/` | Installed build/export output |

A package can have both a game and a reusable plugin. Their `addGame` and `addPlugin`
calls must request Eggy with identical dependency arguments so they share one engine.
See [Create reusable plugins](../how-to/create-plugins.md#using-plugins).

## `eggy.zon`

```zig
.{
    .name = "my_game",
    .title = "My Game",
    .version = "0.1.0",
    .default_scene = "resources/scene/start.scene.zon",
    .metadata = .{
        .company = "Example Studio",
        .description = "A small game",
    },
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `name` | Required | Package/build name; executables are `<name>` and `<name>_editor` |
| `title` | Required | Player-visible title and editor window title |
| `version` | `"0.0.1"` | Game version stored in executable metadata |
| `default_scene` | `null` | Project-relative startup scene; exports require this or an explicit scene |
| `metadata` | Empty fields | Executable metadata below |
| `plugins` | Empty | Plugins installed from File > Plugins, which the game is built with |
| `plugin` | `null` | This folder's plugin, for others to install; see [Share the plugin](../how-to/create-plugins.md#share-the-plugin) |

File > Project Settings opens the Project section of Edit > Preferences and edits
this file, including the startup scene.

### Installed plugins

The Plugins window writes each plugin it installs as an entry of `.plugins`:

```zig
.plugins = .{
    .{ .module = "eggy_git", .version = "0.1.0", .dev = true },
    .{
        .module = "stats",
        .dependency = "stats",
        .version = "1.2.0",
        .source = "https://raw.githubusercontent.com/someone/stats/v1.2.0/eggy.zon",
        .repository = "https://github.com/someone/stats",
        .fingerprint = 0x1234abcd5678ef90,
    },
},
```

| Field | Meaning |
| --- | --- |
| `module` | The plugin's module, which `addGame` builds the game with |
| `dependency` | The `build.zig.zon` dependency publishing it; absent for plugins inside Eggy |
| `version` | The version installed |
| `dev` | Left out of exports (`zig build export`, or `-Ddev-plugins=false`) |
| `source` | Where its `eggy.zon` was read, to check for a newer version |
| `repository`, `fingerprint` | What an update must match |

`addGame` builds these after the plugins its `.plugins` and `.dev_plugins` options name.

### Executable metadata

| Field | Value |
| --- | --- |
| `company` | Studio/publisher text |
| `description` | Executable description |
| `copyright` | Copyright text |
| `extra` | Additional entries with `name` and `value` string fields |

Empty metadata is omitted. Windows builds put title, version, and metadata in executable
version information. Other builds keep Eggy's metadata in an executable section.

## Startup scene selection

| Priority | Ordinary runtime build | Export |
| --- | --- | --- |
| 1 | `-Dscene=<path>` | `-Dscene=<path>` or CLI `--scene` |
| 2 | `eggy.zon`'s `.default_scene` | `eggy.zon`'s `.default_scene` |
| 3 | Editor's last-open scene in `.eggy/scene.zon` | Fails if no scene is selected |
| 4 | First scene under `resources/` | No fallback |
| 5 | No startup scene | No fallback |

The CLI validates that its selected scene exists under `resources/` and leaves
`.default_scene` unchanged. The GUI export dialog saves its scene selection.
See [Build and distribute a game](../how-to/build-and-export.md).

## Editor project discovery

`--project <directory>` chooses a project explicitly. Without it, `<name>_editor`
searches above its executable, including the usual `zig-out/bin/` layout, for a matching
`eggy.zon` name plus `build.zig` and `build.zig.zon`. If that search fails, it checks
the launch directory and its parents.

`zig build run` launches from the project root, including with a custom install prefix.
A copied editor without a matching source project opens as a standalone editor.

## Preferences

Plugin `Preferences` structs accept defaulted bool, integer, float, or enum fields.
Read them with `app.preferences(Preferences)` or, in an editor hook,
`editor.app.preferences(Preferences)`. Reads in `update` follow edits immediately;
values cached during `init` apply at the next start.

| Layer | Scope |
| --- | --- |
| Struct field defaults | Every instance |
| Global editor preferences in Eggy's data folder | Editor settings for all projects, not plugin settings |
| Project `.eggy/` files | Overrides for this project |

| Project file | Contents |
| --- | --- |
| `.eggy/preferences.zon` | Editor settings overriding global values |
| `.eggy/plugins/<published-name>.zon` | Plugin settings; the game's key is `game` |
| `.eggy/plugins.zon` | Editor-written plugin inventory, enabled state, and preference declarations |
| `controls.zon` | Developer input-mapping overrides, written by hand; not player preferences |

Preference files are plain ZON, such as `.{ .volume = 0.5 }`, and may be edited and
committed. Values of the wrong field type are ignored and defaults apply. Published
module names identify plugins, independently of Zig type names. Disabled plugins do
not run, but their settings and component declarations remain known.

Runtime builds embed project plugin preferences and enabled state. Preferences are
configuration, not gameplay saves; `app.storage` is a separate unsupported contract
that returns `NotImplemented`.

See [Map player controls](../how-to/map-input.md) for input assets and overrides, and
[Create reusable plugins](../how-to/create-plugins.md#preferences) for a preference declaration.
