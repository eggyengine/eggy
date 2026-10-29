---
title: See how long you've worked on a project
---

The **Project Stats** plugin keeps track of the time you spend on your project. Install it
from **Edit > Plugins...**, under **Made by Eggy** (see [Install plugins](install-plugins.md)).
It's a dev plugin, so exported games leave it out. The time counts while you use the
editor, and stops when you switch to another window or leave it alone for five minutes.

The clock near the right of the status bar is this session's time, like a speedpaint's
timer. A hot reload, or opening the editor again within five minutes, carries on with the
same session. Click the clock for **Reset Session**, which starts it again from zero, and
**Show Project Stats**, which opens the panel.

The Project Stats panel shows:

- The project's total time, with a dot for each day of the last weeks. The bigger the
  dot, the longer the project was worked on that day, and today has a ring around it.
- Your own time and this session's, the days worked, the current and best streak
  of days in a row, the busiest day, and how long the sessions were.
- Everyone who has worked on the project and their share of the time, once
  more than one person has.
- Lines of Zig code, the project's files by kind with their sizes, and the
  entities in the open scene.
- How many times the scene was saved, the game played and the project built.

Each person's record is kept in its own file in `.eggy/work_time/`, named after their
user name on the computer. Commit these files with the project, and the stats add
everyone up. Since nobody writes to anyone else's file, commits from different people
never conflict there.
