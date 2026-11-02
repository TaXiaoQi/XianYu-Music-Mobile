#!/usr/bin/env bash
# iOS Rust 构建钩子：把 rust/ 下的 xianyu_core 编成动态 framework。
#
# 为什么是动态 framework 而非静态库：flutter_rust_bridge 2.12 在 iOS 上的
# 加载顺序为 lib$stem.dylib → rust_builder.framework → $stem.framework/$stem
# （见 pub 缓存 flutter_rust_bridge-2.12.0/lib/src/loader/_io.dart），没有
# DynamicLibrary.process() 分支；因此必须提供名为 xianyu_core.framework 的
# 动态框架（与 Flutter 官方 plugin_ffi 模板同一模式），静态 .a 链入主程序
# 的符号会被链接器裁剪，运行期 lookup 直接失败。
#
# 对齐 Android 侧 scripts/gradle-rust-hook.ps1 的职责：
#   - 依据 Xcode 传入的 PLATFORM_NAME 选目标三元组：
#       真机   aarch64-apple-ios
#       模拟器 aarch64-apple-ios-sim（装了 x86_64-apple-ios 时 lipo 合并）
#   - 产物：ios/Frameworks/xianyu_core.framework（由 ios/xianyu_core.podspec
#     vendored_frameworks 引入并嵌入 App）
#
# 用法：首次使用前 `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`。
# 设 XIANMU_SKIP_RUST=1 可跳过（如只改 Dart 快速验证）。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${XIANMU_SKIP_RUST:-}" = "1" ]; then
  echo "[ios-rust-hook] XIANMU_SKIP_RUST=1, skip"
  exit 0
fi

# 仅 macOS 可执行（iOS 交叉编译依赖 Xcode 工具链）；其余平台直接放行。
if [ "$(uname -s)" != "Darwin" ]; then
  echo "[ios-rust-hook] not macOS, skip rust build"
  exit 0
fi

command -v cargo >/dev/null 2>&1 || { echo "[ios-rust-hook] cargo not found in PATH" >&2; exit 1; }

FRAMEWORK="$SRC/ios/Frameworks/xianyu_core.framework"
mkdir -p "$FRAMEWORK"

cd "$SRC/rust"

# 按 Xcode script phase 的 PLATFORM_NAME 选目标；本地手跑默认真机。
if [ "${PLATFORM_NAME:-}" = "iphonesimulator" ]; then
  echo "[ios-rust-hook] cargo build (simulator: aarch64-apple-ios-sim)"
  cargo build --release --target aarch64-apple-ios-sim
  DYLIB="$SRC/rust/target/aarch64-apple-ios-sim/release/libxianyu_core.dylib"
  if rustup target list --installed 2>/dev/null | grep -q '^x86_64-apple-ios$'; then
    echo "[ios-rust-hook] cargo build (simulator: x86_64-apple-ios)"
    cargo build --release --target x86_64-apple-ios
    INTEL="$SRC/rust/target/x86_64-apple-ios/release/libxianyu_core.dylib"
    lipo -create "$DYLIB" "$INTEL" -output "$DYLIB.sim.tmp"
    mv "$DYLIB.sim.tmp" "$DYLIB"
  fi
else
  echo "[ios-rust-hook] cargo build (device: aarch64-apple-ios)"
  cargo build --release --target aarch64-apple-ios
  DYLIB="$SRC/rust/target/aarch64-apple-ios/release/libxianyu_core.dylib"
fi

[ -f "$DYLIB" ] || { echo "[ios-rust-hook] dylib missing: $DYLIB" >&2; exit 1; }

# 组装 framework：二进制命名必须与框架同名（loader 打开 $stem.framework/$stem）。
cp "$DYLIB" "$FRAMEWORK/xianyu_core"
# install name 固化为 @rpath 形式，嵌入 App 后由 App 的 rpath 解析。
install_name_tool -id "@rpath/xianyu_core.framework/xianyu_core" "$FRAMEWORK/xianyu_core"

cat > "$FRAMEWORK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>xianyu_core</string>
	<key>CFBundleIdentifier</key>
	<string>cc.xymusic.mobile.xianyuCore</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>xianyu_core</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>0.1.0</string>
	<key>MinimumOSVersion</key>
	<string>15.0</string>
</dict>
</plist>
PLIST

echo "[ios-rust-hook] framework ready: $FRAMEWORK"
exit 0
