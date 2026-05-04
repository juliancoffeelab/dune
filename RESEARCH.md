# RESEARCH

Below are prior assistant messages and quoted issue material, copied
verbatim where requested.

## LSP After Jumping Into External Dependencies

Short answer: `go to definition` can jump from your project into a dependency source file, but full LSP support usually does not continue once that file is opened if it lives outside your workspace. A vendored dependency usually does solve that.

Why:
- Dune’s Merlin config for a workspace file includes dependency source dirs, including non-local libs via `Lib_info.src_dir`, so Merlin can locate definitions in dependency sources from the original file: [merlin.ml](/home/codex/workspace/dune/src/dune_rules/merlin/merlin.ml:661), [merlin.ml](/home/codex/workspace/dune/src/dune_rules/merlin/merlin.ml:679), [merlin.ml](/home/codex/workspace/dune/src/dune_rules/merlin/merlin.ml:763).
- `ocaml-lsp` then returns that located path directly as a URI: [definition_query.ml](/home/codex/workspace/ocaml-lsp/ocaml-lsp-server/src/definition_query.ml:19).
- But when the editor opens the target file, `ocaml-lsp` computes Merlin config from the target file’s own path, not from the source file you jumped from: [document.ml](/home/codex/workspace/ocaml-lsp/ocaml-lsp-server/src/document.ml:231), [merlin_config.ml](/home/codex/workspace/ocaml-lsp/ocaml-lsp-server/src/merlin_config.ml:253), [merlin_config.ml](/home/codex/workspace/ocaml-lsp/ocaml-lsp-server/src/merlin_config.ml:324).
- Dune only serves Merlin config for files inside its workspace. Its path handler rejects outside files: [for_handlers.ml](/home/codex/workspace/dune/src/dune_rpc_impl/for_handlers.ml:3), [ocaml_merlin.ml](/home/codex/workspace/dune/bin/ocaml/ocaml_merlin.ml:146). I verified this directly against the sibling `ocaml-lsp` checkout; Dune returned: `Path ... is not in dune workspace`.
- Internally, Dune’s per-file Merlin map is built only from workspace modules: [merlin.ml](/home/codex/workspace/dune/src/dune_rules/merlin/merlin.ml:788), [merlin.ml](/home/codex/workspace/dune/src/dune_rules/merlin/merlin.ml:809).

So the practical result is:
- Initial jump can work.
- Once you are in an installed/out-of-workspace dependency file, hover/completion/further goto-def/diagnostics often lose the right build context.
- Exception: if the target file is itself inside another real Dune project checkout, `ocaml-lsp` can treat that as a separate project. That is different from an installed dependency.

Vendoring:
- Yes, vendoring usually fixes this because the dependency becomes part of the same workspace. Dune explicitly supports vendored Dune projects: [vendored_dirs.rst](/home/codex/workspace/dune/doc/reference/dune/vendored_dirs.rst:6).
- Dune’s `@ocaml-index` test shows vendored projects are indexed and those indexes are returned in Merlin config: [project-indexation.t](/home/codex/workspace/dune/test/blackbox-tests/test-cases/ocaml-index/project-indexation.t/run.t:15), [project-indexation.t](/home/codex/workspace/dune/test/blackbox-tests/test-cases/ocaml-index/project-indexation.t/run.t:21), [project-indexation.t](/home/codex/workspace/dune/test/blackbox-tests/test-cases/ocaml-index/project-indexation.t/run.t:33).
- You still need artifacts built; for richer queries, keep `@ocaml-index` or `dune build --watch` current: [README.md](/home/codex/workspace/ocaml-lsp/README.md:124).

What would need to change:
- The smallest useful fix is in `ocaml-lsp`: when opening a file reached by locate, keep using the originating project’s Merlin/Dune context instead of recomputing config solely from the target file’s directory.
- A fuller Dune-side fix would require a new API like “give me Merlin config for external file `X` as seen from workspace file/context `Y`”. The current API is workspace-rooted and only has per-file data for workspace modules.
- Without one of those changes, out-of-workspace dependencies remain second-class for editor features, while vendored ones work because they stop being out-of-workspace.

If you want, I can turn this into a concrete design sketch for either the Dune-side API change or the `ocaml-lsp` side change.

## Prior Art

The OCaml prior art mostly falls into two buckets: `Merlin` first, then thin LSP frontends over Merlin.

Merlin predates LSP and is still the real analysis engine. Its own docs say it works best with Dune after you run `dune build`, and for non-Dune builds it needs manual project config (`.merlin`) rather than discovering arbitrary external files itself. See Merlin’s site and repo: https://ocaml.github.io/merlin/ and https://github.com/ocaml/merlin. `ocaml-language-server` was explicitly a wrapper over existing tooling rather than a new semantic engine, and Reason’s old `reason-language-server` explicitly contrasted itself with that Merlin-based approach rather than adding a general build-graph model. See https://www.npmjs.com/package/ocaml-language-server and https://npm.io/package/%40jaredly/reason-language-server. So the prior art in OCaml is not “every file belongs to a global package graph”; it is “opened file asks some project-local tool for config”. That is also what current `ocaml-lsp` does through Dune in [merlin_config.ml](/home/codex/workspace/ocaml-lsp/ocaml-lsp-server/src/merlin_config.ml:324), and what Dune enforces by rejecting files outside the workspace in [for_handlers.ml](/home/codex/workspace/dune/src/dune_rpc_impl/for_handlers.ml:3) and [ocaml_merlin.ml](/home/codex/workspace/dune/bin/ocaml/ocaml_merlin.ml:146).

`rust-analyzer` is the cleanest contrast. It models the world from Cargo metadata, not from “is this file under my workspace root?”. Cargo exposes the package/dependency graph to tools via `cargo metadata`, and rust-analyzer refreshes project info from that and runs build scripts for better analysis; it also loads stdlib source via `rust-src`. That means dependency source files are just more crates with known manifests and source roots, so jumping into them and continuing to navigate is natural. Sources: Cargo metadata docs https://doc.rust-lang.org/cargo/reference/external-tools.html and https://doc.rust-lang.org/cargo/commands/cargo-metadata.html, plus rust-analyzer config/installation docs https://rust-analyzer.github.io/book/configuration and https://rust-analyzer.github.io/book/installation.html.

`Pyright` and `basedpyright` are similar in spirit, but the unit is the Python execution environment rather than a package-manager workspace. Their import resolver searches workspace code, configured extra paths, then installed packages in `site-packages`, preferring stubs, inline `.pyi`, `py.typed` packages, and finally library implementation code if allowed. So an imported dependency file is still in the same semantic environment because the interpreter/import path defines ownership, not the editor workspace boundary. That is why “jump into dependency and keep going” is usually fine there. Sources: Pyright config/import resolution docs https://github.com/microsoft/pyright/blob/main/docs/configuration.md?plain=1 and https://raw.githubusercontent.com/microsoft/pyright/main/docs/import-resolution.md, plus basedpyright’s corresponding docs https://docs.basedpyright.com/latest/usage/import-resolution/.

`clangd` is the closest analogue to the Dune/Merlin problem. It is fundamentally per-file compile-command driven. If you open a header with no direct compile command, clangd tries to borrow the includer’s command; but for headers outside the project, it often falls back to a generic command and loses important flags. Its background index and remote/static index help symbol lookup, but they do not fully solve per-file parse context for arbitrary external headers. That is much closer to the current OCaml situation than rust-analyzer or pyright. Sources: https://clangd.llvm.org/design/compile-commands, https://clangd.llvm.org/design/indexing, and https://clangd.llvm.org/guides/system-headers.

So the pattern across ecosystems is:

- Rust/Python: dependency files are first-class members of a global semantic graph exposed by Cargo or the interpreter/import system.
- Clangd/OCaml today: dependency navigation can work, but opened external files often need borrowed or synthetic config, and that is where things get brittle.

If you want the OCaml side to behave more like rust-analyzer or pyright, the design shift is: stop keying analysis solely off “opened file must live in this workspace”, and instead attach opened dependency files to an owning package/build context. A weaker version, closer to clangd, would be: when a file was reached from file `A`, keep analyzing it under `A`’s config unless/until a better owner is known.

## JS/TS

JS/TS is much closer to Rust/Python than to current Dune+Merlin.

`tsserver` models a file as belonging to a project, and if there’s no `tsconfig.json` it creates an inferred project that includes transitive imports. It is not fundamentally “workspace root only”. See the TypeScript server wiki: https://github.com/microsoft/TypeScript/wiki/Standalone-Server-%28tsserver%29

What that means in practice:

- If you import a package, TypeScript resolves it through real `node_modules` lookup rules, including `package.json` metadata and `@types` packages: https://www.typescriptlang.org/docs/handbook/modules/reference
- For a runtime JS target, TypeScript first tries to find a `.ts`/`.tsx`/`.d.ts`-style type-side file before falling back to `.js`: https://www.typescriptlang.org/docs/handbook/modules/reference.html
- So “go to definition into a dependency” usually works, because the dependency is part of the same module graph, not an alien file outside the project.

The important wrinkle is where you land:

- Very often you land in `.d.ts`, not the original source. That is deliberate. With project references, TS explicitly says imports from a referenced project load its output declaration file: https://www.typescriptlang.org/docs/handbook/project-references
- If you want “jump past `.d.ts` to the original `.ts`”, the normal mechanism is `declarationMap`; TS docs say it maps `.d.ts` back to original `.ts` and enables editors to go to original source: https://www.typescriptlang.org/tsconfig/declarationMap.html
- There is also an explicit “Go to Source Definition” command in the LSP wrapper around tsserver: https://github.com/typescript-language-server/typescript-language-server

So the JS/TS prior art is:

- Ownership comes from the import/package graph.
- Dependencies are first-class if they are resolvable through Node/bundler semantics.
- The main compromise is “definition may be declaration-facing first, source-facing second”.

That is much better than current OCaml here, because TS doesn’t require the opened dependency file to live under the same source root. It only requires that the dependency be in the module-resolution universe of the importing file.

Two notable caveats:

- If a package publishes only declarations, there may be no source to jump to. Then `.d.ts` is the best possible answer.
- In monorepos, TS docs recommend real workspaces/symlinked `node_modules` over fake `paths` aliases for package-to-package deps, because that keeps TypeScript and the runtime using the same resolution model: https://www.typescriptlang.org/docs/handbook/modules/reference

So if you were looking for a model OCaml could imitate, JS/TS’s answer is basically: “bind external files to an owning import/package graph, and separate declaration navigation from source navigation with extra metadata like declaration maps.”

## Existing Issues

Yes. As of May 1, 2026, I found one very direct current Dune issue and one older direct `ocaml-lsp` issue, plus a few nearby ones.

Most relevant:
- Dune: [#12860 pkg: provide Merlin/LSP configuration for navigating packages sources](https://github.com/ocaml/dune/issues/12860), opened December 4, 2025.
  This is basically your question verbatim. The description says that after jumping into an external library’s source, Merlin/LSP runs in a degraded mode because the proper config and artifacts are unavailable.
- OCaml-LSP: [#356 Using ocamllsp within opam dependencies](https://github.com/ocaml/ocaml-lsp/issues/356), opened December 25, 2020.
  The issue asks whether `ocamllsp` can work on files in opam dependencies after go-to-definition into an external library.

Nearby but not exactly the same:
- OCaml-LSP: [#1187 Jump to definition request fails with Merlin "Several source files in your path" error](https://github.com/ocaml/ocaml-lsp/issues/1187), opened September 23, 2023.
  This is about navigating into installed dependency code and Merlin getting confused among multiple matching files.
- OCaml-LSP: [#1582 Symbolic link directories interfere with go-to-definition and find-all-references functionality](https://github.com/ocaml/ocaml-lsp/issues/1582), opened January 14, 2026.
  Different trigger, but same general class: path identity/context mismatch breaks navigation and references once paths stop lining up cleanly.
- OCaml-LSP: [#453 No config found for file ... in ".". Try calling dune build](https://github.com/ocaml/ocaml-lsp/issues/453), opened May 24, 2021.
  Not the same bug. It turned out to be an environment/sandbox problem, so I would not treat it as prior art for the dependency-navigation issue.

My read:
- `ocaml-lsp` has had the user-facing request on file since December 25, 2020: [#356](https://github.com/ocaml/ocaml-lsp/issues/356).
- Dune now has the first issue I found that frames the real fix at the build-system/configuration layer, on December 4, 2025: [#12860](https://github.com/ocaml/dune/issues/12860).
- I did not find an older Dune issue that matches this exact “jump into external dependency, then LSP degrades because config is missing” problem as directly as [#12860](https://github.com/ocaml/dune/issues/12860).

If you want, I can next map these issues to the concrete code paths we inspected and suggest which repo is the better place for a new issue or design comment.

## Recommended OCaml LSP

Recommended, today: `ocaml-lsp-server` / `ocamllsp`.

That’s the one the official OCaml docs point people to, and it’s the official `ocaml/ocaml-lsp` project. The docs also say it uses Merlin under the hood. Sources:
- https://ocaml.org/docs/set-up-editor
- https://github.com/ocaml/ocaml-lsp

How many are there depends on what you count.

If you mean “general-purpose OCaml LSPs you should realistically use in 2026”:
- `1`: `ocaml-lsp-server`

If you include the underlying non-LSP engine:
- `Merlin`: still very important, but it is not itself the recommended general LSP. Official docs even say that for Vim they often talk to Merlin directly rather than through LSP.
- Source: https://ocaml.org/docs/set-up-editor and https://ocaml.github.io/merlin/

If you include historical/obsolete OCaml-family LSP servers:
- `ocaml-language-server`
- `reason-language-server`

Those both still exist on package pages, but their last published releases I found are about 7 years old, so I would treat them as historical, not current recommendations:
- https://www.npmjs.com/package/ocaml-language-server
- https://npm.io/package/%40jaredly/reason-language-server

So the short version is:

- Use `ocaml-lsp-server`.
- Think of `Merlin` as the analysis backend / direct editor integration for some setups.
- Ignore `ocaml-language-server` and `reason-language-server` unless you are dealing with old tooling.

If you want, I can also tell you the recommended setup per editor right now: VS Code, Neovim, Emacs, or Vim.

## Which Repo Owns The Fix

Yes, if the fork is `dune`, that’s the right primary place.

The core limitation is that Dune owns the Merlin config/build context, and today it only serves that for files inside the workspace. `ocaml-lsp` is mostly consuming that information. So for a real fix to “jump into external dependency source and keep full LSP behavior”, Dune is the repo that needs the new capability.

The split is roughly:

- `dune`: real fix
  Needs an API/model for “external file X, as seen from project/package context Y”.
- `ocaml-lsp`: possible workaround or follow-up
  It could preserve the originating context after goto-def, but that’s still a partial solution unless Dune can actually answer the config question for those files.

So if the goal is a proper upstreamable solution, `dune` is the right fork. If the goal is a fast local experiment, `ocaml-lsp` is also worth patching, but I would treat that as secondary.

If you cloned `dune`, yes.

If you only cloned `ocaml-lsp`, that’s useful for tracing behavior, but it’s probably not the main fork for the real fix. The likely ownership is:

- `dune`: expose enough project/package context for external dependency files
- `ocaml-lsp`: optionally thread the originating context through goto-def/opened-file handling

So for implementation work, `dune` is the right repo to have cloned first. If you want to prototype both sides, keeping a sibling `ocaml-lsp` checkout is still useful.

`dune`. This checkout is the right one for the real fix.

The sibling `ocaml-lsp` clone was still useful to confirm behavior end to end, but the primary fork should be this repo.

## Is Dune-Only Enough

Not automatically.

If Dune changed in the strong enough way, then yes, `ocaml-lsp` could start working without much or any change. But that depends on what kind of Dune fix we mean.

Two cases:

1. `Dune` learns how to answer `ocaml-merlin` for those external files by path alone.
In that case, `ocaml-lsp` probably would mostly “just work”, because it already asks Dune for config for the file being opened in [merlin_config.ml](/home/codex/workspace/ocaml-lsp/ocaml-lsp-server/src/merlin_config.ml:324).

2. `Dune` adds a context-sensitive API like “give me config for external file `X` as seen from project/package `Y`”.
In that case, `ocaml-lsp` would need changes, because today it does not pass that kind of origin context. It just opens the target file and asks for config based on that file’s own path, via [document.ml](/home/codex/workspace/ocaml-lsp/ocaml-lsp-server/src/document.ml:231) and [merlin_config.ml](/home/codex/workspace/ocaml-lsp/ocaml-lsp-server/src/merlin_config.ml:253).

So the precise answer is:

- `Dune` is the main place the real capability is missing.
- `ocaml-lsp` might work “magically” only if the Dune fix preserves the current calling convention.
- If the right Dune fix requires extra context, `ocaml-lsp` will also need a patch.

My guess is the clean design is:
- first fix `Dune` to define the model and API,
- then make a small `ocaml-lsp` patch if the new API needs origin/package context.

So: “Dune-only” is possible, but not guaranteed.

## Issue Threads And Notable Comments

What the existing issues suggest is fairly consistent:

- In `ocaml-lsp`, this was treated as a real limitation as early as December 25, 2020, not user error. In [ocaml-lsp#356](https://github.com/ocaml/ocaml-lsp/issues/356), Rudi Grinberg (`rgrinberg`) replied: “Not possible at the moment. Once we have dune integration, it should be possible to start addressing this.” That strongly suggests the maintainers saw Dune as the missing layer, not LSP alone.
- By September 23, 2023, [ocaml-lsp#1187](https://github.com/ocaml/ocaml-lsp/issues/1187) showed a more concrete symptom: jumping into installed libs could fail because Merlin saw multiple same-named source files in the search path. Vincent Laviron / `voodoos` reproduced it on September 25, 2023 and said he’d look into it. That suggests some failures are surface-level `ocaml-lsp`/Merlin behavior, but still in the general family of “dependency source context/path resolution is wrong or ambiguous.”
- By December 4, 2025, the problem had been reframed explicitly in Dune in [dune#12860](https://github.com/ocaml/dune/issues/12860): Dune package management may finally provide enough information to make installed dependency sources behave more like vendored code. That issue has no comments yet, but the issue body itself is the clearest current design direction.
- [ocaml-lsp#1582](https://github.com/ocaml/ocaml-lsp/issues/1582), opened January 14, 2026, is not the same bug, but it points the same way: path identity matters a lot, and once the file path no longer matches the project’s notion of ownership, navigation and references degrade.

Notable OCaml-community voices I found on this exact topic:

- Rudi Grinberg in [ocaml-lsp#356](https://github.com/ocaml/ocaml-lsp/issues/356#issuecomment-751315130): direct maintainer confirmation that this was not supported, and that Dune integration was the expected prerequisite.
- `voodoos` in [dune#12860](https://github.com/ocaml/dune/issues/12860): not a comment, but an issue opened by a Dune collaborator explicitly proposing that Dune package management should provide Merlin/LSP config for installed package sources, possibly by exposing package `_build` structure in a source-oriented way.
- `voodoos` again in [ocaml-lsp#1187](https://github.com/ocaml/ocaml-lsp/issues/1187): he first checked whether the project had been built, then reproduced the bug and took ownership of investigating. That suggests maintainers still see some of the observed behavior as `ocaml-lsp`/Merlin bugs, even if the bigger missing capability is on the Dune side.
- Rachit Nigam in [ocaml-lsp#1187](https://github.com/ocaml/ocaml-lsp/issues/1187#issuecomment-2781681875), on April 6, 2025, said he was still hitting the same issue and even tried `dune pkg lock`, which is a useful signal that users already expect Dune package management to help here.

My read is:

- The old `ocaml-lsp` issue suggests “this needs Dune support first.”
- The newer Dune issue suggests “Dune package management may now make that support feasible.”
- I did not find a richer public maintainer thread yet where they settled the exact API shape.

If you want, I can do one more pass and pull out the likely owners by repo, for example “who in Dune vs `ocaml-lsp` has commented most on Merlin/editor integration,” so you know who to CC on a design issue or PR.

## Verbatim Issue Material

### dune#12860

Title:

`pkg: provide Merlin/LSP configuration for navigating packages sources`

Body:

> Having OCaml editor support when navigating installed libraries' sources has been a recurring request from the community for years. There is no doubt that this request will be made again, and it's possible that having Dune Pkg Management could finally be the key to answer it.
>
> The current situation: you navigate your project's code and jump to the definition of some value that comes from an external library. This can be useful to better understand an undocumented API or to estimate the algorithmic complexity of a function for example. But once you reached the source for that external value, Merlin and LSP will run in a very degraded mode, because they don't have the proper configuration and artifacts available.
>
> This happens because the Merlin configuration generated by Dune (or another build system) are not installed along with the artifacts and cmi. Additionally, it wouldn't be enough to install these files, since the topology of installed artifacts is often different from the actual build directory organization.
>
> But now that Dune handles package itself, it looks like we should have all the information we need to actually provide this behavior, in a similar way as if the dependencies were vendored in the project.
>
> I don't know of it's feasibility or drawbacks, but I think a naive approach would be to have the `_build` folder of packages linked inside their `_build/_private/.pkg/xxxxx/source` folder (and slightly modify the generated confs to point Merlin to these source files instead of the ones in the `target` directory).

### ocaml-lsp#356

Title:

`Using ocamllsp within opam dependencies`

Body:

> Is there any way to get ocamllsp to work on files in opam dependencies (specifically, when I go-to-definition to an external library, I'd like to be able to jump around inside that library)?

Rudi Grinberg answer:

> Not possible at the moment. Once we have dune integration, it should be possible to start addressing this.
