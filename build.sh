#!/bin/bash

# ============================================
# LIBRECPB BUILD SCRIPT
# Usage: ./build.sh [OPTIONS]
#   -j, --jobs N      Number of parallel jobs (default: $(nproc))
#   -d, --debug       Build in debug mode (default: release)
#   -r, --release     Build in release mode (default)
#   -c, --clean       Clean build directory before build
#   -h, --help        Show this help
# ============================================

set -e

# ============================================
# DEFAULT VALUES
# ============================================
JOBS=$(nproc 2>/dev/null || echo 4)
BUILD_TYPE="Release"
CLEAN_BUILD=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PATCH_MARKER="$HOME/.cache/librepcb-jemalloc-patched"

# ============================================
# PARSE ARGUMENTS
# ============================================
while [[ $# -gt 0 ]]; do
  case $1 in
  -j | --jobs)
    JOBS="$2"
    shift 2
    ;;
  -d | --debug)
    BUILD_TYPE="Debug"
    shift
    ;;
  -r | --release)
    BUILD_TYPE="Release"
    shift
    ;;
  -c | --clean)
    CLEAN_BUILD=true
    shift
    ;;
  -h | --help)
    echo "Usage: ./build.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -j, --jobs N      Number of parallel jobs (default: $(nproc 2>/dev/null || echo 4))"
    echo "  -d, --debug       Build in debug mode"
    echo "  -r, --release     Build in release mode (default)"
    echo "  -c, --clean       Clean build directory before build"
    echo "  -h, --help        Show this help"
    exit 0
    ;;
  *)
    echo "❌ Unknown option: $1"
    echo "Use -h for help"
    exit 1
    ;;
  esac
done

# ============================================
# RUST OPTIMIZATION SETTINGS
# ============================================
export RUSTC_WRAPPER=sccache

# DEBUG: ультрабыстрая сборка
export CARGO_PROFILE_DEV_INCREMENTAL=true
export CARGO_PROFILE_DEV_DEBUG=true

# RELEASE: максимально быстрый бинарник
export CARGO_PROFILE_RELEASE_LTO=true
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_INCREMENTAL=false

# ============================================
# HEADER
# ============================================
echo "🔧 Building LibrePCB"
echo "📌 Build type: $BUILD_TYPE"
echo "📌 Parallel jobs: $JOBS"
echo "📌 Clean build: $CLEAN_BUILD"
echo "📁 Project directory: $PROJECT_DIR"
echo ""

# ============================================
# CHECK DEPENDENCIES
# ============================================
echo "🔍 Checking dependencies..."
MISSING=0

command -v cmake >/dev/null 2>&1 || {
  echo "❌ cmake not found"
  MISSING=1
}
command -v make >/dev/null 2>&1 || {
  echo "❌ make not found"
  MISSING=1
}
command -v g++ >/dev/null 2>&1 || {
  echo "❌ g++ not found"
  MISSING=1
}
command -v rustc >/dev/null 2>&1 || {
  echo "❌ rustc not found"
  MISSING=1
}
command -v cargo >/dev/null 2>&1 || {
  echo "❌ cargo not found"
  MISSING=1
}
command -v sccache >/dev/null 2>&1 || { echo "⚠️  sccache not found (install: sudo dnf install sccache)"; }

if [ $MISSING -eq 1 ]; then
  echo ""
  echo "❌ Install missing dependencies:"
  echo "  sudo dnf install cmake gcc-c++ make rust cargo"
  echo "  sudo dnf install qt6-qtbase-devel qt6-qttools-devel qt6-qtimageformats qt6-qtsvg-devel"
  echo "  sudo dnf install mesa-libGLU-devel openssl-devel"
  echo "  sudo dnf install sccache  # optional but recommended"
  exit 1
fi

echo "✅ All dependencies found"

# ============================================
# CHECK SCCACHE
# ============================================
if command -v sccache >/dev/null 2>&1; then
  echo "✅ sccache found (Rust compilation cache enabled)"
else
  echo "⚠️  sccache not found (Rust compilation will be slower)"
  unset RUSTC_WRAPPER
fi

# ============================================
# PATCH JEMALLOC BUILD.RS (ONLY ONCE)
# ============================================
echo "🔧 Checking jemalloc-sys patch..."

# Try to find jemalloc-sys in cargo registry
JEMALLOC_SYS_DIR=$(find ~/.cargo/registry/src -type d -name "tikv-jemalloc-sys-0.7.1*" 2>/dev/null | head -1)

# If not found, try to download it
if [ -z "$JEMALLOC_SYS_DIR" ]; then
  echo "📦 Downloading jemalloc-sys..."
  cargo build --manifest-path "$PROJECT_DIR/libs/librepcb/rust-core/Cargo.toml" --release --features=ffi 2>/dev/null || true
  JEMALLOC_SYS_DIR=$(find ~/.cargo/registry/src -type d -name "tikv-jemalloc-sys-0.7.1*" 2>/dev/null | head -1)
fi

if [ -n "$JEMALLOC_SYS_DIR" ] && [ -f "$JEMALLOC_SYS_DIR/build.rs" ]; then
  if [ ! -f "$PATCH_MARKER" ]; then
    echo "📁 Found jemalloc-sys at: $JEMALLOC_SYS_DIR"
    cp "$JEMALLOC_SYS_DIR/build.rs" "$JEMALLOC_SYS_DIR/build.rs.bak"
    echo "📝 Applying patch (first time only)..."

    sed -i '/fn make_command/,/^}/c\
fn make_command(make_cmd: &str, build_dir: &Path, num_jobs: &str) -> Command {\
    let mut cmd = Command::new(make_cmd);\
    cmd.current_dir(build_dir);\
\
    if let Ok(makeflags) = std::env::var("CARGO_MAKEFLAGS") {\
        let final_flags = if let Ok(orig_makeflags) = std::env::var("MAKEFLAGS") {\
            if orig_makeflags.contains("--jobserver") {\
                orig_makeflags\
            } else if makeflags.contains("--jobserver") {\
                makeflags\
            } else {\
                format!("{makeflags} {orig_makeflags}")\
            }\
        } else {\
            makeflags\
        };\
        cmd.env("MAKEFLAGS", final_flags);\
    } else {\
        cmd.arg("-j").arg(num_jobs);\
    }\
    cmd\
}' "$JEMALLOC_SYS_DIR/build.rs"

    mkdir -p "$(dirname "$PATCH_MARKER")"
    touch "$PATCH_MARKER"
    echo "✅ build.rs patched successfully (marker saved)"
  else
    echo "✅ jemalloc-sys already patched (skipping)"
  fi
else
  echo "⚠️  Could not find jemalloc-sys, using alternative fix"
  export MAKEFLAGS="$(echo $MAKEFLAGS | sed 's/--jobserver[^ ]*//g' | sed 's/ s / /g' | sed 's/^s$//g' | sed 's/^s //g')"
  echo "✅ Alternative fix applied"
fi

# ============================================
# PREPARE BUILD
# ============================================
cd "$PROJECT_DIR"

if [ "$CLEAN_BUILD" = true ]; then
  echo "🧹 Cleaning build directory..."
  rm -rf build
fi

echo "📁 Preparing build..."
mkdir -p build
cd build

# ============================================
# CONFIGURE CMAKE
# ============================================
echo "⚙️  Configuring CMake..."
cmake -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DSLINT_FEATURE_BACKEND_WINIT=ON \
  -DUSE_OPENCASCADE=OFF \
  -DBUILD_TESTS=OFF \
  "$PROJECT_DIR" \
  2>&1 | grep -v "Could NOT find Cups"

# ============================================
# BUILD RUST DEPENDENCIES
# ============================================
echo "🦀 Building Rust dependencies ($JOBS threads)..."
make _cargo-build_librepcb_rust_core -j"$JOBS" 2>/dev/null || true
make _cargo-build_librepcbslint -j"$JOBS" 2>/dev/null || true

# ============================================
# MAIN BUILD
# ============================================
echo "🏗️  Main build ($JOBS threads)..."
if ! make -j"$JOBS" 2>&1; then
  echo "⚠️  Build failed, continuing without slint-compiler..."
  make -j"$JOBS" 2>&1 | grep -v "_cargo-build_slint-compiler" || true
fi

# ============================================
# BUILD LIBREPCB
# ============================================
if [ ! -f "./apps/librepcb/librepcb" ]; then
  echo "🏗️  Building librepcb ($JOBS threads)..."
  make librepcb -j"$JOBS" 2>&1 | grep -v "_cargo-build_slint-compiler" || true
fi

# ============================================
# CHECK RESULT
# ============================================
echo ""
if [ -f "./apps/librepcb/librepcb" ]; then
  echo "✅ BUILD SUCCESSFUL!"
  echo "📂 Binary: $(pwd)/apps/librepcb/librepcb"
  echo ""
  echo "🚀 Run with GPU:"
  echo "  SLINT_BACKEND=winit-femtovg ./apps/librepcb/librepcb"
  echo ""
  echo "🚀 Run with CPU:"
  echo "  SLINT_BACKEND=qt ./apps/librepcb/librepcb"
  echo ""

  # Show sccache stats if available
  if command -v sccache >/dev/null 2>&1; then
    echo "📊 sccache stats:"
    sccache --show-stats
    echo ""
  fi

  file "./apps/librepcb/librepcb"
  ls -lh "./apps/librepcb/librepcb"
  echo ""
  ./apps/librepcb/librepcb --version 2>/dev/null || echo "  (version check skipped)"
else
  echo "❌ BUILD FAILED!"
  echo ""
  echo "🔍 Contents of apps/librepcb/:"
  ls -la apps/librepcb/ 2>/dev/null || echo "  Empty"
  echo ""
  echo "💡 Try manual linking:"
  echo "  cd build && make librepcb"
  exit 1
fi
