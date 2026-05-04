Show that `dune ocaml-merlin` can answer for an external file when given
workspace origin context.

  $ make_dune_project 3.20

  $ mkdir app1 app2
  $ cat > app1/dune <<'EOF'
  > (executable
  >  (name main1))
  > EOF
  $ cat > app2/dune <<'EOF'
  > (executable
  >  (name main2))
  > EOF

  $ touch app1/main1.ml app2/main2.ml

  $ dune build @check

  $ TARGET=/tmp/dune-pr3-external.ml
  $ MAIN1=$PWD/app1/main1.ml
  $ MAIN2=$PWD/app2/main2.ml

Without origin context, Dune rejects the external path.

  $ printf '(4:File%d:%s)' ${#TARGET} "$TARGET" | dune ocaml-merlin | grep -F 'not in dune workspace'
  ((5:ERROR185:Path /tmp/dune-pr3-external.ml is not in dune workspace ($TESTCASE_ROOT).))

With origin context, Dune borrows the requesting file's Merlin config.

  $ printf '(4:File%d:%s7:Context%d:%s)' ${#TARGET} "$TARGET" ${#MAIN1} "$MAIN1" \
  > | dune ocaml-merlin \
  > | dune format-dune-file \
  > | grep 'dune__exe__Main1' \
  > | sed 's/^[^:]*:[^:]*://'
  dune__exe__Main1))

  $ printf '(4:File%d:%s7:Context%d:%s)' ${#TARGET} "$TARGET" ${#MAIN2} "$MAIN2" \
  > | dune ocaml-merlin \
  > | dune format-dune-file \
  > | grep 'dune__exe__Main2' \
  > | sed 's/^[^:]*:[^:]*://'
  dune__exe__Main2))
