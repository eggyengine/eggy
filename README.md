# eggy

_eggy_ is a game engine written in Zig. it's built from a handful of in-house libraries, each living in its own repo:

- **[vitellus](https://github.com/eggyengine/vitellus)**: the rendering hardware interface (vulkan, dx12, webgpu)
- **[weeoui](https://github.com/eggyengine/weeoui)**: the immediate-mode UI, with docking panels and screen-reader support
- **[humpty](https://github.com/eggyengine/humpty)**: physics

they're pulled in as git submodules under `src/`.

## build
requires zig `0.16.0`

```bash
git clone --recursive https://github.com/eggyengine/eggy
cd eggy
zig build run
```

already cloned without `--recursive`? run `git submodule update --init --recursive` first.

| command | what it does |
|---|---|
| `zig build` | build the desktop executable into `zig-out/bin/` |
| `zig build run` | build and launch it |
| `zig build test` | run the workspace tests |
| `zig build -Dtarget=wasm32-emscripten run` | build for the browser and open it (uses `$EMSDK`, or `-Demsdk=<path>`) |
| `zig build update-submodules` | pull the latest submodule branches; review and commit the new pointers |

### linux packages
fatal errors pop up a native dialog through [nvdialog](https://github.com/tseli0s/nvdialog), which needs GTK3 and DBus headers. accessibility needs `libunwind`. on debian:

```bash
sudo apt install libgtk-3-dev libdbus-1-dev libunwind-dev
```

everything else (SDL3, nvdialog, AccessKit) is fetched and linked by `zig build`. windows builds ship `accesskit.dll` beside `eggy.exe`.
