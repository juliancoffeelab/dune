Before, concurrent `dune exec` had two behaviors in [bin/exec.ml](/home/codex/workspace/dune/bin/exec.ml:193):

- `dune exec ./foo.exe` worked over RPC by asking the running server to `build` that file target.
- `dune exec foo` did not use Dune’s normal name resolution at all when another Dune held the lock. It warned and only searched `PATH`.

After, concurrent `dune exec` has an explicit RPC name-resolution step:

- `dune exec foo` asks the running server to resolve the program the same way Dune normally would.
- If the result is a Dune-managed executable, the client asks the server to build that target, then executes the resulting path.
- If the result is external, the client executes it directly with no fake build probe and no warning.

Files changed:

- [bin/exec.ml](/home/codex/workspace/dune/bin/exec.ml:193)
  Before: `In_path` in `build_prog_via_rpc_if_necessary` warned and used `Bin.which`.
  After: `In_path` calls the new `resolve-program` RPC, then either builds a returned target or runs an external path.

- [src/dune_rpc_impl/decl.mli](/home/codex/workspace/dune/src/dune_rpc_impl/decl.mli:19)
  Added the new private RPC declaration surface:
  - `Resolve_program.Request`
  - `Resolve_program.Response`
  - `resolve_program`

- [src/dune_rpc_impl/decl.ml](/home/codex/workspace/dune/src/dune_rpc_impl/decl.ml:57)
  Added the implementation of those RPC types and the request declaration.
  New types added:
  - `Resolve_program.Request.t`
  - `Resolve_program.Response.t`
  - `Resolve_program.Response.Resolution.t`
  - `Resolve_program.Response.Resolution.Build_path.t`

- [src/dune_rpc_impl/client.ml](/home/codex/workspace/dune/src/dune_rpc_impl/client.ml:3)
  Added `Request Decl.resolve_program` to the private RPC menu.

- [src/dune_rpc_impl/server.ml](/home/codex/workspace/dune/src/dune_rpc_impl/server.ml:357)
  Added the server handler for `Decl.resolve_program`.
  New function-shaped behavior added:
  - server-side resolver that reconstructs the build dir from `context + source_dir`
  - calls `Dune_rules.Super_context.resolve_program_memo`
  - returns either:
    - `Not_found`
    - `Found (In_build_dir { target; path })`
    - `Found (External path)`

- [src/dune_rpc_impl/dune](/home/codex/workspace/dune/src/dune_rpc_impl/dune:1)
  Added the `dune_rules` library dependency so the RPC server can resolve programs.

- [test/blackbox-tests/test-cases/watching/watching-eager-concurrent-exec-command.t](/home/codex/workspace/dune/test/blackbox-tests/test-cases/watching/watching-eager-concurrent-exec-command.t:1)
  Updated the fixture to define a package and a public executable.
  Added coverage for:
  - `dune exec foo`
  - `dune exec echo "bar"` without the old warning
  - adjusted watch output expectations

What was removed:

- No files were removed.
- No public CLI surface was removed.
- The old RPC fallback warning path for named executables was effectively replaced in `bin/exec.ml`.

Net effect:

- Before: RPC-mode `dune exec foo` was not semantically aligned with normal `dune exec foo`.
- After: RPC-mode `dune exec foo` resolves through Dune first, then falls back to external binaries cleanly.

Pros:

- It gives RPC-mode `dune exec foo` much closer semantic parity with normal `dune exec foo`.
- It removes the old PATH-only warning behavior for named executables.
- It avoids the install-bin probing hack, so PATH commands like `echo` no longer cause a fake build attempt first.
- It keeps the protocol narrow: one RPC call that only resolves a program, then existing `build` RPC handles the actual build.
- It preserves the important distinction between Dune-managed executables and external binaries.
- The response shape is explicit enough for the client to do the right thing without re-deriving build semantics locally.
- It is testable in the exact concurrent watch/RPC scenario that motivated the change.

Cons:

- It adds a new private RPC surface, which increases maintenance and versioning burden.
- The implementation depends on `dune_rules` from `dune_rpc_impl`, which increases coupling between the RPC server layer and the rule-resolution layer.
- The request/response types are a bit more complex than the old fallback path because they need to carry both logical target info and runnable path info.
- It still duplicates a small amount of execution flow on the client side: resolve first, then maybe build, then exec.
- The solution is only as correct as `Super_context.resolve_program_memo` in this RPC context; that turned out to be subtle, especially around path serialization.
- Because this is a private RPC, it is easier to evolve than a public API, but it is still another internal contract Dune must keep coherent.

In short: this is cleaner and more correct than the heuristic branch, but it is more invasive and introduces tighter architectural coupling.

The main trouble was that the obvious first implementation path was deceptively wrong in two different ways.

First, my earlier attempt at a resolver RPC used Dune rule-resolution machinery in a way that produced a generic server-side `Code_error`. The hard part was that the client only saw “server error,” so I had to narrow it down by reproducing under a watch server and then instrumenting the server enough to see the real failure. What I eventually found was a path-serialization bug: I was sending `_build/default/...` as if it were the internal build-path representation, and on the server that got misread as a context named `_build`. I solved that by changing the RPC contract to send `context + source_dir` and reconstruct the build dir server-side, and by returning both the build target string and the runnable absolute path for managed executables.

Second, the watch-mode test broke in a misleading way after I changed the fixture to use a public executable name. The problem was not the RPC code at all: the watch server was failing because a public executable requires package metadata, and the test project did not define a package. That made `dune exec ./foo.exe` hang because the watch server never had a successful build state. I solved that by updating the test fixture to declare a package in `dune-project`.

A smaller recurring trouble was output and formatting churn. `dune fmt` rewrote a few of the new expressions, and the watch test gained one extra “Success, waiting for filesystem changes...” line, so I had to rerun the full validation sequence after adjusting expectations.

What I solved:
- Replaced the PATH-only fallback for named executables in RPC mode with an explicit resolver RPC.
- Fixed the runtime `Code_error` by correcting how directory/path information is serialized across RPC.
- Kept PATH binaries like `echo` working cleanly without the old fake build probe.
- Added targeted test coverage for the concurrent watch/RPC case.
- Manually verified the real user workflow with the installed Dune binary.

What I did not solve:
- I did not eliminate the architectural coupling this introduces between `dune_rpc_impl` and `dune_rules`; that is an intentional tradeoff in this version.
- I did not design a more general reusable “program resolution service” beyond this private RPC for `dune exec`.

Main edge cases that can still bite us:

- Server/client environment mismatch.
  Resolution now happens on the server, but the final `execve` still runs with `Env.initial` on the client side in [bin/exec.ml](/home/codex/workspace/dune/bin/exec.ml:290). If the server’s context `PATH` or toolchain environment differs from the client process environment, Dune may resolve one binary but run it under a slightly different runtime environment.

- Mixed-version concurrent Dune processes.
  This adds a new private RPC method. If one Dune process knows `resolve-program` and the other does not, behavior can fail at RPC negotiation time instead of falling back gracefully. That is mostly an internal-version-skew issue.

- Name shadowing changes.
  Before, RPC-mode `dune exec foo` effectively preferred `PATH`. Now it prefers Dune resolution first, like direct mode. That is the correct semantics, but it can surprise anyone who had come to rely on the old broken behavior.

- Cross-context / toolchain subtleties.
  The resolver uses the selected Dune context to resolve binaries. If there are tricky host/target or lockdir-specific toolchain setups, this path now depends on that server-side context logic being correct in all those cases.

- Source-dir reconstruction assumptions.
  The RPC request now sends `context + source_dir` and reconstructs the build dir server-side in [server.ml](/home/codex/workspace/dune/src/dune_rpc_impl/server.ml:359). That fixed the `_build` serialization bug, but it still assumes the exec call is rooted in a normal source-backed directory shape.

- Resolve/build race.
  Resolution and build are two separate RPC steps. If the workspace changes between them, the resolved target may no longer match the final state. That is a normal race, but this design does not eliminate it.

- `--no-build` relies on returned path existence.
  For Dune-managed executables, `--no-build` now checks the absolute path returned by the server. If there is any oddity in how that path is materialized for a specific context/platform, the no-build behavior could be fragile.

- Windows/path-format issues.
  This change serializes source dirs, build targets, and absolute paths as strings over RPC. It is fine on the Unix path we tested, but Windows path handling is the kind of area where this sort of contract can hide bugs.

- Private vs public executable expectations.
  Users may still expect bare `dune exec foo` to find any executable named `foo`. This change improves RPC parity with direct mode, but it does not broaden semantics beyond what Dune normally resolves.

The biggest practical ones are the first three: env mismatch, version skew, and changed name-shadowing behavior.
