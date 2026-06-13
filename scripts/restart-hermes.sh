#!/usr/bin/env bash
# Refresh the local Hermes checkout after a rebase, then restart Hermes services.
#
# Default behavior:
#   1. Ensure the repo venv exists.
#   2. Sync Python dependencies from uv.lock into that venv.
#   3. Rebuild the Desktop app only when Hermes' desktop content stamp is stale.
#   4. Restart all Hermes gateway processes.
#
# Usage:
#   bash scripts/restart-hermes.sh
#   bash scripts/restart-hermes.sh --force-desktop
#   bash scripts/restart-hermes.sh --clean-venv
#   bash scripts/restart-hermes.sh --no-desktop

set -euo pipefail

if [ -d /usr/bin ]; then
  case ":$PATH:" in
    *:/usr/bin:*) ;;
    *) PATH="/usr/bin:$PATH" ;;
  esac
fi

PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
SYNC=1
BUILD_DESKTOP=1
FORCE_DESKTOP=0
RESTART_GATEWAY=1
ALL_GATEWAYS=1
CLEAN_VENV=0

usage() {
  printf '%s\n' \
'Usage: bash scripts/restart-hermes.sh [options]' \
'' \
'Options:' \
'  --clean-venv       Delete and recreate ./venv before syncing dependencies.' \
'  --no-sync          Skip uv sync.' \
'  --no-desktop       Skip the desktop build check.' \
'  --force-desktop    Rebuild desktop even if the content stamp matches.' \
'  --no-gateway       Skip gateway restart.' \
'  --current-profile  Restart only the current profile'\''s gateway.' \
'  -h, --help         Show this help.' \
'' \
'Environment:' \
'  PYTHON_VERSION     Python version for venv creation. Default: 3.11'
}

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --clean-venv)
      CLEAN_VENV=1
      ;;
    --no-sync)
      SYNC=0
      ;;
    --no-desktop)
      BUILD_DESKTOP=0
      ;;
    --force-desktop)
      FORCE_DESKTOP=1
      ;;
    --no-gateway)
      RESTART_GATEWAY=0
      ;;
    --current-profile)
      ALL_GATEWAYS=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$REPO_ROOT/venv"

native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

python_exe() {
  if [ -x "$VENV_DIR/Scripts/python.exe" ]; then
    printf '%s\n' "$VENV_DIR/Scripts/python.exe"
  elif [ -x "$VENV_DIR/bin/python" ]; then
    printf '%s\n' "$VENV_DIR/bin/python"
  else
    return 1
  fi
}

hermes_exe() {
  if [ -x "$VENV_DIR/Scripts/hermes.exe" ]; then
    printf '%s\n' "$VENV_DIR/Scripts/hermes.exe"
  elif [ -x "$VENV_DIR/bin/hermes" ]; then
    printf '%s\n' "$VENV_DIR/bin/hermes"
  else
    return 1
  fi
}

run_hermes() {
  local hermes_bin python_bin

  if hermes_bin="$(hermes_exe)"; then
    "$hermes_bin" "$@"
    return
  fi

  python_bin="$(python_exe)" || die "Hermes entry point not found and venv Python is missing"
  "$python_bin" -m hermes_cli.main "$@"
}

cd "$REPO_ROOT"

command -v uv >/dev/null 2>&1 || die "uv is not on PATH"

case "$VENV_DIR" in
  "$REPO_ROOT"/venv) ;;
  *) die "refusing to manage unexpected venv path: $VENV_DIR" ;;
esac

if [ "$CLEAN_VENV" -eq 1 ] && [ -d "$VENV_DIR" ]; then
  log "Removing existing venv"
  rm -rf "$VENV_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
  log "Creating venv with Python $PYTHON_VERSION"
  uv venv "$VENV_DIR" --python "$PYTHON_VERSION"
fi

export UV_PROJECT_ENVIRONMENT
export VIRTUAL_ENV
UV_PROJECT_ENVIRONMENT="$(native_path "$VENV_DIR")"
VIRTUAL_ENV="$UV_PROJECT_ENVIRONMENT"

if [ "$SYNC" -eq 1 ]; then
  log "Syncing Python runtime from uv.lock"
  uv sync --extra all --locked
else
  log "Skipping dependency sync"
fi

if [ "$BUILD_DESKTOP" -eq 1 ]; then
  desktop_args=(desktop --build-only)
  if [ "$FORCE_DESKTOP" -eq 1 ]; then
    desktop_args+=(--force-build)
  fi

  log "Checking Desktop build"
  run_hermes "${desktop_args[@]}"
else
  log "Skipping Desktop build check"
fi

if [ "$RESTART_GATEWAY" -eq 1 ]; then
  gateway_args=(gateway restart)
  if [ "$ALL_GATEWAYS" -eq 1 ]; then
    gateway_args+=(--all)
  fi

  log "Restarting Hermes gateway"
  run_hermes "${gateway_args[@]}"
else
  log "Skipping gateway restart"
fi

log "Hermes refresh complete"
