What I changed:

In [bin/exec.ml](/home/codex/workspace/dune/bin/exec.ml:193), I changed the RPC-side `dune exec NAME` path for `In_path` executables. Before, if another Dune process held the build lock, `exec` gave up on project resolution and only searched `PATH`. Now it:

- computes the installed-bin target for the name, like `_build/install/<context>/bin/<name>` at [bin/exec.ml](/home/codex/workspace/dune/bin/exec.ml:196)
- asks the running Dune server to build that target via the existing RPC `build` request at [bin/exec.ml](/home/codex/workspace/dune/bin/exec.ml:220)
- if that succeeds, runs the built executable at [bin/exec.ml](/home/codex/workspace/dune/bin/exec.ml:234)
- if the target is simply not a Dune-built executable, falls back to `PATH` at [bin/exec.ml](/home/codex/workspace/dune/bin/exec.ml:237)
- if there is a real build failure, it still reports the build error at [bin/exec.ml](/home/codex/workspace/dune/bin/exec.ml:239)

I also updated the regression test in [watching-eager-concurrent-exec-command.t](/home/codex/workspace/dune/test/blackbox-tests/test-cases/watching/watching-eager-concurrent-exec-command.t:3) to use a real public executable name and to assert both `dune exec foo` and `dune exec echo "bar"` under a running watch server. And I added your requested validation rule to [AGENTS.md](/home/codex/workspace/dune/AGENTS.md:150).

Why this approach:

I deliberately did not add a new RPC API for “resolve program”. I tried that route first, but it was more invasive and riskier around the running build system. The final version reuses the RPC mechanism Dune already has: “build this target”. That keeps the patch small and local.

Pros:
- Small surface area: one real behavior change in `bin/exec.ml`, no new protocol.
- Preserves existing direct semantics better for named public executables.
- Keeps `PATH` fallback for things like `echo`.
- Real build failures still surface as failures instead of being silently masked.
- Easy to reason about: “try Dune-installed bin target, otherwise use PATH”.

Cons:
- It is heuristic, not full name-resolution parity with direct `dune exec`.
  Direct mode uses Dune’s full resolution logic; this RPC mode now approximates it through install-bin targets.
- It only helps for names that map to installed/public executables. That is fine for `dune exec foo`, but not for private names, which direct `dune exec foo` does not support anyway.
- The running watch server logs the failed `_build/install/.../echo` build probe before the client falls back to `PATH`. That is why the test now expects those extra watch log lines at [watching-eager-concurrent-exec-command.t](/home/codex/workspace/dune/test/blackbox-tests/test-cases/watching/watching-eager-concurrent-exec-command.t:14).

Validation I ran:
- `./dune.exe fmt`
- `./dune.exe build @check`
- `./dune.exe runtest test/blackbox-tests/test-cases/watching/watching-eager-concurrent-exec-command.t`
- Manual repro with `_build/install/default/bin/dune`: watch server running, then `dune exec foo` => `foo`, `dune exec echo bar` => `bar`

A cleaner larger version would add an explicit RPC request for “resolve this program the same way `dune exec` would”.

Rough shape:
- Add a private RPC method like `resolve_program`.
- Request would carry:
  - context name
  - source/build-relative directory
  - program name
  - maybe resolution mode
- Response would carry:
  - resolved path
  - whether it is a managed Dune target
  - maybe the exact build target to request

Then RPC-mode `dune exec` would do:
1. call `resolve_program`
2. if it resolves to a managed target, ask the server to build it
3. exec the resolved path
4. if it resolves to external `PATH`, exec that directly

Pros:
- True semantic parity with direct `dune exec`
- No heuristic “try install bin target first”
- No noisy failed-build probe for `echo`
- More future-proof if Dune’s executable resolution rules evolve
- Reusable for other commands, not just `exec`

Cons:
- More moving parts
- New RPC API and versioning surface
- More code in `dune_rpc_impl`
- Easier to get wrong around build-system reentrancy, which is exactly what bit the first version I tried
- Higher maintenance cost for a fairly narrow bug

So the tradeoff is:
- current patch: pragmatic, small, good enough for the reported case
- explicit RPC resolver: architecturally cleaner, but meaningfully more invasive

If you want this to be upstream-quality long term, I’d expect maintainers to prefer the explicit RPC resolver eventually. For getting the bug fixed with low risk, the current approach is the better first step.
