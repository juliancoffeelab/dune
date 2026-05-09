#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage:
  run.sh --fixture DIR --dune BIN --ocamllsp BIN [options]
  run.sh --fixture-installed DIR --dune BIN --ocamllsp BIN [options]
  run.sh --project DIR --file RELPATH --dune BIN --ocamllsp BIN [options]

Required:
  --dune BIN           Dune binary to use for build and watch
  --ocamllsp BIN       ocamllsp binary to use in Neovim

Fixture mode:
  --fixture DIR        Materialize the built-in sample project into DIR
  --fixture-installed DIR
                       Materialize and install the built-in outside
                       dependency project into DIR

Direct project mode:
  --project DIR        Project directory to test
  --file RELPATH       File to open, relative to --project

Options:
  --line N             1-based line for headless smoke actions
  --col N              1-based column for headless smoke actions
  --after-line N       1-based line for the second action after goto-def
  --after-col N        1-based column for the second action after goto-def
  --second ACTION      Second action: hover or definition
                       Default: hover
  --expect-path PAT    Expected Lua pattern for the opened definition path
  --headless           Run the scripted headless smoke flow
  --keep-temp          Keep temp logs and config after exit
  --help               Show this message

Fixture defaults:
  file: app/main.ml
  line: 2
  col: 3
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

abspath() {
  path=$1
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *)
      dir=$(dirname "$path")
      base=$(basename "$path")
      (
        cd "$dir"
        printf '%s/%s\n' "$(pwd -P)" "$base"
      )
      ;;
  esac
}

PROJECT=
FILE=
FIXTURE_DEST=
INSTALLED_FIXTURE_DEST=
DUNE_BIN=
OCAMLLSP_BIN=
LINE=
COL=
AFTER_LINE=
AFTER_COL=
SECOND_ACTION=hover
EXPECT_PATH=
HEADLESS=0
KEEP_TEMP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      PROJECT=$2
      shift 2
      ;;
    --file)
      FILE=$2
      shift 2
      ;;
    --fixture)
      FIXTURE_DEST=$2
      shift 2
      ;;
    --fixture-installed)
      INSTALLED_FIXTURE_DEST=$2
      shift 2
      ;;
    --dune)
      DUNE_BIN=$2
      shift 2
      ;;
    --ocamllsp)
      OCAMLLSP_BIN=$2
      shift 2
      ;;
    --line)
      LINE=$2
      shift 2
      ;;
    --col)
      COL=$2
      shift 2
      ;;
    --after-line)
      AFTER_LINE=$2
      shift 2
      ;;
    --after-col)
      AFTER_COL=$2
      shift 2
      ;;
    --second)
      SECOND_ACTION=$2
      shift 2
      ;;
    --expect-path)
      EXPECT_PATH=$2
      shift 2
      ;;
    --headless)
      HEADLESS=1
      shift
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[ -n "$DUNE_BIN" ] || die "Missing --dune"
[ -n "$OCAMLLSP_BIN" ] || die "Missing --ocamllsp"

case "$SECOND_ACTION" in
  hover|definition) ;;
  *) die "Invalid --second value: $SECOND_ACTION" ;;
esac

fixture_mode_count=0
[ -n "$FIXTURE_DEST" ] && fixture_mode_count=$((fixture_mode_count + 1))
[ -n "$INSTALLED_FIXTURE_DEST" ] && fixture_mode_count=$((fixture_mode_count + 1))
[ -n "$PROJECT" ] && fixture_mode_count=$((fixture_mode_count + 1))
if [ "$fixture_mode_count" -gt 1 ]; then
  die "Use only one of --fixture, --fixture-installed, or --project"
fi

load_fixture_metadata() {
  metadata=$1
  while IFS='=' read -r key value; do
    case "$key" in
      project) PROJECT=$value ;;
      file) FILE=${FILE:-$value} ;;
      line) LINE=${LINE:-$value} ;;
      col) COL=${COL:-$value} ;;
      after_line) AFTER_LINE=${AFTER_LINE:-$value} ;;
      after_col) AFTER_COL=${AFTER_COL:-$value} ;;
      ocamlpath) FIXTURE_OCAMLPATH=$value ;;
    esac
  done <<EOF
$metadata
EOF
}

FIXTURE_OCAMLPATH=
if [ -n "$FIXTURE_DEST" ]; then
  HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
  metadata=$("$HARNESS_DIR/prepare-fixture.sh" "$FIXTURE_DEST")
  load_fixture_metadata "$metadata"
fi

if [ -n "$INSTALLED_FIXTURE_DEST" ]; then
  HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
  metadata=$(
    "$HARNESS_DIR/prepare-installed-fixture.sh" \
      "$INSTALLED_FIXTURE_DEST" \
      "$DUNE_BIN"
  )
  load_fixture_metadata "$metadata"
fi

[ -n "$PROJECT" ] || die "Missing --project or --fixture"
[ -n "$FILE" ] || die "Missing --file"

if [ "$HEADLESS" -eq 1 ]; then
  [ -n "$LINE" ] || die "--headless requires --line"
  [ -n "$COL" ] || die "--headless requires --col"
fi

PROJECT=$(abspath "$PROJECT")
DUNE_BIN=$(abspath "$DUNE_BIN")
OCAMLLSP_BIN=$(abspath "$OCAMLLSP_BIN")
TARGET_FILE=$(abspath "$PROJECT/$FILE")
HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

[ -d "$PROJECT" ] || die "Project does not exist: $PROJECT"
[ -f "$TARGET_FILE" ] || die "Target file does not exist: $TARGET_FILE"
[ -x "$DUNE_BIN" ] || die "Dune binary is not executable: $DUNE_BIN"
[ -x "$OCAMLLSP_BIN" ] || die "ocamllsp binary is not executable: $OCAMLLSP_BIN"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dune-nvim-outside-lsp.XXXXXX")
WATCH_LOG=$TMP_ROOT/dune-watch.log
BUILD_LOG=$TMP_ROOT/dune-build.log
SMOKE_LOG=$TMP_ROOT/nvim-outside-lsp.log
XDG_CONFIG_HOME=$TMP_ROOT/xdg-config
XDG_DATA_HOME=$TMP_ROOT/xdg-data
XDG_STATE_HOME=$TMP_ROOT/xdg-state
XDG_CACHE_HOME=$TMP_ROOT/xdg-cache
mkdir -p \
  "$XDG_CONFIG_HOME" \
  "$XDG_DATA_HOME" \
  "$XDG_STATE_HOME" \
  "$XDG_CACHE_HOME"
ln -s "$HARNESS_DIR/nvim" "$XDG_CONFIG_HOME/nvim-outside-lsp"

WATCH_PID=
cleanup() {
  status=$?
  if [ -n "$WATCH_PID" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  if [ "$KEEP_TEMP" -eq 1 ]; then
    printf 'Kept temp dir: %s\n' "$TMP_ROOT" >&2
  else
    rm -rf "$TMP_ROOT"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

(
  cd "$PROJECT"
  OCAMLPATH=$FIXTURE_OCAMLPATH "$DUNE_BIN" build >"$BUILD_LOG" 2>&1
)

(
  cd "$PROJECT"
  OCAMLPATH=$FIXTURE_OCAMLPATH "$DUNE_BIN" build --watch >"$WATCH_LOG" 2>&1
) &
WATCH_PID=$!
sleep 2

export OCAMLLSP_BIN
export NVIM_APPNAME=nvim-outside-lsp
export SMOKE_EXPECT_PATH_REGEX=$EXPECT_PATH
export SMOKE_LOG
export SMOKE_SECOND_ACTION=$SECOND_ACTION
export XDG_CACHE_HOME
export XDG_CONFIG_HOME
export XDG_DATA_HOME
export XDG_STATE_HOME
export OCAMLPATH=$FIXTURE_OCAMLPATH

printf 'Project: %s\n' "$PROJECT"
printf 'Target file: %s\n' "$TARGET_FILE"
printf 'Build log: %s\n' "$BUILD_LOG"
printf 'Watch log: %s\n' "$WATCH_LOG"
printf 'Smoke log: %s\n' "$SMOKE_LOG"

if [ "$HEADLESS" -eq 1 ]; then
  export SMOKE_COL=$COL
  export SMOKE_LINE=$LINE
  export SMOKE_AFTER_COL=$AFTER_COL
  export SMOKE_AFTER_LINE=$AFTER_LINE
  nvim --headless "$TARGET_FILE" \
    "+lua require('nvim_outside_lsp').run_headless()" \
    +qa
else
  if [ -n "$LINE" ] && [ -n "$COL" ]; then
    cursor_cmd=$(printf 'call cursor(%s,%s)' "$LINE" "$COL")
    nvim "$TARGET_FILE" "+$cursor_cmd"
  else
    nvim "$TARGET_FILE"
  fi
fi
