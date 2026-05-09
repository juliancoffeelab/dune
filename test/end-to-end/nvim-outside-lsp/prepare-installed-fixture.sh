#!/bin/sh

set -eu

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

abspath_dir() {
  path=$1
  mkdir -p "$path"
  (
    cd "$path"
    pwd -P
  )
}

[ $# -eq 2 ] || die "Usage: prepare-installed-fixture.sh DEST DUNE_BIN"

HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
FIXTURE_DIR=$HARNESS_DIR/fixture-installed
DEST=$(abspath_dir "$1")
DUNE_BIN=$2
CONSUMER_DIR=$DEST/consumer
EXTERNAL_DIR=$DEST/external
PREFIX_DIR=$DEST/prefix

[ -x "$DUNE_BIN" ] || die "Dune binary is not executable: $DUNE_BIN"

rm -rf "$CONSUMER_DIR" "$EXTERNAL_DIR" "$PREFIX_DIR"
cp -R "$FIXTURE_DIR/consumer" "$CONSUMER_DIR"
cp -R "$FIXTURE_DIR/external" "$EXTERNAL_DIR"

(
  cd "$EXTERNAL_DIR"
  "$DUNE_BIN" build @install >/dev/null
  "$DUNE_BIN" install --prefix "$PREFIX_DIR" >/dev/null
)

printf 'project=%s\n' "$CONSUMER_DIR"
printf 'file=%s\n' "app/main.ml"
printf 'line=%s\n' "1"
printf 'col=%s\n' "15"
printf 'after_line=%s\n' "3"
printf 'after_col=%s\n' "15"
printf 'ocamlpath=%s\n' "$PREFIX_DIR/lib"
