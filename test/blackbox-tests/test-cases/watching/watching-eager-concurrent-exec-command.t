Demonstrate running "dune exec" concurrently with an eager rpc server.

  $ echo '(lang dune 3.18)
  > (package (name foo))' > dune-project
  $ echo '(executable (name foo) (public_name foo))' > dune
  $ echo 'let () = print_endline "foo"' > foo.ml
  $ touch README.md

Just watch the readme file so we don't accidentally build foo.exe before
testing the --no-build option:
  $ dune build README.md --watch &
  Success, waiting for filesystem changes...
  Success, waiting for filesystem changes...
  Success, waiting for filesystem changes...
  Error: Don't know how to build _build/install/default/bin/echo
  Had 1 error, waiting for filesystem changes...

Make sure the RPC server is properly started:
  $ dune rpc ping --wait
  Server appears to be responding normally

Demonstrate handling the --no-build option:
  $ dune exec --no-build ./foo.exe
  Error: Program './foo.exe' isn't built yet. You need to build it first or
  remove the '--no-build' option.
  [1]

Demonstrate running an executable from the current project:
  $ dune exec ./foo.exe
  foo

Demonstrate running a named executable from the current project:
  $ dune exec foo
  foo

Demonstrate running an executable from PATH:
  $ dune exec echo "bar"
  bar

Demonstrate trying to run exec in watch mode while another watch server is running:
  $ dune exec ./foo.exe --watch 2>&1 | tr '\n' ' ' | sed 's/(pid: [0-9]*)/(pid: PID)/'
  Error: Another instance of dune (pid: PID) has locked the _build directory. Refusing to start a new watch server until no other instances of dune are running. 
  [1]

Demonstrate running an executable via an absolute path:
  $ dune exec $(which echo) "baz"
  baz

  $ dune shutdown
  $ wait
