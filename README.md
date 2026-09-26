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
buttons, arrows navigate radio groups, tabs, and open menus, and Escape closes
popups or the modal dialog. Text fields support pointer selection, Shift/Ctrl
navigation, clipboard shortcuts, undo/redo, UTF-8 input, and SDL IME preedit.
Double-click selects a word; triple-click selects a textarea line.
AccessKit can set field values and selections as well as activate controls.
Wheel input scrolls the pane under the pointer before the main gallery; the
file attachment opens SDL's native file picker. The gallery includes a
right-click menu, distinct popovers and hover cards, hover/focus tooltips,
dismissible toasts, month/time navigation, optionally lined tables, animated
loading feedback, an accessible message log with add/jump actions, an
SVG-backed image/icon example, and a rotating Vitellus
3D scene clipped to its viewport. Popups paint above the 3D pass and modal
focus and accessibility are isolated from the page beneath.
Workspace provides project creation/edit actions, Dashboard shows live
project totals and activity, and Settings edits the same preferences as
the main controls.

`zig build test` exercises the native AccessKit update and action path,
scroll-frame budgets, widget roles, focus and pointer routing, text editing,
overlay ordering, and viewport geometry without opening a desktop window.
shadcn/ui's classic registry components have no first-party behavior test
suite; they wrap Radix, Base UI, or React Aria. These Zig tests check
applicable keyboard/accessibility behavior and portable MessageScroller
geometry and follow/scroll intent semantics, not React hydration or browser-only tests.
