#!/usr/bin/env bash
# Rust 自动编译钩子（POSIX / Linux / macOS 版，与 gradle-rust-hook.ps1 逻辑一致）。
# 由 android/app/build.gradle.kts 的 rustHook 任务在非 Windows 平台调用：
# flutter run / flutter build / gradle 构建时自动检测并编译 Rust（绑定 + .so）。
#
# 退出码：0 = 无需处理或构建成功；3 = 绑定已重新生成（release 构建当轮生效，
#         debug 需重跑一次）；其他 = 失败（Gradle 任务报错）。
# XIANMU_SKIP_RUST=1 可完全跳过（直接复用工程中已有 .so 产物）。
#
# 与 ps1 的差异：仅去掉了 Windows 专属的路径规避（D:\ascii-env、UNC 长路径、
# LLVM 的 Program Files 固定安装位），NDK/LLVM 在 POSIX 下走常规检测。

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[ "${XIANMU_SKIP_RUST:-0}" = "1" ] && exit 0

SO_FILE="$ROOT/android/app/src/main/jniLibs/arm64-v8a/libxianyu_core.so"
BINDINGS="$ROOT/lib/src/rust/frb_generated.dart"
RUST_SRC_DIR="$ROOT/rust/src"
HOOK_LOG="$ROOT/build/rust-hook.log"
mkdir -p "$(dirname "$HOOK_LOG")"

log() { printf '%s\n' "$*" >&2; }

# ---- 新鲜度检测：目标产物缺失，或任何 rust 源/配置文件比产物新则需重建 ----
RUST_FILESChanged() { # $1 = 参照文件；存在比其新的 .rs 源文件时返回 0
  local ref="$1"
  [ ! -e "$ref" ] && return 0
  [ -n "$(find "$RUST_SRC_DIR" -type f -name '*.rs' ! -name 'frb_generated.rs' -newer "$ref" -print -quit 2>/dev/null)" ]
}

needSo=1
if [ -e "$SO_FILE" ]; then
  needSo=0
  RUST_FILESChanged "$SO_FILE" && needSo=1
  for cfg in "$ROOT/rust/Cargo.toml" "$ROOT/rust/Cargo.lock" "$ROOT/flutter_rust_bridge.yaml"; do
    [ -e "$cfg" ] && [ "$cfg" -nt "$SO_FILE" ] && needSo=1
  done
fi

needCodegen=1
if [ -e "$BINDINGS" ]; then
  needCodegen=0
  RUST_FILESChanged "$BINDINGS" && needCodegen=1
fi

if [ "$needSo" -eq 0 ] && [ "$needCodegen" -eq 0 ]; then exit 0; fi

log "[rust-hook] Building Rust..."

# ---- 工具链定位 ----
CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin"
if [ ! -d "$CARGO_BIN" ]; then
  cargoPath="$(command -v cargo 2>/dev/null || true)"
  [ -n "$cargoPath" ] && CARGO_BIN="$(dirname "$cargoPath")"
fi
case ":$PATH:" in
  *":$CARGO_BIN:"*) ;;
  *) export PATH="$CARGO_BIN:$PATH" ;;
esac

# ANDROID_HOME：优先环境变量，其次 Linux/macOS 默认 SDK 位置
if [ -z "${ANDROID_HOME:-}" ]; then
  for cand in "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
    if [ -d "$cand" ]; then ANDROID_HOME="$cand"; break; fi
  done
fi
export ANDROID_HOME="${ANDROID_HOME:-}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

# NDK：取 SDK 下 ndk/ 目录中版本号最新的一个
if [ -n "$ANDROID_HOME" ] && [ -d "$ANDROID_HOME/ndk" ]; then
  ndkVer="$(ls -1 "$ANDROID_HOME/ndk" 2>/dev/null | sort -V | tail -n1)"
  if [ -n "$ndkVer" ]; then
    export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$ndkVer"
    export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/$ndkVer"
  fi
fi

# libclang（rquickjs-sys 0.12+ 的 bindgen 依赖）：macOS Homebrew / Debian 系
# 常见位置自动探测，已显式设置 LIBCLANG_PATH 时不覆盖
if [ -z "${LIBCLANG_PATH:-}" ]; then
  for cand in /opt/homebrew/opt/llvm/lib /usr/local/opt/llvm/lib /usr/lib/llvm-*/lib; do
    for f in "$cand"/libclang.*; do
      if [ -e "$f" ]; then export LIBCLANG_PATH="$cand"; break 2; fi
    done
  done
fi

if [ "$needCodegen" -eq 1 ]; then
  log "[rust-hook] Generating Dart bindings..."
  codegen="$CARGO_BIN/flutter_rust_bridge_codegen"
  [ -x "$codegen" ] || codegen="$(command -v flutter_rust_bridge_codegen)" || codegen="flutter_rust_bridge_codegen"
  if ! (cd "$ROOT" && "$codegen" generate \
        --rust-root "$ROOT/rust" --rust-output "$ROOT/rust/src/frb_generated.rs" \
        >"$HOOK_LOG" 2>&1); then
    tail -n 20 "$HOOK_LOG" >&2
    log "[rust-hook] Codegen failed"
    exit 1
  fi
fi

if [ "$needSo" -eq 1 ]; then
  log "[rust-hook] Compiling .so..."
  if ! (cd "$ROOT/rust" && cargo ndk -t arm64-v8a build --release >"$HOOK_LOG" 2>&1); then
    tail -n 30 "$HOOK_LOG" >&2
    log "[rust-hook] cargo ndk build failed"
    exit 1
  fi
  mkdir -p "$ROOT/android/app/src/main/jniLibs/arm64-v8a"
  cp -f "$ROOT/rust/target/aarch64-linux-android/release/libxianyu_core.so" \
        "$ROOT/android/app/src/main/jniLibs/arm64-v8a/"
  # 与 ps1 一致：清掉 jniLibs 下除目标 .so 外的其他 so（防历史产物混入打包）
  find "$ROOT/android/app/src/main/jniLibs" -type f -name '*.so' \
       ! -path '*/arm64-v8a/libxianyu_core.so' -delete 2>/dev/null || true
fi

if [ "$needCodegen" -eq 1 ]; then
  log "[rust-hook] Rust API bindings regenerated. Please re-run flutter run."
  exit 3
fi

log "[rust-hook] .so updated successfully"
exit 0
