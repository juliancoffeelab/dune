# PR 4

This path description is exploratory, not prescriptive.

Goal: produce a working patch for this path.

Worktrees:
- Use `/home/codex/workspace/dune-pr-4` for Dune-side validation and any
  Dune changes that turn out to be necessary.
- Use `/home/codex/workspace/ocaml-lsp-pr-4` for `ocaml-lsp` changes.
- This path is expected to patch `ocaml-lsp`, and may also patch Dune if
  the experiment needs it.

**4. ocaml-lsp workaround: sticky borrowed context**
Without waiting for a richer Dune model, `ocaml-lsp` could treat jumped-to external files as continuing under the source file’s config.

Verification:
- First, add the smallest possible Dune blackbox/cram test or direct
  `dune ocaml-merlin` probe needed to show that the borrowed project
  config is at least sufficient for the jumped-to dependency file.
- Then add the smallest possible `ocaml-lsp`-level proof that the
  source file’s context is carried across goto-definition.
- Then run the real acceptance test in Neovim with a dedicated config
  directory for the experiment.
- All validation should use repo-built binaries only, not globally
  installed binaries.
- Launch `dune build --watch` using the exact Dune binary built from
  `/home/codex/workspace/dune-pr-4`, and ensure the shell environment
  does not fall back to another `dune` on `PATH`.
- The Neovim config should explicitly configure the OCaml LSP client to
  launch the exact `ocamllsp` binary built from
  `/home/codex/workspace/ocaml-lsp-pr-4`, not a globally installed
  version.
- Start those repo-built binaries in the sample project before opening
  the editor, and wait for the initial build to complete.
- Open a tiny Dune project with one external dependency.
- From a project file, run goto-definition into the dependency source.
- Once inside the dependency file, run at least one more LSP action:
  hover, goto-definition again, or find references.
- Reopen the dependency file directly and confirm whether the behavior
  intentionally degrades once the borrowed context is gone.
- Restart the editor and repeat the same check, since this design is
  especially sensitive to session-local state.
- Confirm normal in-workspace navigation still works unchanged.
- Record the exact Neovim config and launch command so the smoke test is
  reproducible for the same PR branch.
- Treat the editor result as the real pass/fail signal; the earlier
  checks are only there to avoid wasting time on a dead prototype.

## Postmortem

1. Story of changes
I first implemented PR4 as a one-shot borrowed Merlin config in
`ocaml-lsp`: store the source file's resolved config when
goto-definition lands in a dependency file, then consume that config on
the next open of that target. The first version only borrowed for paths
outside the workspace. After validation, I widened it to also borrow
for Dune's synthetic dependency paths under `_build/_private/.pkg/...`,
because that is what this branch actually returned during navigation. I
also added a focused expect test for the one-shot behavior.

2. What worked
The `ocaml-lsp` change itself built and the focused test passed. The
branch-built Dune and branch-built `ocamllsp` were both usable. The
shared harness plus a custom outside-package consumer project
eventually produced a true outside-workspace goto-definition target:
`/home/codex/.opam/default/lib/pr4-outside-smoke/pr4_outside_smoke.ml`

3. What did not work or misled me
The shared fixture in `nvim-outside-lsp` was misleading for PR4 on this
branch. It did not jump to a true outside-workspace file; it jumped to
Dune's synthetic `_build/_private/.pkg/.../target/lib/...` path, so the
initial "editor validation" was not exercising PR4 at all. The built-in
harness hover check was also weak because it hovered on the
definition-site cursor for `message`, which was not a reliable signal.
That forced a more targeted editor check.

4. How I solved it
I stopped treating the shared fixture as authoritative and built a
branch-specific outside dependency setup:
- external package installed from a real outside path
- consumer project built with branch Dune
- pinned Neovim runs using branch `ocamllsp`
That gave a real outside-workspace definition target and let validation
move onto the actual PR4 case instead of the synthetic `_build/.pkg`
case.

5. My view of the change
The change is directionally correct for PR4: it is small,
session-local, and does not require new Dune APIs. But the
branch-specific validation showed that Dune path shapes matter a lot. If
Dune hands back synthetic workspace-owned paths, PR4's borrowed-context
logic is bypassed or becomes less relevant. So the change is useful,
but it is inherently brittle and path-shape dependent.

6. Pros/cons
Pros
- Small `ocaml-lsp`-only change
- No Dune protocol change required
- Clear one-shot/session-local model
- Easy to reason about in code and test directly

Cons
- Path-shape dependent; Dune synthetic paths weaken the PR4 case
- Heuristic, not a real ownership model
- Reopen/restart behavior is intentionally degraded
- Validation required a custom true-outside dependency setup because the
  shared fixture did not hit the intended path on this branch

## Known Weakness

A realistic failure case is: use goto-definition into the dependency
file, then later reopen that same file directly from recent files,
buffer picker, or file tree.

Concrete repro:
- open the consumer source file
- run goto-definition into the outside dependency file
- close that buffer
- reopen the same dependency file directly, without coming from
  goto-definition
- try hover or goto-definition on local symbols in that file

What the user would see:
- the first open from goto-definition works
- the reopened file has weaker or missing Merlin-backed features

Why this fails:
- PR4 is intentionally one-shot borrowed state
- the dependency file only gets the source file’s config when opened as
  the immediate target of goto-definition
- once that borrowed config is consumed, reopening the file falls back
  to standalone outside-workspace behavior

### Fresh editor restart

A realistic failure case is: quit the editor after jumping into the
outside dependency, then reopen that same dependency file directly in a
new session.

Concrete repro:
- jump into the outside dependency file
- quit the editor
- reopen that same file directly from recent files or the picker
- try hover or goto-definition there

What the user would see:
- the file opens
- the borrowed behavior is gone
- hover/goto-definition are degraded or missing

Why this fails:
- PR4 stores borrowed state only in process memory
- after restart there is nothing left to reuse

### Second jump inside the dependency library

A realistic degraded workflow is: jump into the outside dependency file,
then navigate onward to a sibling file in that same outside library.

Concrete repro:
- jump into one outside dependency file
- from there, run goto-definition on a symbol that lives in another file
  in the same library

What the user would see:
- the first file works
- the second file can lose the borrowed context and degrade

Why this fails:
- PR4 borrows context for one target file only
- it does not naturally widen to the containing library subtree

## Reproduction Steps

### Same-session direct reopen

1. Open the consumer file.
2. Jump into the outside dependency file with goto-definition.
3. Close that dependency buffer.
4. Reopen the same file directly, without coming from goto-definition.
5. Try hover or goto-definition on local symbols in that file.

Expected result:
- The reopened file keeps the same borrowed project context within the
  same editor session.

Actual result:
- The first open works, but the reopened file can lose Merlin-backed
  features.

### Fresh editor restart

1. Jump into the outside dependency file.
2. Quit the editor.
3. Start a fresh editor session.
4. Reopen that same file directly from recent files or the picker.
5. Try hover or goto-definition there.

Expected result:
- The dependency file still behaves as owned by the project it came
  from.

Actual result:
- The file opens, but the borrowed behavior is gone.

### Second jump inside the dependency library

1. Jump into one outside dependency file.
2. From there, run goto-definition on a symbol that lives in another
   file in the same outside library.
3. In the second file, try hover or goto-definition again.

Expected result:
- Borrowed context extends naturally across the outside library.

Actual result:
- The first file works, but the second file can lose the borrowed
  context and degrade.

## Possible Fixes

### Same-session direct reopen

The smallest next fix is to replace one-shot consumption with a
short-lived session cache.

Proposed approach:
- keep borrowed context alive for a file while the session still has a
  plausible owner
- expire it when the user leaves the outside library, the workspace
  changes, or the file is idle long enough

Feasibility:
- very feasible
- this is the easiest extension of the current patch

### Fresh editor restart

The only plausible fix is restart persistence, but it is conceptually
the weakest one.

Proposed approach:
- persist a lightweight mapping from outside file or library root back
  to the source workspace or config
- reload it on next start

Feasibility:
- moderate technically
- weak conceptually, because the cached ownership can become stale after
  rebuilds, opam changes, or workspace changes

### Second jump inside the dependency library

This should be fixed by widening borrowed scope from one exact target
file to the containing outside-library root.

Proposed approach:
- store borrowed context by directory prefix or library root, not only
  by exact URI
- let sibling files in the same outside library inherit that context

Feasibility:
- fairly feasible
- the main risk is overreach if multiple workspaces can legitimately
  point into the same installed library tree

### Fresh editor restart

Concrete repro:
- open the consumer source file
- run goto-definition into the outside dependency file
- quit the editor
- start a fresh editor session and open that same dependency file
  directly from recent files or a file picker
- try hover, completion, or goto-definition in that file

What the user sees:
- the dependency file worked in the earlier navigation flow
- after restart, the same file opens with weaker or missing
  Merlin-backed features

Why it fails:
- the borrowed config is session-local and not persisted anywhere
- a fresh `ocamllsp` process has no record of the source file that
  originally supplied context
- the outside file is again treated as a standalone file with no durable
  owning workspace

### Second jump inside the dependency library

Concrete repro:
- open the consumer source file
- run goto-definition into the outside dependency file
- inside that file, run goto-definition on another library-local symbol,
  such as a helper module defined in a sibling file
- land in the second outside dependency file
- try hover or goto-definition again there

What the user sees:
- the first dependency file works after the original jump
- the second file can lose language features or behave inconsistently
  compared with the first one

Why it fails:
- PR4 only borrows context from the original source-to-target jump
- it does not establish durable context for the whole outside library
- once navigation moves to a different outside file, there may be no
  borrowed config prepared for that new target
