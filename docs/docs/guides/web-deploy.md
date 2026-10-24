---
title: Put your game on the web
---

An Eggy game runs in the browser through WebGPU. Browsers only offer WebGPU to **secure
pages**: ones served over `https://`, or from `localhost` on your own computer. A page opened
from disk, or over plain `http://` from any other address, can't draw, and the game says so
instead of starting.

## Export

Choose **Web** in **File > Export**, or run:

```sh
zig build export -Dtarget=wasm32-emscripten
```

The first web export sets up its tools by itself. You get
`zig-out/export/<name>-wasm32-emscripten-musl.zip`, and the same files unzipped beside it in
a `web/` folder:

| File | What it is |
| --- | --- |
| `<name>.html` | The page: the game across the whole window, with a progress bar while it loads |
| `<name>.js`, `<name>.wasm` | The game |
| `<name>.data` | Its scenes, models, textures and other resources |

Keep all four together in one folder.

## Try it on your computer

Serve the folder from `localhost`, which browsers treat as secure:

```sh
cd zig-out/export/<name>-wasm32-emscripten-musl/web
python3 -m http.server 8000
```

Then open `http://localhost:8000/<name>.html`. Use `localhost` itself: the same server
reached through your computer's network address (`http://192.168.…`) is not secure, and
WebGPU stays off.

## Try it on a phone or another computer

Other devices reach your computer through its network address, so they need `https://`.
The quickest way is a tunnel, which gives the server running above a temporary public
`https://` address. With [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/)
installed:

```sh
cloudflared tunnel --url http://localhost:8000
```

It prints an address ending in `trycloudflare.com`; open it with `/<name>.html` added on the
other device. Anyone with the address can load the game while the tunnel runs, so stop it
(Ctrl+C) when you're done.

## Publish it

Any host that serves static files over HTTPS works, and most do by default: GitHub Pages,
Netlify, Cloudflare Pages, itch.io, or your own web server with a certificate.

- Upload the four files together, as they are.
- Many hosts open `index.html` when someone visits the folder, and itch.io requires it.
  Rename `<name>.html` to `index.html`; the other files keep their names.
- On itch.io, make an HTML project and upload the zip with `index.html` inside it.

## Which browsers

The player's browser needs WebGPU. Recent Chrome and Edge have it on Windows, macOS,
ChromeOS and Android. Other browsers and Linux are catching up and may need it turned on
in their settings. See [feature support](../reference/feature-support.md#capability-support).

## When it doesn't start

The page shows what stopped the game over it:

- **"WebGPU needs a secure page"**: it was served over plain `http://` from an address
  other than `localhost`. Serve it over `https://`, or open it through `localhost`.
- **"This browser doesn't support WebGPU"**: try another browser, or turn WebGPU on in this
  one.
- **Nothing loads, or the `.data` file fails**: the page was opened straight from disk.
  Serve the folder as above.

The browser's developer console (F12) shows the game's own log, as the Console does in the
editor.
