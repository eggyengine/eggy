---
sidebar_position: 1
title: Set up a project
---

# Set up a project

Check the Zig toolchain, create a project from Eggy's template, and open its editor.
The same steps work through terminal prompts or supplied arguments.

## Before you start

Have an Eggy editor installation, including its resources, and a terminal in the parent
directory where you want the project. Eggy uses Zig 0.16. If you use zvm, put its `bin`
directory first on `PATH`.

The commands below use `eggy_editor`. Replace that with the path to your installed
executable when it is not on `PATH`.

## Steps

### Check Zig before creating a project

Run:

```sh
eggy_editor doctor
```

Doctor checks the supported Zig version, standard library, a compiler invocation, cache
write access, and project dependencies when a build file is present. Read each proposed
repair before approving it.

With zvm already installed, doctor can run `zvm install` and `zvm use` for the required
version. Selecting it changes the active zvm version. Doctor does not install zvm,
OS SDKs, drivers, or language servers.

To check without reading terminal input or approving repairs, use:

```sh
eggy_editor doctor --project . --fix=false --non-interactive
```

Dependency evaluation can still fetch missing required Zig packages. `--fix=false`
declines optional prefetch and toolchain changes.

### Create the project

For prompts, run:

```sh
eggy_editor new
```

Enter a title, package name, and directory. The name defaults to one derived from the
title; the directory defaults to that name. The destination must be absent or empty.

To supply all creation answers:

```sh
eggy_editor new --title "Space Game" --name space_game --directory ./space_game --non-interactive
```

Creation unpacks the bundled engine and template and builds the project's editor.
It finishes in the terminal unless you add `--open`.

The GUI alternative is to launch `eggy_editor` without arguments and choose
File > New Project. File > Open Project opens an existing project.

### Open the project's editor

From the generated project directory, run:

```sh
zig build run
```

The generated `<name>_editor` also opens its GUI without arguments.
`--project <directory>` chooses a source project explicitly; otherwise the editor
[discovers it](../reference/project-configuration.md#editor-project-discovery).

## Verify

Check that the editor's status bar names your project and that Assets shows its
`resources/` folder. From the project root, run `eggy_editor doctor --project .`
to include its build configuration and dependencies in the checks.

For a first game, follow the [scene-based tutorial](../tutorials/first-game.md) or
[code-only tutorial](../tutorials/code-only-games.md).

## Related reference

- [Editor CLI flags, defaults, and repair policy](../reference/editor-cli.md)
- [Project files and configuration](../reference/project-configuration.md)
