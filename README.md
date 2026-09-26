# eggy

Unrecoverable startup, frame, and event errors (and panics) show a native
nvdialog error dialog before Eggy exits. The error remains in stderr with its
trace; without a graphical session nvdialog cannot open a dialog, so stderr
remains the fallback. Linux builds require GTK3 and DBus development packages
(`libgtk-3-dev` and `libdbus-1-dev` on Debian). The nvdialog source is pinned
and linked during `zig build`; no separate nvdialog installation is needed.

Eggy's Weeoui demo publishes its laid-out controls, focus, labels, values,
and bounds through AccessKit (AT-SPI on Linux, UI Automation on Windows, and
macOS accessibility APIs). Screen-reader focus and activation use the same
app-owned control state as keyboard and mouse input. The pinned AccessKit C
release is linked statically on Linux/macOS; Windows builds install
`accesskit.dll` alongside `eggy.exe`. Linux also needs `libunwind`.
The release includes Linux x86/x86_64, Windows x86_64/arm64, and macOS
x86_64/arm64 libraries; Linux arm64 needs an upstream prebuilt release or a
separate source build before it can use this integration.

The desktop demo scrolls through an interactive native component gallery.
Tab and Shift+Tab move focus in opposite directions; Enter/Space activate
buttons, arrows adjust sliders and the panel divider, and editable fields
accept keyboard text. Click a control or activate it through AccessKit to
update the same application-owned state. Wheel input scrolls the pane under
the pointer before the main gallery; the file attachment opens SDL's native
file picker. The gallery includes text-alignment examples, bundled Lucide
SVG icons, and a rotating Vitellus 3D scene clipped to its viewport.
`zig build test` checks control state, focus, nested scrolling, semantic
snapshots, registered SDL event delivery, and 3D viewport geometry without
opening a desktop window.
