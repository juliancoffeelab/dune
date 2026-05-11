# PR 6

This path description is exploratory, not prescriptive.

Goal: produce a working patch for this path.

Worktrees:
- Use `/home/codex/workspace/dune-pr-6` for Dune changes.
- Use `/home/codex/workspace/ocaml-lsp-pr-6` for `ocaml-lsp` changes.
- This path is expected to patch both repos.

**6. Hybrid PR1+3: real external paths plus explicit origin context**
Keep the real external dependency file as the editor-visible path, but
combine it with PR3-style context-aware Dune/LSP plumbing so external
files are owned by provenance rather than by path alone.

What this path should try to achieve:
- Keep goto-definition landing on the real external path, not a
  synthetic `_build/.pkg/...` surrogate.
- Replace lossy “reconstruct from installed metadata only” behavior with
  stronger origin-aware config lookup where needed.
- Use PR3-style `Context=<origin>` support to preserve same-session
  reopen behavior and avoid target-path-only ownership.
- If possible, reduce PR1’s PPX/reader fidelity loss by reusing richer
  Merlin data instead of thin synthetic fallback.

Validation:
- Use the shared harness at
  `/home/codex/workspace/dune/test/end-to-end/nvim-outside-lsp`.
- Treat the editor result as the real pass/fail signal.
- All validation should use repo-built binaries only.
- Launch `dune build --watch` using the exact Dune binary built from
  `/home/codex/workspace/dune-pr-6`.
- Configure Neovim to launch the exact `ocamllsp` binary built from
  `/home/codex/workspace/ocaml-lsp-pr-6`.

Mandatory lockdir fixture checks:
- Run the lockdir-managed local-source fixture with `--fixture`.
- Confirm goto-definition lands on the real external path under
  `external_sources/...`, not `_build/.pkg/...`.
- Confirm a second LSP action works inside that real external file.
- Reopen the same external file in the same session and confirm the
  same LSP action still works.

Mandatory installed-fixture checks:
- Run the installed outside-library fixture with `--fixture-installed`.
- Confirm goto-definition lands on the true installed outside path.
- Confirm a second LSP action works there.
- Exercise at least one same-session reopen or sibling-file case.

Fast screening:
- Add the smallest Dune blackbox/cram test that proves the real external
  path is queryable with the richer context model.
- Add the smallest `ocaml-lsp` integration test that proves remembered
  origin/context is reused for real external files.

Stretch goal:
- If the branch gets far enough, extend either fixture to cover a PPX or
  compile-flag-sensitive dependency file, since that is the known weak
  point of plain PR1.

## Design Note

This branch combines:
- PR1's real external-path mapping for package-managed local sources
- PR3's remembered-origin and `Context=<origin>` request flow

Current implementation seam:
- Dune still maps a real external dependency file back into package-managed
  build/install knowledge so the editor-visible path stays real.
- `dune ocaml-merlin` now accepts optional origin context for the same real
  external path.
- When a target file has no direct workspace Merlin config, Dune first tries
  context-aware lookup and then falls back to the external-package path logic.
- `ocaml-lsp` remembers the origin of goto-definition targets and reuses that
  origin for both project-root selection and the Dune request when the target
  file opens later in the same session.

## Validation Results

Validated with the shared harness at
`/home/codex/workspace/dune/test/end-to-end/nvim-outside-lsp`.

- Lockdir fixture passed with repo-built binaries:
  branch-built Dune at `_build/default/bin/main.exe` and branch-built
  `ocamllsp` at `_build/install/default/bin/ocamllsp`.
- The editor jumped to the real external path
  `external_sources/smoke_dep.ml`, not a `_build/.pkg/...` surrogate.
- A second `textDocument/definition` request inside that real external
  file succeeded in the same session.
- The installed outside-library fixture also passed and landed on the
  true installed outside path under `prefix/lib/extdep/extdep.ml`.
- `git diff --check` passed on both the Dune and `ocaml-lsp` worktrees.
- The focused Dune cram test at
  `test/blackbox-tests/test-cases/pkg/merlin-external-context.t`
  passed after fixing blank-line cram formatting in the test file.

Current caveat:
- The focused `ocaml-lsp` test file
  `ocaml-lsp-server/test/e2e-new/borrowed_context.ml` is present and
  compiled as part of the branch build, but the usual `dune runtest ...`
  wrapper behaved oddly in this environment, so the strongest proof here
  is again the real Neovim harness run rather than a separately
  captured inline-test invocation.

## Story Of Changes

This branch merged:
- PR1's real external-path mapping
- PR3's remembered-origin and `Context=<origin>` request flow

The concrete shape is:
- Dune still maps a real external dependency path back into
  package-managed build/install knowledge instead of forcing the editor
  onto a synthetic path.
- `dune ocaml-merlin` now accepts optional origin context for those same
  real external files.
- `ocaml-lsp` remembers the origin file after goto-definition and reuses
  that origin both to pick project context and to retry the Dune query.

What worked:
- In the lockdir local-source fixture, goto-definition landed on the
  real `external_sources/smoke_dep.ml` path.
- A second definition inside that real external file succeeded.
- In the installed outside-library fixture, goto-definition landed on
  the true installed outside path under `prefix/lib/extdep/extdep.ml`.

What is still not perfect:
- The branch is stronger than PR1, but it still keeps PR1's reverse
  mapping and fallback reconstruction machinery.
- When origin is unavailable or ambiguous, some of the old PR1 fidelity
  concerns can still reappear.

## Pros

- Best user-facing path behavior: the editor sees the real file.
- Better same-session provenance handling than plain PR1.
- Works in both lockdir local-source and installed outside-library
  scenarios.
- Best fit for “jump to the real dependency file and keep going”.

## Cons

- More moving parts than PR3 alone.
- Still requires both Dune and `ocaml-lsp`.
- Provenance ambiguity remains when multiple origins are possible.
- The hardest fidelity cases may still depend on fallback reconstruction
  instead of purely generated artifacts.

## Known Weaknesses

- If the same external file is reached from two different origins with
  different effective contexts, the current remembered-origin table is
  last-writer-wins. A normal user can trigger this by using two
  packages, executables, or test contexts that jump into the same
  dependency file.
- After editor restart, the remembered origin is gone. Direct reopen of
  the external file may still work if Dune's real-path reverse mapping
  is enough, but richer origin-sensitive cases can degrade.
- Opening a sibling file in the same external library directly, rather
  than reaching it through goto-definition first, may lose the borrowed
  provenance that made the first file work.
- PPX, reader, or compile-flag-sensitive dependency code can still be a
  weak spot if the branch falls back to reconstructed external-package
  config rather than richer generated Merlin data.

## Reproduction Steps

### Same external file from two origins

1. Create two project files or contexts that can both jump to the same
   external dependency file.
2. From origin `A`, jump to external file `X`.
3. Later in the same session, from origin `B`, jump to that same file
   `X`.
4. Use hover or goto-definition inside `X`.

Expected result:
- The external file has a stable ownership model even with more than
  one plausible origin.

Actual result:
- Behavior can depend on which origin was remembered last.

### Restart and direct reopen

1. Jump from the workspace into the real external dependency file.
2. Quit the editor.
3. Start a fresh editor session.
4. Open that same external file directly from recent files or the
   picker.
5. Try hover or goto-definition there.

Expected result:
- The reopened external file still behaves as owned by the originating
  project.

Actual result:
- Direct reopen may still work in easy cases, but richer
  origin-sensitive behavior can degrade because the remembered origin is
  gone.

### Open a sibling external file directly

1. Jump from the workspace into one file of an external library.
2. Open a sibling file from the same external library directly via tree,
   picker, or `:edit`.
3. Try hover or goto-definition in that sibling file.

Expected result:
- The sibling file inherits the same borrowed project context.

Actual result:
- The original file works, but the sibling file may lose the borrowed
  provenance that made the first one work.

### PPX or compile-flag-sensitive external file

1. Make the external dependency use a PPX or rely on package-specific
   compile flags.
2. From the consumer project, jump into that external file.
3. Try diagnostics, hover, completion, or follow-up goto-definition in
   that file.

Expected result:
- The external file keeps the same rich compile environment it had when
  built.

Actual result:
- If the branch falls back to reconstructed external-package config,
  PPX/reader/flag-sensitive behavior can still degrade.

## Possible Fixes

- Widen remembered provenance from exact file to library root or source
  subtree so sibling-file navigation stays in the same borrowed world.
- Track more than one candidate origin for a target file and choose
  among them more deliberately than last-writer-wins.
- Persist richer processed Merlin config for package-managed external
  libraries so fallback reconstruction is needed less often.
- If restart continuity matters, add a provenance cache with careful
  invalidation, but that is a bigger design commitment.

## Follow-Up

After the original PR6 experiment proved the real-path borrowed-context
approach was viable, the follow-up branch tightened the Dune-side Merlin
fallbacks so the feature works in the cases that still broke in real
editor use.

What changed in Dune:
- `merlin: support external package source files`
  taught Dune to synthesize Merlin config for external package source
  files when there is no nearby generated Merlin file to read from
  directly.
- `merlin: handle external package target files`
  extended that logic to package-managed target files under paths like
  `_build/_private/default/.pkg/.../target/lib/.../*.ml`, which is what
  showed up in the failing `Fmt`/stdlib follow-up cases.
- The blackbox test
  `test/blackbox-tests/test-cases/pkg/merlin-external-context.t`
  was widened to cover the real package-managed source/target path
  shapes that triggered the failures.

What changed in `ocaml-lsp`:
- The follow-up branch there added stronger borrowed-context coverage in
  `ocaml-lsp-server/test/e2e-new/borrowed_context.ml`.
- That test work is meant to lock in the practical editor behavior for
  “jump into dependency code, then keep navigating there” rather than
  only the initial goto-definition hop.

What the follow-up was specifically trying to fix:
- real external package source files still needed better fallback Merlin
  config in some cases
- package-managed target files could fail with “no config found”
- stdlib navigation from inside borrowed external files still needed to
  keep finding sibling modules like `Seq`

Net result:
- the follow-up branch is not a new design; it is the “make PR6
  actually hold up in practice” pass
- it keeps the same PR6 model of real editor-visible paths plus explicit
  origin context
- it mainly hardens the Dune fallback path so the already-chosen model
  survives stdlib and package-target follow-up navigation
