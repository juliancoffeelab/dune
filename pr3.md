# PR 3

This path description is exploratory, not prescriptive.

Goal: produce a working patch for this path.

Worktrees:
- Use `/home/codex/workspace/dune-pr-3` for Dune changes.
- Use `/home/codex/workspace/ocaml-lsp-pr-3` for `ocaml-lsp`
  changes.
- This path is expected to patch both repos.

**3. Dune + ocaml-lsp: context-sensitive config API**
Dune exposes something like “config for external file `X` as seen from source file/package `Y`”, and `ocaml-lsp` preserves the origin context after goto-def.

Verification:
- First, add a Dune blackbox/cram test for the context-sensitive API or
  protocol shape itself.
- The blackbox test should prove that Dune can answer for external file
  `X` when given origin file or package context `Y`, and that different
  origin contexts can produce the intended result.
- Then add the smallest possible integration proof on the `ocaml-lsp`
  side that the origin context is preserved across goto-definition.
- Then run the real acceptance test in Neovim with a dedicated config
  directory for the experiment.
- All validation should use repo-built binaries only, not globally
  installed binaries.
- Launch `dune build --watch` using the exact Dune binary built from the
  Dune PR branch under test, and ensure the shell environment does not
  fall back to another `dune` on `PATH`.
- The Neovim config should explicitly configure the OCaml LSP client to
  launch the exact `ocamllsp` binary built from the PR under test, not a
  globally installed version.
- The Neovim config must pin the exact `ocamllsp` binary built from
  `/home/codex/workspace/ocaml-lsp-pr-3`.
- Start those repo-built binaries in the sample project before opening
  the editor, and wait for the initial build to complete.
- Open a tiny Dune project with one external dependency.
- From a project file, run goto-definition into the dependency source.
- Once inside the dependency file, run at least one more LSP action:
  hover, goto-definition again, or find references.
- Reopen the dependency file directly in the same editor session and
  confirm the borrowed context is still correct, or fails only in ways
  the design explicitly accepts.
- Restart the editor, reopen the dependency file, and confirm whether
  the design intentionally preserves or drops the extra context.
- Confirm normal in-workspace navigation still works unchanged.
- Record the exact Neovim config and launch command so the smoke test is
  reproducible for the same PR branch.
- Treat the editor result as the real pass/fail signal; the blackbox
  and integration tests are only the fast screening step.

## Postmortem

### Story of changes

I patched both repos. In `dune-pr-3`, `dune ocaml-merlin` now accepts an
optional origin/context path in its csexp request and can answer for an
external target using the origin file’s Merlin config. In
`ocaml-lsp-pr-3`, definition jumps record a borrowed origin, and
Merlin-config lookup now uses that origin both to pick the Dune project
root and to resend the config request with `Context=<origin>`. I also
added a Dune cram test for the new request shape and an `ocaml-lsp`
test for borrowed-context reuse.

### What worked

- Dune can answer a context-sensitive `ocaml-merlin` request for an
  external path.
- `ocaml-lsp` can preserve and reuse the origin instead of treating the
  opened target as standalone.
- The Dune blackbox test passed after tightening the fixture.
- The `ocaml-lsp` borrowed-context test passed.
- In editor probing, the branch-built `dune` + `ocamllsp` could jump
  from consumer code to an actually outside-workspace installed file at
  `/tmp/.../prefix/lib/extdep/extdep.ml`.

### What did not work or misled me

- The shared fixture from `nvim-outside-lsp` did not exercise PR3 at
  first, because goto-definition landed in
  `_build/_private/.../target/lib/...`, which is not a true
  outside-workspace path.
- The harness’s built-in second-action probe runs at the exact returned
  definition start. In both the synthetic-path case and the true
  outside-workspace case, that put the cursor at file start, so
  hover/definition looked broken even when the dependency buffer itself
  was usable.
- In `ocaml-lsp`, I initially reused borrowed context only for the
  request payload, not for project-root selection, so external files
  still bypassed Dune entirely.
- In Dune, I briefly broke Merlin-file selection by scanning only the
  first config file in a directory instead of checking all of them.

### How I solved it

- `ocaml-lsp` now uses borrowed origin to choose the project context
  directory before it ever starts `dune ocaml-merlin`.
- Dune’s context-based lookup now restores the original “scan all
  Merlin configs in the directory” behavior.
- For validation, I switched from the shared fixture’s package-managed
  copy path to a true installed external library under
  `/tmp/.../prefix/lib/extdep`, still using the shared harness config
  and branch-built binaries. That finally exercised the real PR3 path.
- I also stopped trusting the harness’s default follow-up cursor
  position and moved to manual symbol-position probes when needed.

### My view of the change

The implementation direction is correct for PR3. The Dune API shape and
the `ocaml-lsp` state threading match the path brief:
context-sensitive config on one side, preserved origin on the other.
The main remaining difficulty is not the core mechanism but proving it
cleanly in editor automation, because the shared harness’s default
follow-up action is too naive for this path.

### Pros

- small, surgical changes in both repos
- Dune now has an explicit context-sensitive config request shape
- `ocaml-lsp` no longer assumes the target path alone defines ownership
- the branch can reach real outside-workspace dependency files

### Cons

- editor validation is fragile because returned definition ranges are
  not good follow-up probe positions
- the real outside-workspace case required a custom installed-dependency
  setup, not the stock shared fixture
- the Dune-side behavior is still “borrow origin config for target”
  rather than a richer per-external-file ownership model
- the path is harder to validate than PR4-style sticky context because
  you need both the API shape and the editor state flow to line up

## Known Weakness

A realistic failure case is: restart the editor, then reopen the
dependency file directly from recent files.

Concrete repro:
- open a project file and run goto-definition into a true
  outside-workspace dependency file
- quit the editor
- start it again and open that same dependency file directly from recent
  files, a file picker, or the tree
- try hover or goto-definition inside that file

What the user would see:
- the file opens, but LSP behavior is degraded or dead
- hover may return nothing
- goto-definition or references may stop working

Why this fails:
- the borrowed origin context in this branch is session-local
- after restart, `ocaml-lsp` no longer remembers which workspace file
  provided the `Context`
- the outside file path by itself is still not enough for Dune to infer
  the right config

### Opening a sibling file in the external library

A realistic degraded workflow is: jump into one external file, then open
another file from the same outside-workspace library directly.

Concrete repro:
- jump from the workspace into `extdep.ml`
- from the editor tree, picker, or `:edit`, open a sibling file in the
  same external library
- try hover or goto-definition there

What the user would see:
- the original target file works
- the sibling file can be degraded or dead

Why this fails:
- this branch remembers borrowed context for the exact target file only
- sibling files in the same external library do not automatically inherit
  that origin

### Jumping into the same external file from a different origin

A realistic degraded workflow is: two different project files jump to
the same outside dependency file in one session.

Concrete repro:
- jump from project file `A` into external file `X`
- later jump from a different project file `B` into that same external
  file `X`
- then use LSP inside `X`

What the user would see:
- behavior can depend on which origin was remembered last
- navigation can feel unstable or context-sensitive in surprising ways

Why this fails:
- the current borrowed-context mapping is keyed too coarsely
- a single external file can legitimately have more than one relevant
  origin, but the branch does not fully model that

## Reproduction Steps

### Restart and direct reopen

1. Open a project file and jump into a true outside-workspace dependency
   file.
2. Quit the editor.
3. Start a fresh editor session.
4. Open that same dependency file directly from recent files, a picker,
   or the file tree.
5. Try hover or goto-definition there.

Expected result:
- The reopened dependency file still behaves as owned by the original
  project.

Actual result:
- Hover, goto-definition, or references can be degraded or dead because
  the remembered origin was only session-local.

### Open a sibling file directly

1. Jump from the project into one file in an outside library.
2. Use the tree, picker, or `:edit` to open a sibling file in that same
   external library.
3. Try hover or goto-definition in the sibling file.

Expected result:
- The sibling file inherits the same effective project context as the
  original external target.

Actual result:
- The original target works, but the sibling file can be degraded or
  dead.

### Reach the same external file from two origins

1. From project file `A`, jump to external file `X`.
2. Later in the same session, from a different project file `B`, jump to
   that same external file `X`.
3. Use hover or goto-definition inside `X`.

Expected result:
- The file has a stable, principled ownership model even when multiple
  origins are possible.

Actual result:
- Behavior can depend on which origin was remembered last.

## Possible Fixes

### Restart and direct reopen

The cleanest fix is to persist provenance from external file path back
to one or more origin files or workspaces, then reuse it to populate the
Dune `Context` request after restart.

Proposed approach:
- give `ocaml-lsp` a per-workspace cache from external file path to one
  or more origins
- reload that cache on startup
- invalidate it when workspace or dependency layout changes

Feasibility:
- medium-hard
- technically doable, but it becomes a persistence and staleness design
  rather than a small extension

### Opening sibling files in the same external library

This is the best next fix for the branch.

Proposed approach:
- widen remembered scope from one exact file to an external library root
  or containing subtree
- when no exact file mapping exists, fall back to the nearest borrowed
  external root

Feasibility:
- fairly feasible
- this is still branch-shaped and mostly local to `ocaml-lsp` lookup
  policy

### Same external file from different origins

This needs richer provenance than a single file-path map.

Proposed approach:
- allow more than one borrowed context per external file
- choose the right one based on stronger provenance than “last file to
  jump here”
- as a weaker mitigation, prefer the most recent origin in the same
  workspace

Feasibility:
- medium for a partial mitigation
- hard for a principled fix

### Opening a sibling file in the external library

Concrete repro:
- open a project file and run goto-definition into a true
  outside-workspace dependency file such as `extdep.ml`
- once that file is open and working, use the editor normally to open a
  sibling file from the same installed library, such as `extdep_types.ml`
- try hover or goto-definition in the sibling file

What the user would see:
- the first external file still works
- the sibling file opens, but LSP is degraded or dead there
- hover may be empty and navigation may stop resolving

Why this fails:
- this branch records borrowed context for the exact target file URI
- opening a sibling file is a fresh path that never went through the
  goto-definition handoff
- `ocaml-lsp` therefore has no saved origin to send back as `Context`
  for that sibling file

### Jumping into the same external file from a different origin

Concrete repro:
- in one editor session, open `app1/main.ml` and run goto-definition
  into an outside-workspace dependency file
- go back, open `app2/main.ml` from a different Dune context or package,
  and run goto-definition into that same dependency file path
- return to the dependency buffer and run hover or goto-definition again

What the user would see:
- the dependency buffer stays open, but LSP answers can change or become
  inconsistent after the second jump
- names may resolve according to the most recent origin rather than the
  one that originally opened the buffer

Why this fails:
- the borrowed-context table in this branch is keyed by target file path
  only
- when the same external file is reached from a second origin, the first
  origin is overwritten
- PR3 therefore cannot represent multiple simultaneous origins for the
  same external file in one session
-## Postmortem
+
+### 1. Story of changes
+
+I patched both repos. In `dune-pr-3`, `dune ocaml-merlin` now accepts an
+optional origin/context path in its csexp request and can answer for an
+external target using the origin file's Merlin config. In
+`ocaml-lsp-pr-3`, definition jumps record a borrowed origin, and
+Merlin-config lookup now uses that origin both to pick the Dune project
+root and to resend the config request with `Context=<origin>`. I also
+added a Dune cram test for the new request shape and an `ocaml-lsp`
+test for borrowed-context reuse.
+
+### 2. What worked
+
+The core branch-specific mechanism worked:
+
+- Dune can answer a context-sensitive `ocaml-merlin` request for an
+  external path.
+- `ocaml-lsp` can preserve and reuse the origin instead of treating the
+  opened target as standalone.
+- The Dune blackbox test passed after tightening the fixture.
+- The `ocaml-lsp` borrowed-context test passed.
+- In editor probing, the branch-built `dune` + `ocamllsp` could jump
+  from consumer code to an actually outside-workspace installed file at
+  `/tmp/.../prefix/lib/extdep/extdep.ml`.
+
+### 3. What did not work or misled me
+
+Two things misled the validation:
+
+- The shared fixture from `nvim-outside-lsp` did not exercise PR3 at
+  first, because goto-definition landed in
+  `_build/_private/.../target/lib/...`, which is not a true
+  outside-workspace path.
+- The harness's built-in second-action probe runs at the exact returned
+  definition start. In both the synthetic-path case and the true
+  outside-workspace case, that put the cursor at file start, so
+  hover/definition looked broken even when the dependency buffer itself
+  was usable.
+
+I also lost time on two implementation mistakes:
+
+- In `ocaml-lsp`, I initially reused borrowed context only for the
+  request payload, not for project-root selection, so external files
+  still bypassed Dune entirely.
+- In Dune, I briefly broke Merlin-file selection by scanning only the
+  first config file in a directory instead of checking all of them.
+
+### 4. How I solved it
+
+I fixed the real logic gaps first:
+
+- `ocaml-lsp` now uses borrowed origin to choose the project context
+  directory before it ever starts `dune ocaml-merlin`.
+- Dune's context-based lookup now restores the original "scan all Merlin
+  configs in the directory" behavior.
+
+For validation, I switched from the shared fixture's package-managed
+copy path to a true installed external library under
+`/tmp/.../prefix/lib/extdep`, still using the shared harness config and
+branch-built binaries. That finally exercised the real PR3 path. I also
+stopped trusting the harness's default follow-up cursor position and
+moved to manual symbol-position probes when needed.
+
+### 5. My view of the change
+
+The implementation direction is correct for PR3. The Dune API shape and
+the `ocaml-lsp` state threading match the path brief:
+context-sensitive config on one side, preserved origin on the other. The
+main remaining difficulty is not the core mechanism but proving it
+cleanly in editor automation, because the shared harness's default
+follow-up action is too naive for this path.
+
+### 6. Pros/cons
+
+Pros
+
+- Small, surgical changes in both repos.
+- Dune now has an explicit context-sensitive config request shape.
+- `ocaml-lsp` no longer assumes the target path alone defines
+  ownership.
+- The branch can reach real outside-workspace dependency files.
+
+Cons
+
+- Editor validation is fragile because returned definition ranges are
+  not good follow-up probe positions.
+- The real outside-workspace case required a custom
+  installed-dependency setup, not the stock shared fixture.
+- The Dune-side behavior is still "borrow origin config for target"
+  rather than a richer per-external-file ownership model.
+- The path is harder to validate than PR4-style sticky context because
+  you need both the API shape and the editor state flow to line up.
