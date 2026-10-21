# Git

Use Git without leaving the editor. Open **Window > Git** to see what changed in your
project, stage and unstage files, write a commit message and commit. **Pull** and **Push**
talk to the branch's remote; a branch without one is pushed to `origin`.

The status bar shows the branch and how many files changed. Click it to check again.

## Requirements

- `git` on your PATH.
- The project in a Git repository. If it isn't one, the Git panel offers to create it.

Git can't ask for a password from the editor. If a push or pull needs one, set up an SSH key
or a credential helper first.

## Dev plugin

Git only runs in the editor: exported games leave it out.
