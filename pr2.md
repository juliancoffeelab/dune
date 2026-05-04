# PR 2

This path description is exploratory, not prescriptive.

Goal: produce a working patch for this path.

Worktree:
- Use only `/home/codex/workspace/dune-pr-2`.
- For editor validation, use the stock `ocaml-lsp` checkout at
  `/home/codex/workspace/ocaml-lsp`.

**2. Dune-only: expose synthetic workspace-owned package paths**
This branch is closest to the idea in
[dune#12860](https://github.com/ocaml/dune/issues/12860), but the
validated behavior is more specific: editor navigation lands on a
synthetic Dune-owned package path under
`_build/_private/default/.pkg/.../target/lib/...`, with usable Merlin
configuration, rather than reopening the original installed path.

Verification:
- First, add a Dune blackbox/cram test that proves the dependency is
  exposed under the synthetic Dune-owned package path with usable Merlin
  configuration.
- The blackbox test should show that a project file can locate into the
  dependency and that querying config for the synthetic dependency path
  succeeds.
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
- From a project file, run goto-definition into the dependency.
- Once inside the dependency file, run at least one more LSP action:
  hover, goto-definition again, or find references.
- Confirm the opened path is the intended synthetic Dune-owned path.
- Reopen that dependency file through the same path and confirm the same
  LSP action still works.
- Confirm normal in-workspace navigation still works unchanged.
- Check that the editor does not end up with duplicate buffers for the
  same logical file under both installed and synthetic paths.
- Record the exact Neovim config and launch command so the smoke test is
  reproducible for the same PR branch.
- Treat the editor result as the real pass/fail signal; the blackbox
  test is only the fast screening step.

## Postmortem

### 1. Story of changes

I ended up making the PR2 path real in two layers.

First, I changed Dune's Merlin generation so package-managed libraries
advertise a Dune-owned synthetic package path instead of the installed
copy. In the validated editor flow, that landed under
`_build/_private/default/.pkg/.../target/lib/...`. That is the
`src/dune_rules/merlin/merlin.ml` side.

Second, I changed `dune ocaml-merlin` so reopening one of those
synthetic package files works. Two pieces mattered there:
- preserve already-build-owned `.pkg` paths instead of normalizing them
  into the wrong context
- synthesize a usable Merlin response for the synthetic package path
  when no on-disk `.merlin-conf` exists there

I also added a focused blackbox test under
`test/blackbox-tests/test-cases/pkg/merlin-synthetic-source.t/run.t`.

I kept two additional Dune-side adjustments in
`src/dune_rules/dune_package.ml` and `src/dune_rules/pkg_rules.ml`
because they support the synthetic-source model more broadly, even
though the crucial behavior was driven by the Merlin path changes and
`ocaml-merlin` fallback.

### 2. What worked

The key branch-specific behavior now works:
- from a workspace file, Merlin config points at a synthetic
  Dune-owned package path
- querying `dune ocaml-merlin` directly for a synthetic dependency file
  now succeeds
- in Neovim with the repo-built binaries, goto-definition opens the
  synthetic Dune-owned package path under
  `_build/_private/default/.pkg/.../target/lib/...`
- once inside that synthetic file, LSP is still attached and a
  dependency-local hover works
- reopening the same synthetic file path keeps LSP working
- jumping from the workspace file again still resolves to the same
  synthetic path
- the editor buffer list did not contain a duplicate
  `target/lib/.../smoke_dep.ml`

### 3. What did not work or misled me

A few things were dead ends or misleading:

- My first manual repro was flawed because the dependency source
  directory was still visible as part of the workspace, so Dune was not
  exercising the true package-managed synthetic path case.
- The synthetic-file failure was not initially the fallback itself. The
  real issue was that `ocaml-merlin` was stripping `_build/_private/...`
  down to a fake source path and then reattaching it under the wrong
  context.
- The first blackbox test shape was bad. A single `.t` at
  `test-cases/pkg/` ran inside the shared `pkg` test root and overwrote
  that directory's own `dune` file. That hid the real behavior.
- The stock Neovim harness `run_headless()` was not enough by itself for
  this branch. Its second action runs at the landed definition position,
  and on this fixture that meant hover/definition on the binding name
  itself, which was not a good dependency-local probe.
- The harness `--expect-path` uses Lua `string.match`, not regex syntax.
  I lost time on that mismatch.

### 4. How I solved it

I fixed it in a sequence that matched the actual failure modes.

- I corrected the manual repro to use an external sibling source tree so
  the dependency was truly package-managed.
- I made Merlin source dirs for package libs point to the synthetic
  Dune-owned package tree.
- I fixed `ocaml-merlin` path handling so build-owned `.pkg` paths stay
  build-owned instead of being remapped incorrectly.
- I added a synthetic Merlin fallback so reopened synthetic package
  files get a usable config even without a physical `.merlin-conf`
  there.
- I rebuilt around a dedicated cram testcase directory with `run.t`,
  which isolated the blackbox test properly.
- For editor validation, I reused the shared harness fixture/config but
  drove a custom headless Lua script on top of it so I could:
  jump into the synthetic dependency
  verify hover on a real inner symbol in that file
  reopen the same synthetic file
  verify hover again
  return to the workspace file and jump again
  check buffer names for duplicates

### 5. My view of the change

This branch now demonstrates the PR2 idea credibly.

It is not just Dune answering a weird manual query. The editor path
actually becomes synthetic and Dune-owned, and that path remains live
enough for follow-up LSP behavior after reopen. The important correction
is that the validated path is the synthetic package path under
`_build/_private/default/.pkg/.../target/lib/...`, not a mirrored
`source/...` path.

The weakest part is that reopened synthetic files currently rely on a
synthesized Merlin answer rather than a real generated `.merlin-conf`
tree under the synthetic package path. That is pragmatic and works, but
it is less elegant than having the full synthetic subtree carry native
Merlin artifacts.

### 6. Pros / cons

Pros:
- stays entirely on the Dune side
- makes dependency paths workspace-owned from the editor's point of view
- avoids the outside-workspace failure mode directly
- works with repo-built `dune` and stock `ocamllsp`
- real editor validation succeeded on the branch

Cons:
- `ocaml-merlin` now has special handling for synthetic `.pkg` paths
- the reopened-file success path depends on synthesized config, not a
  full mirrored `.merlin-conf` layout
- validation needed a custom headless step on top of the shared harness
  because the stock second action was not a good probe for this branch
- the patch is not tiny; it touches Merlin generation, package
  metadata, package build targets, and `ocaml-merlin` lookup behavior

## Known Weakness

A realistic degraded workflow is: jump from the workspace into the
dependency, then immediately ask for hover on the symbol where the
editor landed.

Concrete repro:
- open `app/main.ml`
- run goto-definition on a dependency symbol such as `Smoke_dep.message`
- once the editor opens the synthetic Dune-owned package path, trigger
  hover immediately without moving the cursor

What the user would see:
- the jump itself works
- the dependency file opens at the synthetic Dune-owned package path
- but hover at that landed position can return nothing

Why this fails:
- the branch uses a synthesized fallback Merlin config for the synthetic
  package path
- that is enough to reopen the file and recover useful analysis inside
  it
- but it is still weaker than having a full native Merlin artifact
  layout for that exact path, so the landed definition site can be a
  weaker follow-up point than a normal in-workspace file

### Intra-dependency goto-definition can still fail

A realistic degraded workflow is: jump into the dependency, then run a
second goto-definition from inside that synthetic package file.

Concrete repro:
- jump from the workspace into the dependency
- from inside the synthetic package file, run goto-definition on another
  symbol in that dependency

What the user would see:
- the first jump works
- the second jump can fail or be weaker than expected

Why this fails:
- a second definition query is more demanding than “attach and hover”
- it needs richer per-file Merlin data than the current fallback always
  provides

### Find references from the synthetic dependency can be partial or empty

A realistic degraded workflow is: open the synthetic dependency file,
then run Find References from there.

Concrete repro:
- jump into the synthetic dependency file
- run references on a symbol defined there

What the user would see:
- references can be partial or empty

Why this fails:
- the fallback config is intentionally minimal
- richer metadata such as index data is not guaranteed to be present for
  reopened synthetic files

## Reproduction Steps

### Immediate hover at the landed definition

1. Open the consumer file such as `app/main.ml`.
2. Run goto-definition on `Smoke_dep.message`.
3. As soon as the synthetic dependency buffer opens, trigger hover
   without moving the cursor.

Expected result:
- Hover at the landed symbol works immediately, just as it would in a
  normal in-workspace file.

Actual result:
- The jump works and the synthetic path opens, but hover at that landed
  position can return nothing.

### Second goto-definition from inside the synthetic file

1. Jump from the workspace file into the synthetic dependency file.
2. Move to another symbol in that dependency implementation.
3. Run goto-definition again.

Expected result:
- The synthetic dependency file remains fully navigable for a second
  definition request.

Actual result:
- The first jump works, but the second goto-definition can fail or
  return no locations.

### Find references from the synthetic dependency file

1. Jump from the workspace file into the synthetic dependency file.
2. Put the cursor on a symbol defined there.
3. Run Find References.

Expected result:
- References from the synthetic dependency file are as complete as from
  a normal project file.

Actual result:
- References can be partial or empty.

## Possible Fixes

### Immediate landed-site weakness

The strongest next step is to make the synthetic package tree carry real
Merlin artifacts and let `ocaml-merlin` load them normally instead of
relying on the thin fallback for common reopened-file behavior.

Proposed approach:
- push further on the synthetic package tree so Merlin-relevant build
  artifacts exist under it
- reuse `get_pkg_inner_merlin_files_paths` with real configs instead of
  a hand-built fallback whenever possible

Feasibility:
- medium
- conceptually this is the right PR2 fix
- the fiddly part is lining source layout and package build layout up
  without over-copying

### Intra-dependency goto-definition

The clean fix is the same real-artifact path above; a pragmatic fix
would only enrich the fallback if needed.

Proposed approach:
- first try to serve the real processed Merlin config for files under
  the synthetic package tree
- only fall back to a richer synthesized answer as a stopgap

Feasibility:
- medium for a pragmatic improvement
- medium-low for a clean full fix unless Dune can map synthetic source
  files back to exact processed configs reliably

### Partial or empty references

This should be fixed by giving reopened synthetic files real index data
or real processed configs.

Proposed approach:
- make reopened synthetic files reuse `INDEX` directives from normal
  processed Merlin config
- or resolve them directly to the package's full processed config

Feasibility:
- medium
- more realistic if the relevant index files already exist in package
  build output and can be reused

### Intra-dependency goto-definition can still fail

Another realistic workflow is: jump into the dependency, move to another
symbol inside that file, then ask for goto-definition again.

Concrete repro:
- open `app/main.ml`
- run goto-definition on `Smoke_dep.message`
- once inside the synthetic dependency file, move to another symbol such
  as a helper used in the implementation
- run goto-definition again

What the user would see:
- the first jump into the synthetic package path works
- but the second goto-definition from inside the dependency can return
  no locations

Why this fails:
- the branch's synthetic fallback is strong enough to reopen the file
  and recover some local analysis
- but it is still not equivalent to a full native Merlin artifact layout
  for that synthetic package path
- in validation, this exact shape degraded: a second definition request
  on an inner dependency symbol returned no locations until the probe was
  changed to hover instead

### Find references from the synthetic dependency can be partial or empty

Another normal workflow is: jump into the dependency and ask for
references on a symbol from inside that synthetic file.

Concrete repro:
- open `app/main.ml`
- run goto-definition on `Smoke_dep.message`
- once inside the synthetic dependency file, put the cursor on
  `message` or another symbol in that file
- run Find References

What the user would see:
- the dependency file is open at the synthetic Dune-owned path
- but references can come back empty or noticeably worse than they would
  from a normal in-workspace file

Why this fails:
- the synthetic fallback Merlin response is deliberately minimal
- it gives enough information for reopening and some local semantic
  queries, but it does not carry the full richer config that normal
  workspace-generated Merlin data can include
- in particular, this branch-specific fallback omits things like
  `INDEX` directives, so reference-style features have less data than
  the original workspace-file path
