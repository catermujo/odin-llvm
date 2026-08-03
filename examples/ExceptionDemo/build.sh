#!/usr/bin/env bash

set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd -P)"
LLVM_ROOT="$(cd "$BASE/../.." && pwd -P)"

OUTPUT=""
if (($# > 0)) && [[ "$1" != -* ]]; then
  OUTPUT="$1"
  shift
fi

ODIN_ARGS=()
while (($# > 0)); do
  case "$1" in
    -out:*)
      [[ -z "$OUTPUT" ]] || {
        echo "Output specified more than once." >&2
        exit 1
      }
      OUTPUT="${1#-out:}"
      [[ -n "$OUTPUT" ]] || {
        echo "Missing output path." >&2
        exit 1
      }
      ;;
    -out | --output)
      [[ -z "$OUTPUT" ]] || {
        echo "Output specified more than once." >&2
        exit 1
      }
      shift
      (($# > 0)) || {
        echo "Missing output path." >&2
        exit 1
      }
      OUTPUT="$1"
      ;;
    --output=*)
      [[ -z "$OUTPUT" ]] || {
        echo "Output specified more than once." >&2
        exit 1
      }
      OUTPUT="${1#--output=}"
      [[ -n "$OUTPUT" ]] || {
        echo "Missing output path." >&2
        exit 1
      }
      ;;
    *) ODIN_ARGS+=("$1") ;;
  esac
  shift
done

relative_path() {
  local from="${1#/}"
  local to="${2#/}"
  local common=0
  local index
  local result=""
  local IFS=/
  local -a from_parts to_parts

  read -r -a from_parts <<<"$from"
  read -r -a to_parts <<<"$to"
  while ((common < ${#from_parts[@]} && common < ${#to_parts[@]})) &&
    [[ "${from_parts[common]}" == "${to_parts[common]}" ]]; do
    ((common += 1))
  done
  for ((index = common; index < ${#from_parts[@]}; index += 1)); do
    result+="../"
  done
  for ((index = common; index < ${#to_parts[@]}; index += 1)); do
    result+="${to_parts[index]}/"
  done
  result="${result%/}"
  printf '%s' "${result:-.}"
}

case "$(uname -m)" in
  arm64 | aarch64) LLVM_ARCH=arm64 ;;
  x86_64 | amd64) LLVM_ARCH=x64 ;;
  *)
    echo "ExceptionDemo requires a 64-bit arm64 or x86_64 host." >&2
    exit 1
    ;;
esac

case "$(uname -s)" in
  Darwin)
    LLVM_LIBRARY_DIR="$LLVM_ROOT/darwin_$LLVM_ARCH"
    RPATH_ORIGIN=@loader_path
    ;;
  Linux)
    LLVM_LIBRARY_DIR="$LLVM_ROOT/linux_$LLVM_ARCH"
    RPATH_ORIGIN='$ORIGIN'
    ;;
  *)
    echo "ExceptionDemo requires an Itanium/DWARF EH host (Darwin or Linux)." >&2
    exit 1
    ;;
esac

CXX="${CXX:-clang++}"
command -v "$CXX" >/dev/null 2>&1 || {
  echo "Missing C++ compiler: $CXX" >&2
  exit 1
}
command -v ar >/dev/null 2>&1 || {
  echo "Missing archiver: ar" >&2
  exit 1
}
command -v odin >/dev/null 2>&1 || {
  echo "Missing Odin compiler: odin" >&2
  exit 1
}

TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_DIR="$(mktemp -d "${TEMP_ROOT%/}/ExceptionDemo.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

TEMP_OUTPUT=false
if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$TEMP_DIR/ExceptionDemo"
  TEMP_OUTPUT=true
else
  case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
  esac
  OUTPUT_PARENT="$(dirname "$OUTPUT")"
  [[ -d "$OUTPUT_PARENT" ]] || {
    echo "Output directory does not exist: $OUTPUT_PARENT" >&2
    exit 1
  }
  OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
  OUTPUT="$OUTPUT_PARENT/$(basename "$OUTPUT")"
  case "$OUTPUT" in
    "$BASE" | "$BASE"/*)
      echo "Output must be outside source directory: $BASE" >&2
      exit 1
      ;;
  esac
  [[ ! -L "$OUTPUT" ]] || {
    echo "Refusing symlink output: $OUTPUT" >&2
    exit 1
  }
fi

LLVM_RELATIVE_DIR="$(relative_path "$(dirname "$OUTPUT")" "$LLVM_LIBRARY_DIR")"
LLVM_RPATH="$RPATH_ORIGIN/$LLVM_RELATIVE_DIR"
BRIDGE_OBJECT="$TEMP_DIR/exception_bridge.o"
BRIDGE_ARCHIVE="$TEMP_DIR/libexception_bridge.a"
BRIDGE_IMPORT="exception_demo_bridge:libexception_bridge.a"

"$CXX" -std=c++17 -O2 -fPIC -c "$BASE/exception_bridge.cpp" -o "$BRIDGE_OBJECT"
ar rcs "$BRIDGE_ARCHIVE" "$BRIDGE_OBJECT"
odin build "$BASE" \
  -out:"$OUTPUT" \
  -define:LLVM_LINK=shared \
  -collection:exception_demo_bridge="$TEMP_DIR" \
  -define:EXCEPTION_DEMO_BRIDGE_ARCHIVE="$BRIDGE_IMPORT" \
  -extra-linker-flags:"-Wl,-rpath,$LLVM_RPATH" \
  "${ODIN_ARGS[@]}"

if [[ "$TEMP_OUTPUT" == true ]]; then
  printf 'ExceptionDemo build verified with temporary output.\n'
else
  printf 'Built %s\n' "$OUTPUT"
fi
