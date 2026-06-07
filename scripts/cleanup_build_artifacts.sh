#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR_INPUT="${1:-${APP_ROOT:-$(pwd)}}"
ROOT_DIR="$(cd "$ROOT_DIR_INPUT" && pwd -P)"
DRY_RUN="${DRY_RUN:-0}"
CLEAN_SWIFTPM_BUILD="${CLEAN_SWIFTPM_BUILD:-1}"
CLEAN_BUILD_DIR="${CLEAN_BUILD_DIR:-1}"
CLEAN_DIST_DIR="${CLEAN_DIST_DIR:-1}"
CLEAN_EXTRA_PATHS="${CLEAN_EXTRA_PATHS:-}"

if [[ "$ROOT_DIR" == "/" || "$ROOT_DIR" == "$HOME" ]]; then
  echo "Refusing to clean unsafe root: $ROOT_DIR"
  exit 1
fi

if [[ ! -f "$ROOT_DIR/Package.swift" ]]; then
  echo "Refusing to clean $ROOT_DIR because Package.swift was not found."
  exit 1
fi

candidate_paths=()

if [[ "$CLEAN_SWIFTPM_BUILD" == "1" ]]; then
  candidate_paths+=("$ROOT_DIR/.build")
fi

if [[ "$CLEAN_BUILD_DIR" == "1" ]]; then
  candidate_paths+=("$ROOT_DIR/build")
fi

if [[ "$CLEAN_DIST_DIR" == "1" ]]; then
  candidate_paths+=("$ROOT_DIR/dist")
fi

if [[ -n "$CLEAN_EXTRA_PATHS" ]]; then
  old_ifs="$IFS"
  IFS=':'
  for item in $CLEAN_EXTRA_PATHS; do
    if [[ -z "$item" ]]; then
      continue
    fi
    if [[ "$item" == /* || "$item" == "." || "$item" == ".." || "$item" == *"/.."* ]]; then
      echo "Refusing unsafe CLEAN_EXTRA_PATHS entry: $item"
      exit 1
    fi
    candidate_paths+=("$ROOT_DIR/$item")
  done
  IFS="$old_ifs"
fi

clean_path() {
  local path="$1"
  local parent
  local checked_path

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return
  fi

  parent="$(cd "$(dirname "$path")" && pwd -P)"
  checked_path="$parent/$(basename "$path")"

  case "$checked_path" in
    "$ROOT_DIR"/*)
      ;;
    *)
      echo "Refusing to clean path outside app root: $path"
      exit 1
      ;;
  esac

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN: rm -rf $path"
  else
    rm -rf "$path"
    echo "Removed: $path"
  fi
}

for path in "${candidate_paths[@]}"; do
  clean_path "$path"
done

echo "Build artifact cleanup complete: $ROOT_DIR"
