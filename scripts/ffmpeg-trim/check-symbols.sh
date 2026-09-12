#!/usr/bin/env bash
# =============================================================================
# 符号覆盖检查：确认裁剪版 libav* 能满足 AAR 内 libffmpegkit.so 的全部引用。
# libffmpegkit.so 是插件 fork 用完整 FFmpeg 8.0 编译的，内部 ffmpeg.c/ffprobe.c
# 引用通用 API；若裁剪版缺符号，Android linker dlopen 时会失败。
# 用法：bash check-symbols.sh <libffmpegkit.so路径> <dist目录>
# =============================================================================
set -uo pipefail

FFMPEGKIT_SO="${1:-}"
DIST="${2:-$(cd "$(dirname "$0")" && pwd)/dist/arm64-v8a}"
NDK_BIN="/mnt/c/Users/小奇/AppData/Local/Android/Sdk/ndk/27.1.12297006/toolchains/llvm/prebuilt/windows-x86_64/bin"
NM="$NDK_BIN/llvm-nm.exe"

if [ ! -f "$FFMPEGKIT_SO" ]; then
  echo "用法: bash check-symbols.sh <libffmpegkit.so> [dist目录]"
  echo "libffmpegkit.so 可从 AAR 解出：unzip ffmpeg-kit-audio-*.aar jni/arm64-v8a/libffmpegkit.so"
  exit 1
fi

# 裁剪版库的全部导出符号
ALL_EXPORTS="$(
  for f in "$DIST"/*.so; do "$NM" -D --defined-only "$f" 2>/dev/null; done \
  | awk '{print $3}' | grep -v '^$' | sort -u
)"

# libffmpegkit.so 的未定义符号中，来自 FFmpeg 生态的（av*/sw*/ff_*）
MISSING=0
while read -r sym; do
  if ! grep -qx "$sym" <<<"$ALL_EXPORTS"; then
    echo "  MISSING: $sym"
    MISSING=1
  fi
done < <("$NM" -D --undefined-only "$FFMPEGKIT_SO" 2>/dev/null | awk '{print $2}' | grep -E '^(av|sw|ff_)' | sort -u)

if [ "$MISSING" -eq 0 ]; then
  echo "OK: 裁剪版库覆盖 libffmpegkit.so 的全部 FFmpeg 符号引用"
else
  echo "FAIL: 存在缺失符号，需调整 configure 裁剪配置"
  exit 1
fi
