# PR 1

This path description is exploratory, not prescriptive.

Goal: produce a working patch for this path.

Worktree:
- Use only `/home/codex/workspace/dune-pr-1`.
- For editor validation, use the stock `ocaml-lsp` checkout at
  `/home/codex/workspace/ocaml-lsp`.

**1. Dune-only: make external package source files directly queryable**
Dune would answer `ocaml-merlin` for installed dependency source paths as-is.

Verification:
- First, add a Dune blackbox/cram test that proves `dune ocaml-merlin`
  can answer for the installed dependency source path itself.
- The blackbox test should show that a project file can locate into the
  dependency and that querying config for the dependency file no longer
  fails with “not in dune workspace”.
- Then run the real acceptance test in Neovim with a dedicated config
  directory for the experiment.
- All validation should use repo-built binaries only, not globally
  installed binaries.
- Launch `dune build --watch` using the exact Dune binary built from the
  PR branch under test, and ensure the shell environment does not fall
  back to another `dune` on `PATH`.
- The Neovim config should explicitly configure the OCaml LSP client to
  launch the repo-built `ocamllsp` binary from
  `/home/codex/workspace/ocaml-lsp`, not a globally installed version.
- Start that repo-built `dune build --watch` in the sample project
  before opening the editor, and wait for the initial build to complete.
- Open a tiny Dune project with one external dependency.
- From a project file, run goto-definition into the dependency source.
- Once inside the dependency file, run at least one more LSP action:
  hover, goto-definition again, or find references.
- Confirm the opened path is the real installed path, not a rewritten
  synthetic path.
- Reopen the dependency file directly and confirm the same LSP action
  still works.
- Confirm normal in-workspace navigation still works unchanged.
- Record the exact Neovim config and launch command so the smoke test is
  reproducible for the same PR branch.
- Treat the editor result as the real pass/fail signal; the blackbox
  test is only the fast screening step.

## Postmortem

### Story

I started with the narrow Dune-side idea in PR1: make
`dune ocaml-merlin` accept an external local-source package file path
and translate it to the package-managed build tree. The first patch only
added that path translation in `bin/ocaml/ocaml_merlin.ml` plus
lockdir/pkg lookups in `src/dune_rules/pkg_rules.ml`. That got
`dune ocaml-merlin` past the “not in dune workspace” failure, but it
still did not satisfy the real editor behavior.

From there the work split into two missing pieces:
- direct external-file queries needed a usable merlin config even though
  package sources do not get normal workspace merlin entries
- project-file goto-definition still opened
  `_build/_private/.../target/lib/...` instead of the real external
  source path

That led to the final branch-specific changes:
- no-build-safe lockdir reads from source lockdirs, not build-graph
  package resolution
- synthetic per-file merlin config for external package files from
  installed `dune-package` metadata
- merlin source dirs for package-managed local-source deps rewritten
  back to the real external source root

### What worked

- The final Dune-only direction did work.
- `dune ocaml-merlin` can now answer for the real external dependency
  file path directly.
- goto-definition from project code now opens the real external file
  path, not the package target path.
- follow-up definition inside the external file worked in the pinned
  editor flow.
- reopening the external file directly also worked.
- normal in-workspace navigation still worked.

### What did not work or misled me

- My first implementation used `Pkg_rules.all_project_deps` /
  `Lock_dir.get_exn`, which crashes in `dune ocaml-merlin`’s no-build
  path with the `Unexpected build progress state (expected [Building _])`
  internal error.
- I initially mapped external files to `.pkg/.../source/...`, but there
  are no usable merlin configs there.
- I then mapped them to `.pkg/.../target/lib/...`, which fixed direct
  queries but failed PR1’s real requirement because goto-definition
  still opened the synthetic build path.
- The stock headless `run.sh --headless` flow was too rigid for
  validation because it always runs the second action at the first
  definition site. That produced false negatives for “second action
  inside dependency file” until I reused the same harness config with a
  custom headless Lua script that moved the cursor to a meaningful
  symbol inside the dependency file.
- I also lost time on repo-wide `dune fmt` / `@check` invocations that
  were much broader than the PR1 acceptance signal.

### How I solved it

- I replaced build-graph package lookup with source-lockdir parsing via
  `Dune_pkg.Lock_dir.read_disk_exn`, guarded by `lock_dir_active`, so
  the path resolution stays safe in `dune ocaml-merlin`.
- I added reverse mapping from installed package lib dirs back to real
  external source roots and used that in merlin source-dir generation.
- I synthesized external-file merlin config from installed
  `dune-package` metadata in `src/dune_rules/merlin/merlin.ml`, with
  `bin/ocaml/ocaml_merlin.ml` loading that as a fallback.
- I validated with the new blackbox test plus pinned Neovim runs using
  the shared harness config and repo-built binaries.

### My view of the change

This is a real PR1 implementation, not a design sketch. It stays
Dune-only, preserves real external paths at the editor boundary, and
teaches Dune enough about package-managed local sources to answer
merlin queries for those files. It is still a fairly targeted solution:
it is specifically about local-source package deps represented in the
lockdir, not a general ownership model for arbitrary external files.

### Pros

- Dune-only
- real editor-visible paths
- works for direct external-file queries
- works for project-to-dependency navigation
- keeps the patch scoped to package-managed local sources
- has both blackbox and editor validation

### Cons

- more invasive than the very first path-translation idea
- adds merlin-specific fallback logic based on installed `dune-package`
  metadata
- validation needed a custom headless Lua driver on top of the shared
  harness because the stock scripted flow was too rigid
- I did not finish full repo-wide `dune fmt` or full `@check`;
  validation is targeted, not whole-tree

## Known Weakness

A realistic breakage is: jump into an external dependency file that uses
PPX syntax, then try to keep working in that file.

Concrete repro:
- make the external local-source package use a normal PPX such as
  `ppx_let`
- depend on that package from the workspace project
- run goto-definition from the workspace file into the dependency file
- once the editor opens the real external path, try hover, completion,
  diagnostics, or follow-up goto-definition there

What the user would see:
- the file opens at the correct real external path
- Merlin/LSP can report parse errors around PPX syntax
- hover/completion/follow-up navigation can be missing or wrong

Why this fails:
- the synthetic external-file Merlin config used by this branch is
  intentionally lossy
- it preserves path/module ownership, but drops preprocessing and reader
  details
- so the branch is strong on real-path ownership, but weaker on exact
  fidelity for PPX-heavy dependency files

### Dependency file relies on package compile flags

A realistic degraded workflow is: jump into an external dependency file
that depends on package compile flags, then try to keep using LSP there.

Concrete repro:
- make the external package depend on nontrivial compile flags or syntax
  extensions
- run goto-definition from the workspace into that external file
- try hover, completion, or diagnostics there

What the user would see:
- the file opens at the real external path
- analysis can be incomplete or wrong
- hover/completion/diagnostics can degrade

Why this fails:
- the current synthesized fallback preserves ownership better than exact
  per-package compile fidelity
- compile-flag-sensitive files need a richer Merlin payload than this
  branch currently reconstructs

### Navigation from the external file into its own dependency can fail

A realistic degraded workflow is: jump into an external dependency file,
then follow a second reference from that file into one of its own
dependencies.

Concrete repro:
- jump from the workspace into an external dependency file
- from inside that file, run goto-definition on a symbol that lives in
  one of that package's dependencies

What the user would see:
- the first jump works
- the second jump can fail or become unreliable

Why this fails:
- the branch reconstructs enough config for the package itself, but not
  the full transitive Merlin environment a normal workspace file would
  have
- so follow-up navigation into the dependency's own dependency graph is
  weaker

## Reproduction Steps

### PPX-heavy dependency file

1. Make the external local-source package use a PPX such as `ppx_let`.
2. Add a definition in the dependency file that uses the PPX syntax.
3. From the consumer project, jump to that definition with
   goto-definition.
4. In the opened dependency buffer, run hover or goto-definition again.

Expected result:
- The dependency file opens at the real external path and continues to
  behave like a normal project-owned file.

Actual result:
- The file opens at the real path, but Merlin/LSP can report parse
  errors or lose follow-up semantic features.

### Dependency file depends on compile flags

1. Make the external package rely on a normal compile flag such as
   `-open Base` or another implicit environment detail.
2. Reference a value that is only available because of that flag.
3. From the consumer project, jump into that external file.
4. Ask for hover, completion, or diagnostics in the opened file.

Expected result:
- The dependency file keeps the same compile environment it had when the
  package was built.

Actual result:
- The file opens, but hover/completion/diagnostics can show unbound
  names or weaker type information.

### Second hop into the dependency graph

1. Make the external package depend on another library.
2. From the consumer project, jump into the external dependency file.
3. In that file, run goto-definition on a symbol that comes from the
   dependency's own dependency.

Expected result:
- The second jump works as reliably as the first jump.

Actual result:
- The first jump works, but the second jump can fail or become weaker.

## Possible Fixes

### PPX and reader fidelity

The strongest fix is to stop reconstructing a lossy external-file Merlin
config from installed `dune-package` metadata and instead persist the
real processed Merlin config Dune already knows during package build.

Proposed approach:
- keep the real-path rewrite from this branch
- emit a serialized per-library Merlin config alongside package-managed
  local-source artifacts under `.pkg/...`
- include full flags, PPX config, reader, suffixes, hidden dirs,
  indexes, and parameters
- map the real external path back to that stored config instead of
  rebuilding it from `dune-package`

Feasibility:
- medium to medium-high
- Dune already has the needed information
- the harder part is choosing the persisted artifact format and how
  stable it should be

### Follow-up navigation into the dependency graph

The same persisted-config approach should also be the main fix here.

Proposed approach:
- persist the processed Merlin config for the package lib exactly as
  generated for the package-managed build-tree file
- at query time, rewrite only the package's own visible source dirs back
  to the real external source root
- leave dependency dirs, hidden dirs, indexes, flags, and opens intact

Feasibility:
- high if the persisted-config approach is adopted first
- low to medium if this branch keeps extending the current
  `dune-package`-based synthesizer instead

### Dependency file relies on package compile flags

Concrete repro:
- make the external local-source package compile with a normal library
  flag such as `-open Base` or `-open Import`
- write the dependency source file so it relies on that implicit open
- depend on the package from the workspace project
- run goto-definition from the workspace file into the dependency file,
  then wait for diagnostics or try hover/completion there

What the user would see:
- the dependency file opens at the correct real external path
- Merlin/LSP can immediately report unbound values or wrong types in the
  external file
- hover and completion in that file can degrade even though the package
  builds normally

Why this fails:
- the synthetic external-file Merlin config built by this branch drops
  package-specific compiler flags
- the fallback path keeps module ownership, but does not replay the
  package’s real compile environment
- so files that rely on normal `-open` or similar flags can look broken
  in the editor after the jump

### Navigation from the external file into its own dependency can fail

Concrete repro:
- make the external local-source package depend on another normal
  library, for example `base`, `stdio`, or a second local-source package
- reference a symbol from that dependency inside the external source
  file
- from the workspace project, run goto-definition into the external file
- once there, run goto-definition or hover on the referenced dependency
  symbol

What the user would see:
- the first jump from the workspace into the external file works
- the second jump from that external file into one of its own
  dependencies can fail, stop at interface-only information, or produce
  weaker type information than expected

Why this fails:
- the synthetic config for an external package file mainly reconstructs
  the current package’s own source and object directories
- it does not rebuild the full transitive Merlin environment that a
  normal in-workspace library gets
- so cross-library editor features from inside the external file are
  weaker than the initial project-to-dependency jump
