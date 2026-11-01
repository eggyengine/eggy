# eggy

_eggy_ is a game engine written in Zig. more info at [eggyengine.github.io](https://eggyengine.github.io). 

since the editor is compiled with the runtime, create a project with this script (which bootstraps everything):

```bash
curl -fsSL https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.sh | bash
```

or on windows:
```pwsh
irm https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.ps1 | iex
```

## make a game
requires zig `0.17.0`

The eggy engine uses the editor to initialise the project, so all of these steps are done automatically.

Documentation is also available at [eggyengine.github.io/eggy](https://eggyengine.github.io/eggy)

<!-- note: uncomment below if linux packaging errors occur in the future -->

<!-- ### linux packages
fatal errors pop up a native dialog through [nvdialog](https://github.com/tseli0s/nvdialog), which needs GTK3 and DBus headers. accessibility needs `libunwind`. on debian:

```bash
sudo apt install libgtk-3-dev libdbus-1-dev libunwind-dev
```

everything else (SDL3, nvdialog, AccessKit) is fetched and linked by `zig build`. windows builds ship `accesskit.dll` beside the executables. -->

## contributing to eggy
clone the repository, then run the editor as such:

```bash
git clone --recursive https://github.com/eggyengine/eggy
cd eggy
zig build run
```

despite being potentially controversial, agents are welcome to contribute however you cannot make **slop** commits. They must be reviewed as though I can ask you in person what the PR does without looking at the code. 

I personally use agents to help me work on this, and personally review through everything. 
