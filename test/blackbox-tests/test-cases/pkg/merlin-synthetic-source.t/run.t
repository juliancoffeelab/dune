Verify that package-managed dependency sources are exposed under Dune's
synthetic `.pkg/.../source` tree with usable Merlin configuration.

  $ mkdir external_sources actual
  $ cat >external_sources/dune-project <<EOF
  > (lang dune 3.11)
  > (package
  >  (name smoke_dep))
  > EOF
  $ cat >external_sources/dune <<EOF
  > (library
  >  (public_name smoke_dep)
  >  (name smoke_dep))
  > EOF
  $ cat >external_sources/smoke_dep.ml <<EOF
  > let message = "smoke dependency"
  > EOF
  $ cat >external_sources/smoke_dep.mli <<EOF
  > val message : string
  > EOF

  $ cd actual
  $ cat >dune-project <<EOF
  > (lang dune 3.20)
  > (package
  >  (name smoke-consumer)
  >  (depends smoke_dep)
  >  (allow_empty))
  > EOF
  $ mkdir app
  $ cat >app/dune <<EOF
  > (executable
  >  (name main)
  >  (libraries smoke_dep))
  > EOF
  $ cat >app/main.ml <<EOF
  > let () = print_endline Smoke_dep.message
  > EOF

  $ DUNE_ROOT=$(which dune_cmd | sed 's#/_build/.*##')
  $ dune=$DUNE_ROOT/_build/default/bin/main.exe
  $ make_lockdir
  $ make_lockpkg smoke_dep <<EOF
  > (version 0.0.1)
  > (source (copy $PWD/../external_sources))
  > (build (run $dune build --release --promote-install-file=true . @check @install))
  > EOF

  $ $dune build app/main.exe

The consumer's Merlin config should point at the synthetic source tree rather
than the installed target copy.

  $ FILE=$PWD/app/main.ml
  $ printf "(4:File%d:%s)" ${#FILE} "$FILE" | $dune ocaml-merlin \
  > | grep -o -E '_build/_private/default/.pkg/[^)]*/target/lib/smoke_dep|_build/_private/default/.pkg/[^)]*/source' \
  > | sanitize_pkg_digest smoke_dep.0.0.1 \
  > | dune_cmd subst "$PWD" '$TESTCASE_ROOT'
  _build/_private/default/.pkg/smoke_dep.0.0.1-DIGEST_HASH/target/lib/smoke_dep
  _build/_private/default/.pkg/smoke_dep.0.0.1-DIGEST_HASH/source

Querying Merlin for the synthetic dependency file path should also succeed.

  $ PKG_DIR=$(get_build_pkg_dir smoke_dep)
  $ FILE=$PWD/$PKG_DIR/source/smoke_dep.ml
  $ printf "(4:File%d:%s)" ${#FILE} "$FILE" | $dune ocaml-merlin \
  > | grep -o -E '_build/_private/default/.pkg/[^)]*/target/lib/smoke_dep|_build/_private/default/.pkg/[^)]*/source|ERROR' \
  > | sanitize_pkg_digest smoke_dep.0.0.1 \
  > | dune_cmd subst "$PWD" '$TESTCASE_ROOT'
  _build/_private/default/.pkg/smoke_dep.0.0.1-DIGEST_HASH/target/lib/smoke_dep
  _build/_private/default/.pkg/smoke_dep.0.0.1-DIGEST_HASH/source
