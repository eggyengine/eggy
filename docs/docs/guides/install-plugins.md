---
title: Install plugins from the editor
---

Plugins add features to your game or to the editor. **File > Plugins...** finds them,
shows their read-me, and installs them into your project. Nothing is installed until you
choose to.

## Find a plugin

The Plugins window has three pages:

- **Installed** lists the plugins this project installed from the window. Plugins your
  `build.zig` adds by hand aren't listed.
- **Made by Eggy** lists the plugins that ship with Eggy, such as **Git** (stage, commit,
  pull and push from the editor) and **Frame Stats** (frames per second in a corner of
  the game).
- **From an Address** fetches any plugin by its `eggy.zon`. Paste its address, or the
  GitHub page of its folder, or a folder on your computer, and press **Fetch**.

You can also drop a plugin's `eggy.zon` onto the editor: the Plugins window opens on that
plugin.

## Read it, then install it

Choosing a plugin opens its page: its version, the repository it comes from, and its
read-me. A plugin without a read-me says "No README.md was provided." Press **Back** to
return without installing anything.

Press **Install** to add it. The editor fetches the plugin's package, checks it, saves it
into your `build.zig.zon`, lists it in your `eggy.zon`, then rebuilds the game with it.
Edit > Undo takes the install back.

When a page shows a newer version of a plugin you have, its button reads **Update to
1.2.0**. **Uninstall** removes a plugin from the game.

## Why an install can be refused

An Eggy plugin names the repository it is hosted in and its package's fingerprint (the
`.fingerprint` in its `build.zig.zon`). The editor installs it only when:

- the `eggy.zon` was read from inside that repository, so a copy hosted elsewhere can't
  pose as it;
- the package it fetched has that fingerprint, so a different package can't stand in for
  it;
- an update names the same repository and fingerprint as the version you installed.

Once installed, Zig pins the package's exact contents in `build.zig.zon`, so a later
change upstream can't slip into your build. These checks prove a plugin is the one its
repository publishes, not that the code is safe: read what a plugin does before you
install it.

## Dev plugins

Some plugins help you make the game rather than being part of it. Git is one. A plugin
marked **Dev plugin** runs in the editor and in `zig build run-runtime`, but File > Export
and `zig build export` leave it out of the game you ship.

To make and publish your own, see [Create reusable plugins](../how-to/create-plugins.md#share-the-plugin).
