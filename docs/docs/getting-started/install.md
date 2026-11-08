---
title: Install Eggy and make a project
sidebar_position: 1
sidebar_label: Install Eggy
description: Install Zig and Eggy, check the toolchain, and make a project.
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

Eggy needs Zig 0.17. The install script sets up both.

## Install

<Tabs groupId="os">
<TabItem value="unix" label="Linux and macOS">

```sh
curl -fsSL https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.sh | bash
```

</TabItem>
<TabItem value="windows" label="Windows">

```powershell
irm https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.ps1 | iex
```

</TabItem>
</Tabs>

The script installs Zig 0.17 if it is missing, asking first, through
[zvm](https://www.zvm.app). It then asks whether you want the latest release or the nightly
build, and whether to install for you alone or for everyone on the computer.

| Installed for | Linux and macOS | Windows |
| --- | --- | --- |
| You | `~/.local/share/eggy/launcher`, with `eggy` in `~/.local/bin` | `%LOCALAPPDATA%\Programs\Eggy` |
| Everyone | `/opt/eggy`, with `eggy` in `/usr/local/bin` (uses `sudo`) | `%ProgramFiles%\Eggy`, from an administrator PowerShell |

On Linux Eggy joins the applications menu; on Windows its `bin` folder joins `PATH` and Eggy
joins the Start menu. Run the script again to update. If you use zvm, keep its `bin` folder
first on `PATH`.

## Make a project

Open Eggy. The launcher lists the projects you opened lately, newest first, with the Eggy
each one builds against. Press **New Project**, give it a title, a package name (lower case,
digits and `_`) and an empty folder. Eggy writes the project from its template and builds
the project's own editor, which opens when it's done.

**Open Project...** opens an existing folder with an `eggy.zon` in it.

From a terminal, the same thing (the command is `eggy` on Linux and macOS, `eggy_editor` on
Windows):

```sh
eggy new
eggy new --title "Space Game" --name space_game --directory ./space_game --non-interactive
```

The first asks for each answer; the second gives them all. It finishes in the terminal
unless you add `--open`. In the project folder, `zig build run` opens the project's editor.

## Check the toolchain

If a build fails before your code runs, ask the doctor:

```sh
eggy doctor --project .
```

It checks the Zig version on `PATH`, its standard library, a real compile, cache write access
and the project's dependencies, and offers repairs, such as `zvm install` for the right Zig.
Read each before approving it. Doctor never installs zvm, OS SDKs, graphics drivers or
language servers. Its options are in the [command-line reference](../reference/editor-cli.md#check-the-toolchain).

## Next

Make [your first game](first-game.md) in the editor, or [a game in code only](code-only-game.md).
[Project files](../reference/project-configuration.md) lists what the template wrote.
