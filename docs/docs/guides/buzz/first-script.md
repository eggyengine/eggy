---
sidebar_position: 1
title: Your first Buzz script
---

Eggy's dev console runs [Buzz](https://buzz-lang.dev), a small, statically typed scripting
language. In this tutorial you will try Buzz a line at a time, then write a script file that
adds a `slowmo` function to your game, run it, fix a mistake in it, and run it again.

## Before you begin

You need an Eggy project that opens in the editor. Buzz runs on desktop (Windows, macOS
and Linux); the web and Android builds run console commands only.

## 1. Open the console

Press **Play**, click into the game so it has the keyboard, then press <kbd>`</kbd>. A bar
opens along the bottom of the game with the prompt **Write your command**. Press
<kbd>`</kbd> again, or <kbd>Esc</kbd>, to close it.

The editor's **Console** panel has the same prompt under its messages, and both share one
session: what you declare in one, you can use in the other.

## 2. Try a few lines

Type each line and press <kbd>Enter</kbd>:

```buzz
print("hello")
```

```
hello
```

A line that ends in a value shows it:

```buzz
1 + 2
```

```
3
```

What a line declares stays for the lines after it:

```buzz
var speed = 3;
```

```buzz
speed * 2
```

```
6
```

Type `help` to list the console's commands. A line whose first word is a command runs that
command; anything else runs as Buzz. Press <kbd>Tab</kbd> to complete commands, entity
names and the names you have declared, and <kbd>Up</kbd> to bring back an earlier line.

## 3. Write a script file

Typing works for one-off lines. For anything longer, write a file. In your project's folder
(the one with `build.zig`), make a folder named `scripts` and save this as
`scripts/slowmo.buzz`:

```buzz
// Slow the game down, or speed it back up.
fun slowmo(scale: double) > void {
    if (run("timescale {scale}")) {
        print("Time now runs at {scale}x");
    } else {
        print("Couldn't change the time scale");
    }
}

print("slowmo is ready: try slowmo(0.25)");
```

A few things to notice:

- `fun` declares a function. Each parameter has a type, and `> void` says it returns nothing.
- `{scale}` inside a string puts the value of `scale` there.
- `run` runs a console command, here `timescale`, and returns whether it ran.

## 4. Run it

In the console, type `run scripts/` and press <kbd>Tab</kbd>: it completes to
`scripts/slowmo.buzz`. Press <kbd>Enter</kbd>:

```
slowmo is ready: try slowmo(0.25)
```

The script ran from top to bottom, and `slowmo` now exists for later lines. Call it:

```buzz
slowmo(0.25)
```

```
Time now runs at 0.25x
```

The game slows to a quarter of its speed. Put it back:

```buzz
slowmo(1)
```

```
Bad argument type: got type `int`, expected `double` (column 8)
```

Buzz never turns one type into another for you. `1` is an `int` and `slowmo` takes a
`double`, so write `1.0`:

```buzz
slowmo(1.0)
```

```
Time now runs at 1x
```

## 5. Change the script and run it again

Let `slowmo` take whole numbers too, by adding a second function to the file:

```buzz
// Slow the game down, or speed it back up.
fun slowmo(scale: double) > void {
    if (run("timescale {scale}")) {
        print("Time now runs at {scale}x");
    } else {
        print("Couldn't change the time scale");
    }
}

// Back to normal speed.
fun normal() > void {
    slowmo(1.0);
}

print("slowmo is ready: try slowmo(0.25), then normal()");
```

Save it and run it again with `run scripts/slowmo.buzz` (or <kbd>Up</kbd> to find the
line). Running a script again replaces everything it declared last time, so you can keep
editing and rerunning it while the game plays. Now `normal()` works.

## 6. Read an error

Make a mistake on purpose. Change the last line to:

```buzz
print(42);
```

and run the script again:

```
Bad argument type: got type `int`, expected `str` (scripts/slowmo.buzz:15:8)
```

An error names the file, the line and the column. A script that fails changes nothing: the
`slowmo` and `normal` from the last run that worked are still there. Put the line back the
way it was, or write `print("{42}")`, and run it again.

## What's next

- [The scripting API](./scripting-api.md) lists what a script can reach and how the console
  runs it.
- [Give scripts your own commands](./script-commands.md) shows how your game's Zig code adds
  commands that scripts, and players, can call.
- [Buzz's own documentation](https://buzz-lang.dev) covers the language: lists, maps,
  objects, enums, loops and more.
