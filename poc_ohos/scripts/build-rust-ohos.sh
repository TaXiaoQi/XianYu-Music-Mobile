#!/usr/bin/env bash
# build-rust-ohos.sh - macOS/Linux：交叉编译 libxianyu_core.so（aarch64-unknown-linux-ohos）
#
# 用法:
#   ./scripts/build-rust-ohos.sh                     # 自动探测 SDK
#   ./scripts/build-rust-ohos.sh <OHOS_SDK_ROOT>     # 指定 SDK 根（其下应有 native/llvm/bin/clang）
#
# 产物:
#   rust/target/aarch64-unknown-linux-ohos/release/libxianyu_core.so
#   若 poc_ohos/ohos/entry 已生成，自动拷贝到 poc_ohos/ohos/entry/libs/arm64-v8a/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(dirname "$SCRIPT_DIR")"
MOBILE_DIR="$(dirname "$POC_DIR")"
RUST_DIR="$MOBILE_DIR/rust"
TARGET="aarch64-unknown-linux-ohos"

echo "== 弦予 xianyu_core -> OpenHarmony (arm64) =="

command -v cargo  >/dev/null 2>&1 || { echo "未找到 cargo，请先安装 Rust"; exit 1; }
command -v rustup >/dev/null 2>&1 || { echo "未找到 rustup"; exit 1; }

# ---- 探测 OHOS SDK native 根（含 llvm/bin/clang 与 sysroot）----
find_native() {
  local root="$1"
  [ -n "$root" ] && [ -d "$root" ] || return 1
  for cand in "$root/native" "$root/default/openharmony/native" "$root/openharmony/native"; do
    [ -x "$cand/llvm/bin/clang" ] && { echo "$cand"; return 0; }
  done
  # 版本目录两层 glob（如 sdk/HarmonyOS-NEXT-DB6/openharmony/native）
  local hit
  hit="$(find "$root" -maxdepth 6 -path '*/native/llvm/bin/clang' -print -quit 2>/dev/null || true)"
  if [ -n "$hit" ]; then
    dirname "$(dirname "$(dirname "$hit")")"
    return 0
  fi
  return 1
}

NATIVE=""
for cand in "${1:-}" "${DEVECO_SDK_HOME:-}" "${HOS_SDK_HOME:-}" "${OHOS_SDK_HOME:-}" "${OHOS_BASE_SDK_HOME:-}" \
  "/Applications/DevEco-Studio.app/Contents/sdk" "$HOME/Library/OpenHarmony/Sdk" \
  "/command-line-tools" "$HOME/command-line-tools"; do
  NATIVE="$(find_native "$cand" 2>/dev/null || true)"
  [ -n "$NATIVE" ] && break
done
if [ -z "$NATIVE" ]; then
  echo "未找到 HarmonyOS SDK（native/llvm/bin/clang）。请安装 DevEco Studio 后重试，或显式传入 SDK 根目录。"
  exit 1
fi
CLANG="$NATIVE/llvm/bin/clang"
CLANGXX="$NATIVE/llvm/bin/clang++"
LLVM_AR="$NATIVE/llvm/bin/llvm-ar"
LLVM_RANLIB="$NATIVE/llvm/bin/llvm-ranlib"
SYSROOT="$NATIVE/sysroot"
echo "SDK native: $NATIVE"
[ -d "$SYSROOT" ] || { echo "未找到 sysroot: $SYSROOT"; exit 1; }

# ---- rustup target ----
rustup target list --installed | grep -qx "$TARGET" || rustup target add "$TARGET"

# ---- linker / CC wrapper ----
TOOLCHAIN_DIR="$POC_DIR/.toolchain-ohos"
mkdir -p "$TOOLCHAIN_DIR"
LINKER="$TOOLCHAIN_DIR/$TARGET-clang"
LINKERXX="$TOOLCHAIN_DIR/$TARGET-clang++"
printf '#!/bin/sh\nexec "%s" --target=aarch64-linux-ohos --sysroot="%s" -D__MUSL__ "$@"\n' "$CLANG" "$SYSROOT"  > "$LINKER"
printf '#!/bin/sh\nexec "%s" --target=aarch64-linux-ohos --sysroot="%s" -D__MUSL__ "$@"\n' "$CLANGXX" "$SYSROOT" > "$LINKERXX"
chmod +x "$LINKER" "$LINKERXX"

# ---- 编译环境变量 ----
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$LINKER"
export CC_aarch64_unknown_linux_ohos="$LINKER"
export CXX_aarch64_unknown_linux_ohos="$LINKERXX"
[ -x "$LLVM_AR" ]     && export AR_aarch64_unknown_linux_ohos="$LLVM_AR"
[ -x "$LLVM_RANLIB" ] && export RANLIB_aarch64_unknown_linux_ohos="$LLVM_RANLIB"

# bindgen（rquickjs 需 libclang）
LIBCLANG_DIR="$NATIVE/llvm/lib"
if ! ls "$NATIVE/llvm/lib/libclang.so" "$NATIVE/llvm/lib/libclang.dylib" >/dev/null 2>&1; then
  for alt in /opt/homebrew/opt/llvm/lib /usr/local/opt/llvm/lib; do
    [ -e "$alt/libclang.dylib" ] || [ -e "$alt/libclang.so" ] && { LIBCLANG_DIR="$alt"; break; }
  done
fi
export LIBCLANG_PATH="$LIBCLANG_DIR"
export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$SYSROOT -D__MUSL__ -I$SYSROOT/usr/include"

# ---- cargo build ----
echo "开始编译: cargo build --release --target $TARGET"
cargo build --release --target "$TARGET" --manifest-path "$RUST_DIR/Cargo.toml"

# ---- 产物拷贝 ----
SO="$RUST_DIR/target/$TARGET/release/libxianyu_core.so"
[ -f "$SO" ] || { echo "产物缺失: $SO"; exit 1; }
echo "产物: $SO ($(du -h "$SO" | cut -f1))"

DEST_DIR="$POC_DIR/ohos/entry/libs/arm64-v8a"
if [ -d "$POC_DIR/ohos/entry" ]; then
  mkdir -p "$DEST_DIR"
  cp -f "$SO" "$DEST_DIR/libxianyu_core.so"
  echo "已拷贝到: $DEST_DIR/libxianyu_core.so"
else
  echo "提示: poc_ohos/ohos/entry 尚未生成（先跑 scripts/setup.ps1），产物保留在 rust/target 下"
fi

echo "== 完成 =="