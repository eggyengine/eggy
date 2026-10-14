---
slug: /
sidebar_position: 1
title: Introduction
---

# Eggy

Eggy is a game engine for Zig 0.16. Your game is a Zig package that depends on Eggy: Eggy builds it into two programs, a **runtime** that players run and an **editor** for working on it.

- **The runtime** opens a window, renders the scene and runs your game. It builds for desktop and the web.
- **The editor** runs the same game inside dockable panels: the scene, an inspector, and any panels your plugins add. It is desktop only.

Everything your game does goes through **plugins**. Your game is the first plugin, and other packages can add more. See the [Plugins guide](guides/plugins.md).

## Packages

An Eggy package follows Zig's layout:

| File | What it is | Built with |
| --- | --- | --- |
| `src/main.zig` | A game: `pub const Game` | `eggy.addGame` |
| `src/root.zig` | A plugin or library: `pub const Plugin` | `eggy.addPlugin` |

A package can have both, so the game uses its own plugin and other games can use it too.

## Building

From your package's directory:

| Command | What it does |
| --- | --- |
| `zig build run` | Build and open the editor. On the web, open the runtime in a browser. |
| `zig build run-runtime` | Build and run the runtime. |
| `zig build all` | Build both into `zig-out/bin/` without running them. |
| `zig build test` | Run your tests. |

The UI in the editor, and in your editor panels, is [Weeoui](https://eggyengine.github.io/weeoui/), an immediate-mode UI library for Zig.
