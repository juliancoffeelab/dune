# PR Notes

These comparative notes are intentionally kept in one shared file to
reduce bias in the per-path implementation briefs.

Everything in this file is hypothetical and exploratory. These are not
settled conclusions, and they should not be treated as acceptance
criteria. The real evaluation criteria are whether a path produces a
working patch and whether it works in the editor under the validation
steps described in `pr1.md` through `pr4.md`.

## Note For Human

This is how to build and try the experiment branches without installing
anything globally.

- Dune branch binary:
  from a Dune worktree, build `bin/main.exe`. In these experiments the
  branch-local launcher `dune.exe` still points at `_boot/dune.exe`, so
  the reliable pinned binary is usually
  `_build/default/bin/main.exe`.
- `ocaml-lsp` branch binary:
  from an `ocaml-lsp` worktree, run `dune build @install`. The pinned
  binary is then
  `_build/install/default/bin/ocamllsp`.
- Shared editor harness:
  `/home/codex/workspace/dune/test/end-to-end/nvim-outside-lsp/run.sh`
- Lockdir local-source scenario:
  use `--fixture <tmpdir>`.
- True outside installed-library scenario:
  use `--fixture-installed <tmpdir>`.

Example for `PR5`:

```sh
cd /home/codex/workspace/dune-pr-5
/home/codex/workspace/dune/_boot/dune.exe build bin/main.exe -j 1

cd /home/codex/workspace/ocaml-lsp-pr-5
dune build @install

tmp=$(mktemp -d)
/home/codex/workspace/dune/test/end-to-end/nvim-outside-lsp/run.sh \
  --fixture "$tmp" \
  --dune /home/codex/workspace/dune-pr-5/_build/default/bin/main.exe \
  --ocamllsp /home/codex/workspace/ocaml-lsp-pr-5/_build/install/default/bin/ocamllsp \
  --headless \
  --second definition \
  --expect-path '_build/_private/default/%.pkg/.+/source/smoke_dep%.ml$'
```

Example for `PR6`:

```sh
cd /home/codex/workspace/dune-pr-6
/home/codex/workspace/dune/_boot/dune.exe build bin/main.exe -j 1

cd /home/codex/workspace/ocaml-lsp-pr-6
dune build @install

tmp=$(mktemp -d)
/home/codex/workspace/dune/test/end-to-end/nvim-outside-lsp/run.sh \
  --fixture-installed "$tmp" \
  --dune /home/codex/workspace/dune-pr-6/_build/default/bin/main.exe \
  --ocamllsp /home/codex/workspace/ocaml-lsp-pr-6/_build/install/default/bin/ocamllsp \
  --headless \
  --second definition \
  --expect-path 'prefix/lib/extdep/extdep%.ml$'
```

## Execution Contract

Each path is expected to be explored as an implementation attempt, not
as a design-only exercise.

The supervising agent should:
- run one worker per path, using only that path's assigned worktree or
  worktree pair
- keep the worker going until it either produces a working patch or is
  demonstrably blocked
- resume or redirect a worker if it stops early
- review the resulting code directly rather than trusting the worker's
  summary
- verify that validation was actually run with the pinned repo-built
  binaries described in the per-path brief
- reject fake, weak, or partial validation, especially if the editor
  acceptance step was skipped
- send the worker back to continue if the patch is incomplete or the
  validation trail is not credible
- prefer surgical cleanup over full discard: add notes, remove broken
  pieces, or revert only the worker's bad validation scaffolding before
  considering a restart
- treat discarding the entire experiment in a worktree as a nuclear
  option, only after the path is truly stuck or the implementation and
  validation are too broken to salvage cleanly
- if a full restart is necessary, discard only that worker's experiment
  inside its own worktree and have it restart cleanly

Definition of done for any path:
- there is a working patch in the assigned repo or repos
- the patch has a concrete validation trail
- the validation uses repo-built binaries only
- the real Neovim smoke test was run against the correct binaries
- the resulting code passes final review

Validation is not complete if it only proves an internal API shape,
blackbox test, or direct `dune ocaml-merlin` probe. Those are screening
steps. The real pass/fail signal is whether the editor workflow works.

The shared editor harness lives in
`/home/codex/workspace/dune/test/end-to-end/nvim-outside-lsp`.
Workers should reuse that harness and vary only the pinned binaries,
worktree paths, and path-shape expectations required by their path.

## PR 1

**1. Dune-only: make external package source files directly queryable**
Dune would answer `ocaml-merlin` for installed dependency source paths
as-is.

Pros:
- Smallest conceptual change for `ocaml-lsp`
- If it works, `ocaml-lsp` may mostly just start working
- Keeps real filesystem paths, so editor UX is simple

Cons:
- Hardest Dune contract to make correct
- The same external file may need different configs depending on who
  depends on it
- Installed source layout and build layout do not naturally line up

## PR 2

**2. Dune-only: expose synthetic workspace-owned package source paths**
This is closest to the idea in
[dune#12860](https://github.com/ocaml/dune/issues/12860): make package
sources appear under some Dune-controlled tree, with matching build
artifacts/config.

Pros:
- Dune stays in control of path ownership
- Avoids “file is outside workspace” entirely
- More likely to fit the current Dune/Merlin model cleanly

Cons:
- Paths shown to editors may be synthetic rather than the original
  installed path
- You may need path rewriting when jumping/opening files
- More invasive on the Dune side than a simple API tweak

## PR 3

**3. Dune + ocaml-lsp: context-sensitive config API**
Dune exposes something like “config for external file `X` as seen from
source file/package `Y`”, and `ocaml-lsp` preserves the origin context
after goto-def.

Pros:
- Semantically the cleanest model
- Handles the real ambiguity problem honestly
- Keeps dependency files tied to the importing project’s world

Cons:
- Requires coordinated changes in both repos
- More state in `ocaml-lsp`
- Harder to make editor behavior predictable across reopen/session
  restore cases

## PR 4

**4. ocaml-lsp workaround: sticky borrowed context**
Without waiting for a richer Dune model, `ocaml-lsp` could treat
jumped-to external files as continuing under the source file’s config.

Pros:
- Fastest prototype
- Good way to test whether the UX is even worth pursuing
- Could solve a large chunk of the practical pain

Cons:
- Not a real ownership model
- Breaks down if the same dependency file is opened independently
- Likely brittle around multi-root workspaces and restarts

## PR 5

**5. Hybrid PR2+3: synthetic Dune-owned package paths plus explicit
origin context**

Pros:
- Keeps Dune in charge of path ownership, which avoids the raw
  outside-workspace lookup problem directly.
- Preserves same-session provenance like `PR3`, so reopened synthetic
  files can still borrow the project they came from.
- Worked in the editor with a synthetic `.pkg/.../source/...` path,
  which is closer to the original Dune-side issue framing than the
  real-path branches.
- Did not regress the true outside installed-library case in the
  secondary fixture.

Cons:
- The editor-visible path is still synthetic, so it is less natural for
  users than the real-path branches.
- The current implementation still keeps exact-file borrowed context in
  `ocaml-lsp`, so it inherits `PR3`-style ambiguity when the same file
  is reached from multiple origins.
- It is a two-repo change, not a Dune-only refinement.
- The focused `ocaml-lsp` test exists and compiles, but the usual
  `dune runtest ...` wrapper was not trustworthy in this environment, so
  the strongest proof is the real editor harness run.

## PR 6

**6. Hybrid PR1+3: real external paths plus explicit origin context**

Pros:
- Keeps the real external path visible to the editor, which is the most
  intuitive user-facing result.
- Uses provenance to strengthen `PR1`, so same-session reopen works
  better than a plain real-path reverse mapping.
- Worked in the editor in both the lockdir local-source case and the
  true installed outside-library case.
- Best matches “jump to the real file and keep going” as a user story.

Cons:
- Still needs coordinated Dune and `ocaml-lsp` changes.
- More moving pieces than `PR3` alone because it keeps the real-path
  reverse-mapping machinery from `PR1`.
- Still inherits provenance ambiguity if the same external file can be
  reached from multiple origins with different effective contexts.
- May still lose fidelity in harder PPX/reader/compile-flag cases if the
  fallback path has to reconstruct external-package config instead of
  reusing richer generated Merlin artifacts.
