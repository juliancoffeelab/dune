Test that `dune ocaml-merlin` accepts dependency source files coming from
package management local sources, and that origin context can still be
provided for the same real external path.

  $ mkdir -p external_sources
  $ cat > external_sources/dune-project <<EOF
  > (lang dune 3.20)
  > 
  > (package
  >  (name smoke-dep))
  > EOF
  $ mkdir -p external_sources/src
  $ cat > external_sources/src/dune <<EOF
  > (library
  >  (name smoke_dep)
  >  (public_name smoke-dep))
  > EOF
  $ cat > external_sources/src/smoke_dep.mli <<EOF
  > val message : string
  > EOF
  $ cat > external_sources/src/smoke_dep.ml <<EOF
  > let message = "from dependency"
  > EOF

  $ mkdir project
  $ cd project

  $ make_lockdir
  $ EXTROOT="$(cd .. && pwd)/external_sources"

  $ cat > main.ml <<EOF
  > let message =
  >   Smoke_dep.message
  > 
  > let () = print_endline message
  > EOF
  $ cat > dune-project <<EOF
  > (lang dune 3.20)
  > 
  > (package
  >  (name smoke-consumer)
  >  (depends smoke-dep))
  > EOF
  $ cat > dune <<EOF
  > (executable
  >  (name main)
  >  (libraries smoke-dep))
  > EOF

  $ cat > dune.lock/smoke-dep.pkg <<EOF
  > (version 0.0.1)
  > 
  > (source
  >  (copy $EXTROOT))
  > 
  > (build
  >  (run dune build --release --promote-install-file=true . @install))
  > EOF

  $ dune build @check

The real external source file should remain queryable as-is.
  $ FILE=$EXTROOT/src/smoke_dep.ml
  $ printf "(4:File%d:%s)" ${#FILE} $FILE | dune ocaml-merlin |
  > sed -E "s/[[:digit:]]+:/?:/g" | sed "s#$PWD#\$PWD#g" |
  > sed "s#$EXTROOT#\$EXTROOT#g" | tr '(' '\n' |
  > grep -E '\?:UNIT_NAME\?:smoke_dep\)'
  ?:UNIT_NAME?:smoke_dep))

The same real external path should also accept explicit origin context.
  $ MAIN=$PWD/main.ml
  $ printf "(4:File%d:%s7:Context%d:%s)" ${#FILE} $FILE ${#MAIN} $MAIN \
  > | dune ocaml-merlin \
  > | sed -E "s/[[:digit:]]+:/?:/g" | sed "s#$PWD#\$PWD#g" |
  > sed "s#$EXTROOT#\$EXTROOT#g" | tr '(' '\n' |
  > grep -E '\?:UNIT_NAME\?:smoke_dep\)'
  ?:UNIT_NAME?:smoke_dep))

The materialized package source inside `_build/_private/.../source/...` should
also remain queryable.
  $ FILE=$(find $PWD/_build/_private/default/.pkg -path '*/source/src/smoke_dep.ml' | head -n 1)
  $ printf "(4:File%d:%s)" ${#FILE} $FILE | dune ocaml-merlin |
  > sed -E "s/[[:digit:]]+:/?:/g" | sed "s#$PWD#\$PWD#g" |
  > tr '(' '\n' |
  > grep -E '\?:UNIT_NAME\?:smoke_dep\)'
  ?:UNIT_NAME?:smoke_dep))
