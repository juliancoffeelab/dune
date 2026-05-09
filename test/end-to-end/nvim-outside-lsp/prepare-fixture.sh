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

escape_for_sed() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

[ $# -eq 1 ] || die "Usage: prepare-fixture.sh DEST"

HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
FIXTURE_DIR=$HARNESS_DIR/fixture
DEST=$(abspath_dir "$1")
PROJECT_DIR=$DEST/project
SOURCE_DIR=$DEST/external_sources

rm -rf "$PROJECT_DIR" "$SOURCE_DIR"
cp -R "$FIXTURE_DIR/project" "$PROJECT_DIR"
cp -R "$FIXTURE_DIR/external_sources" "$SOURCE_DIR"

SOURCE_ESCAPED=$(escape_for_sed "$SOURCE_DIR")
sed "s|__SMOKE_DEP_SOURCE__|$SOURCE_ESCAPED|g" \
  "$PROJECT_DIR/dune.lock/smoke-dep.0.0.1.pkg.in" \
  >"$PROJECT_DIR/dune.lock/smoke-dep.0.0.1.pkg"
rm "$PROJECT_DIR/dune.lock/smoke-dep.0.0.1.pkg.in"

printf 'project=%s\n' "$PROJECT_DIR"
printf 'file=%s\n' "app/main.ml"
printf 'line=%s\n' "2"
printf 'col=%s\n' "3"
printf 'after_line=%s\n' "3"
printf 'after_col=%s\n' "15"
