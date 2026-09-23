---
name: git-fuse-atomic-commits
description: Split uncommitted changes in a Git repository into many small atomic commits, using git-fuse to stage partial changes by editing a mounted view of the Git index. Use when asked to create atomic commits, split up a diff, or commit work-in-progress changes as a clean series of commits.
---

Review the whole diff (`git status`, `git diff`, `git diff --cached`) and split it into many atomic commits.

One commit should contain at most one change (one refactoring, one behavior change). Split it as much as you can (as atomic as possible).

## The mounted index

To help you do this, `$GIT_DIR/mounted/index` is a writable view of the Git index, which you can use to stage files.
(Note: `$GIT_DIR` is usually `.git`; if you are in a worktree, resolve it with `$(git rev-parse --git-dir)`.)

The mounted index is a fully featured mounted filesystem view with real-time synchronization:
- Rename a file to do the equivalent of `git mv`
- Edit files directly to modify only the index without touching the working copy
- This avoids conflicts and lets you stage partial changes cleanly
- Changes made here affect only the staging area, not your working directory

It's a two-way real-time view:
- `git add`, `git rm --cached`, etc. are immediately reflected in the mounted index.
- Edits to files in `$GIT_DIR/mounted/index` immediately update the Git index, making them instantly visible in `git diff --cached` and applicable to `git commit`.

For partial staging (like `git add -p`), just edit the file in `$GIT_DIR/mounted/index` to contain exactly what you want staged.
- For example, if you want to stage only a hunk that adds a function, edit the file in `$GIT_DIR/mounted/index` to add just that function.
- If you want to stage all changes in a file, you can `cp` it to `$GIT_DIR/mounted/index`, or just use `git add` as usual.
- Similarly, `rm` of a file in `$GIT_DIR/mounted/index` is synonymous with `git rm --cached`.
- If you staged too much, you can unstage by undoing the edit or running `git restore --staged`.

## Setup

If `$GIT_DIR/mounted/index` is empty or doesn't exist yet, set up `git-fuse` from the repository's top level:

    mkdir -p "$(git rev-parse --git-dir)/mounted" && git-fuse . "$(git rev-parse --git-dir)/mounted"

Only if that fails because the environment doesn't allow it (e.g. `git-fuse` is not installed, or inside a sandbox without `/dev/fuse`), abort and ask the user to set up `git-fuse`.

## Committing

Note that some things might already be staged. You may want to unstage everything first (e.g. `git reset`) to start with a clean index matching HEAD.

Before committing, re-check the staged diff with `git diff --cached`, then commit with regular `git commit`.

You can run the project's tests on `$GIT_DIR/mounted/index` before committing (e.g. `nix flake check path:$GIT_DIR/mounted/index`, or the project's usual test command run from within that directory). This directory is the exact tree that will end up in the commit - a complete, testable tree representing what a clean checkout of that commit would look like. Each atomic commit should pass tests independently. Note that if running the tests creates or modifies files in `$GIT_DIR/mounted/index`, these will also automatically be included in the commit, so make sure to clean up any unwanted changes before committing.
