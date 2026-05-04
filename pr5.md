# PR 5

This path description is exploratory, not prescriptive.

Goal: produce a working patch for this path.

Worktrees:
- Use `/home/codex/workspace/dune-pr-5` for Dune changes.
- Use `/home/codex/workspace/ocaml-lsp-pr-5` for `ocaml-lsp` changes.
- This path is expected to patch both repos.

**5. Hybrid PR2+3: synthetic Dune-owned package paths plus explicit origin context**
Treat the Dune-owned synthetic package path as the canonical editor path,
but add PR3-style context-aware Dune/LSP plumbing where the synthetic
path alone is not rich enough or becomes ambiguous.

What this path should try to achieve:
- Keep the editor landing on a Dune-owned package path under
  `_build/_private/default/.pkg/...`.
- Avoid thin fallback-only behavior for reopened synthetic files.
- Reuse PR3-style origin/context threading where synthetic package files
  need stronger semantic context, sibling-file support, or multi-origin
  disambiguation.
- Prefer real Merlin artifacts over hand-built fallback responses where
  possible.

Validation:
- Use the shared harness at
  `/home/codex/workspace/dune/test/end-to-end/nvim-outside-lsp`.
- Treat the editor result as the real pass/fail signal.
- All validation should use repo-built binaries only.
- Launch `dune build --watch` using the exact Dune binary built from
  `/home/codex/workspace/dune-pr-5`.
- Configure Neovim to launch the exact `ocamllsp` binary built from
  `/home/codex/workspace/ocaml-lsp-pr-5`.

Mandatory lockdir fixture checks:
- Run the lockdir-managed local-source fixture with `--fixture`.
- Confirm goto-definition lands on a Dune-owned package path under
  `_build/_private/default/.pkg/...`.
- Confirm a second LSP action works inside that file.
- Reopen the same synthetic file in the same session and confirm the
  same LSP action still works.
- Exercise at least one sibling-file or same-file-different-origin case
  inside the synthetic package tree.
- Confirm normal in-workspace navigation still works.

Secondary installed-fixture checks:
- Run the installed outside-library fixture with `--fixture-installed`.
- If the hybrid touches generic origin plumbing, confirm it does not
  regress true outside-workspace dependency handling.

Fast screening:
- Add the smallest Dune blackbox/cram test that proves the synthetic
  package path is queryable with the richer context model.
- Add the smallest `ocaml-lsp` integration test that proves remembered
  origin/context is reused for synthetic package files.

## Design Note

PR5 will merge PR2's path-ownership model with PR3's provenance model.

- Dune remains responsible for making package-managed dependencies appear
  under a Dune-owned `.pkg/...` path rather than a raw outside path.
- `ocaml-lsp` remains responsible for remembering how we reached that
  dependency file, then reusing that origin when the synthetic path
  needs richer Merlin context than its own path provides.

The intended seam is:

- In Dune, keep the PR2-style synthetic source-dir/package decoding
  changes so locate points into the `.pkg` tree and package metadata is
  interpreted against that tree.
- In `dune ocaml-merlin`, combine PR2's `.pkg`-path preservation with
  PR3's `Context=<origin>` request shape. Direct synthetic-path lookup
  should try real Merlin artifacts first, then retry with the origin
  context when the synthetic path alone is not enough.
- In `ocaml-lsp`, reuse PR3's remembered-origin mechanism for synthetic
  package files as well as true outside-workspace files, so reopen and
  follow-up queries in the same session keep the originating project
  context.

The branch should prefer real generated Merlin artifacts over thin
fallback responses. A hand-built fallback is acceptable only as a last
resort, not as the primary reopened-file path.

## Validation Results

Validated with the shared harness at
`/home/codex/workspace/dune/test/end-to-end/nvim-outside-lsp`.

- Lockdir fixture passed with repo-built binaries:
  branch-built Dune at `_build/default/bin/main.exe` and branch-built
  `ocamllsp` at `_build/install/default/bin/ocamllsp`.
- The editor jumped to a synthetic Dune-owned path under
  `_build/_private/default/.pkg/.../source/smoke_dep.ml`.
- A second `textDocument/definition` request inside that synthetic file
  succeeded in the same session.
- The installed outside-library fixture also passed, so the added
  origin plumbing did not regress the true outside-workspace case.
- `git diff --check` passed on both the Dune and `ocaml-lsp` worktrees.
- The focused Dune cram test at
  `test/blackbox-tests/test-cases/pkg/merlin-synthetic-context.t/`
  passed.

Current caveat:
- The focused `ocaml-lsp` test file
  `ocaml-lsp-server/test/e2e-new/borrowed_synthetic_context.ml` is
  present and compiled as part of the branch build, but the usual
  `dune runtest ...` wrapper behaved oddly in this environment, so the
  strongest proof here is the real Neovim harness run rather than a
  separately captured inline-test invocation.

## Story Of Changes

This branch merged:
- PR2's synthetic Dune-owned package path model
- PR3's remembered-origin and `Context=<origin>` request flow

The concrete shape is:
- Dune still rewrites package-managed dependency navigation into the
  `.pkg/...` tree and teaches Merlin/package decoding to treat that tree
  as a real owner.
- `dune ocaml-merlin` now also accepts optional origin context for those
  synthetic paths.
- `ocaml-lsp` remembers where a synthetic package file was reached from,
  and reuses that origin later when the synthetic path alone is not
  enough.

What worked:
- From the workspace file, goto-definition landed on a synthetic
  `.pkg/.../source/smoke_dep.ml` path.
- A second definition inside that synthetic file succeeded.
- The installed outside-library fixture still worked, so the borrowed
  origin plumbing did not break true outside paths.

What did not fully become native:
- The path ownership story is strong, but the design still depends on
  remembered origin in `ocaml-lsp` for the richer cases.
- The branch is not yet a pure “the synthetic tree owns everything by
  itself” story.

## Pros

- Strong Dune-owned path identity.
- Better same-session behavior than plain PR2.
- Closer to the original Dune issue framing than the real-path hybrids.
- No regression in the installed outside-library case.

## Cons

- Synthetic editor paths are less pleasant than real ones.
- Exact-file origin tracking can still be too narrow.
- Two-repo coordination is required.
- The focused `ocaml-lsp` proof is weaker than the editor proof in this
  environment.

## Known Weaknesses

- If the same synthetic dependency file is reached from two different
  origins in one session, the current remembered-origin table is
  last-writer-wins. A normal user can trigger this by jumping into the
  same dependency from two executables or libraries with different
  effective contexts.
- If a user opens a sibling file inside the synthetic package tree
  directly, without arriving there through goto-definition first, the
  exact-file borrowed origin may be missing and the path may have to
  fall back to synthetic-path-only behavior.
- After editor restart, any remembered origin is gone. If the synthetic
  path alone is not sufficient for some richer semantic case, the branch
  will degrade after reopen.

## Reproduction Steps

### Same synthetic file from two origins

1. Create two project entry points with different effective contexts.
2. From file `A`, jump into the same synthetic dependency file.
3. Later in the same session, from file `B`, jump into that same
   synthetic dependency file.
4. Use hover or goto-definition inside the synthetic file.

Expected result:
- The synthetic file has a stable ownership model even with more than
  one plausible origin.

Actual result:
- Behavior can depend on which origin was remembered last.

### Open a sibling synthetic file directly

1. Jump from the workspace into one synthetic package file under
   `_build/_private/default/.pkg/.../source/...`.
2. Use the tree, picker, or `:edit` to open a sibling file in the same
   synthetic package subtree.
3. Try hover or goto-definition in that sibling file.

Expected result:
- The sibling file inherits the same borrowed project context.

Actual result:
- The original file works, but the sibling file may fall back to
  synthetic-path-only behavior.

### Restart and reopen the synthetic file

1. Jump into the synthetic dependency file.
2. Quit the editor.
3. Start a fresh editor session.
4. Open that same synthetic file directly.
5. Try hover or goto-definition there.

Expected result:
- The synthetic file still behaves as owned by the originating project.

Actual result:
- Any remembered origin is gone, so richer origin-sensitive behavior can
  degrade after reopen.

## Possible Fixes

- Widen remembered provenance from exact file to package root or library
  subtree, so sibling-file navigation inherits the same origin.
- Track multiple candidate origins per synthetic target and choose among
  them more carefully than last-writer-wins.
- Move more of the semantic truth into real generated Merlin artifacts
  under the synthetic tree, so origin is needed less often.
- If restart behavior matters, persist a package-root-to-origin cache,
  but only if the staleness story is acceptable.
