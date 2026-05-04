Test that `dune ocaml-merlin` accepts dependency source files coming from
package management local sources.

  $ mkdir -p external_sources
  $ cat > external_sources/dune-project <<EOF
  > (lang dune 3.20)
  > 
  > (package
  >  (name smoke-dep))
  > EOF
  $ cat > external_sources/dune <<EOF
  > (library
  >  (name smoke_dep)
  >  (public_name smoke-dep))
  > EOF
  $ cat > external_sources/smoke_dep.mli <<EOF
  > val message : string
  > EOF
  $ cat > external_sources/smoke_dep.ml <<EOF
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

Project files should see the dependency source directory in their merlin config.
  $ FILE=$PWD/main.ml
  $ printf "(4:File%d:%s)" ${#FILE} $FILE | dune ocaml-merlin |
  > sed -E "s/[[:digit:]]+:/?:/g" | sed "s#$PWD#\$PWD#g" |
  > sed "s#$EXTROOT#\$EXTROOT#g" | tr '(' '\n' |
  > grep -F '?:S?:$EXTROOT)'
  ?:S?:$EXTROOT)

The dependency source file itself should now be directly queryable as-is.
  $ FILE=$EXTROOT/smoke_dep.ml
  $ printf "(4:File%d:%s)" ${#FILE} $FILE | dune ocaml-merlin |
  > sed -E "s/[[:digit:]]+:/?:/g" | sed "s#$PWD#\$PWD#g" |
  > sed "s#$EXTROOT#\$EXTROOT#g" | tr '(' '\n' |
  > grep -E '(\?:S\?:\$EXTROOT\)|\?:UNIT_NAME\?:smoke_dep\))'
  ?:S?:$EXTROOT)
  ?:UNIT_NAME?:smoke_dep))
