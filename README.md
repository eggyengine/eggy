# eggy

Unrecoverable startup, frame, and event errors (and panics) show a native
nvdialog error dialog before Eggy exits. The error remains in stderr with its
trace; without a graphical session nvdialog cannot open a dialog, so stderr
remains the fallback. Linux builds require GTK3 and DBus development packages
(`libgtk-3-dev` and `libdbus-1-dev` on Debian). The nvdialog source is pinned
and linked during `zig build`; no separate nvdialog installation is needed.
