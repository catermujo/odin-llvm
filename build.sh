#!/usr/bin/env bash

set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd -P)"
SOURCE_DIR="$BASE/llvm-project"
REMOTE="${LLVM_REPOSITORY:-https://github.com/llvm/llvm-project.git}"
REVISION="llvmorg-22.1.8"
REVISION_COMMIT="ca7933e47d3a3451d81e72ac174dcb5aa28b59d1"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

require_file() {
    [ -f "$1" ] || {
        echo "Missing LLVM build artifact: $1" >&2
        exit 1
    }
}

verify_source() {
    local dirty head tag_commit

    git -C "$SOURCE_DIR" show-ref --verify --quiet "refs/tags/$REVISION" || {
        echo "LLVM source is missing required tag $REVISION" >&2
        exit 1
    }
    tag_commit="$(git -C "$SOURCE_DIR" rev-parse --verify "refs/tags/$REVISION^{commit}")" || {
        echo "Could not resolve LLVM tag $REVISION" >&2
        exit 1
    }
    [ "$tag_commit" = "$REVISION_COMMIT" ] || {
        echo "LLVM tag $REVISION resolves to $tag_commit, expected $REVISION_COMMIT" >&2
        exit 1
    }
    head="$(git -C "$SOURCE_DIR" rev-parse --verify HEAD)" || {
        echo "Could not resolve LLVM source HEAD" >&2
        exit 1
    }
    [ "$head" = "$REVISION_COMMIT" ] || {
        echo "LLVM source HEAD is $head, expected $REVISION ($REVISION_COMMIT)" >&2
        exit 1
    }
    dirty="$(git -C "$SOURCE_DIR" status --porcelain=v1 --untracked-files=all)" || {
        echo "Could not inspect LLVM source status" >&2
        exit 1
    }
    [ -z "$dirty" ] || {
        echo "LLVM source is dirty; refusing to build:" >&2
        printf '%s\n' "$dirty" >&2
        exit 1
    }
}

require_command git
require_command cmake
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_DIR GIT_INDEX_FILE
unset GIT_OBJECT_DIRECTORY GIT_WORK_TREE
export GIT_OPTIONAL_LOCKS=0

if [ -e "$SOURCE_DIR" ] && [ ! -e "$SOURCE_DIR/.git" ]; then
    echo "LLVM source path exists but is not a git checkout: $SOURCE_DIR" >&2
    exit 1
fi

if [ ! -e "$SOURCE_DIR/.git" ]; then
    git clone --branch "$REVISION" --depth=1 "$REMOTE" "$SOURCE_DIR"
fi
verify_source

case "$(uname -m)" in
    x86_64 | amd64) ARCH=x64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *)
        echo "Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

PLATFORM_CMAKE_ARGS=()
case "$(uname -s)" in
    Darwin)
        CPU=$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
        BUILD_DIR="$BASE/build_shared_darwin_$ARCH"
        OUTPUT_DIR="$BASE/darwin_$ARCH"
        RPATH=@loader_path
        if [ "$ARCH" = arm64 ]; then
            DEFAULT_MACOSX_DEPLOYMENT_TARGET=11.0
        else
            DEFAULT_MACOSX_DEPLOYMENT_TARGET=10.15
        fi
        PLATFORM_CMAKE_ARGS=(
            -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$DEFAULT_MACOSX_DEPLOYMENT_TARGET}"
        )
        ;;
    Linux)
        CPU=$(nproc)
        BUILD_DIR="$BASE/build_shared_linux_$ARCH"
        OUTPUT_DIR="$BASE/linux_$ARCH"
        RPATH='$ORIGIN'
        ;;
    *)
        echo "Unsupported host OS: $(uname -s)" >&2
        exit 1
        ;;
esac

echo "Configuring LLVM $REVISION shared build..."
cmake -S "$SOURCE_DIR/llvm" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    "${PLATFORM_CMAKE_ARGS[@]}" \
    -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DCMAKE_INSTALL_RPATH="$RPATH" \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_TARGETS_TO_BUILD=all

echo "Building LLVM and LTO..."
cmake --build "$BUILD_DIR" --target LLVM LTO --parallel "$CPU"

mkdir -p "$OUTPUT_DIR"
case "$(uname -s)" in
    Darwin)
        require_file "$BUILD_DIR/lib/libLLVM.dylib"
        require_file "$BUILD_DIR/lib/libLTO.dylib"
        cp "$BUILD_DIR/lib/libLLVM.dylib" "$OUTPUT_DIR/libLLVM.dylib"
        cp "$BUILD_DIR/lib/libLTO.dylib" "$OUTPUT_DIR/libLTO.dylib"
        ;;
    Linux)
        shopt -s nullglob
        llvm_libraries=("$BUILD_DIR"/lib/libLLVM*.so*)
        lto_libraries=("$BUILD_DIR"/lib/libLTO*.so*)
        shopt -u nullglob
        ((${#llvm_libraries[@]} > 0)) || {
            echo "Missing LLVM shared libraries under $BUILD_DIR/lib" >&2
            exit 1
        }
        ((${#lto_libraries[@]} > 0)) || {
            echo "Missing LTO shared libraries under $BUILD_DIR/lib" >&2
            exit 1
        }
        for artifact in "${llvm_libraries[@]}" "${lto_libraries[@]}"; do
            if [ -L "$artifact" ] && [ ! -e "$artifact" ]; then
                echo "LLVM build produced dangling symlink: $artifact" >&2
                exit 1
            fi
        done
        rm -f -- "$OUTPUT_DIR"/libLLVM*.so* "$OUTPUT_DIR"/libLTO*.so*
        cp -a -- "${llvm_libraries[@]}" "${lto_libraries[@]}" "$OUTPUT_DIR/"
        ;;
esac

echo "LLVM shared build completed successfully!"
