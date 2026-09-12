#!/usr/bin/env bash
# =============================================================================
# 精简版 FFmpeg 交叉构建脚本（Android arm64-v8a）
#
# 背景：ffmpeg_kit_flutter_new_audio 依赖的 com.antonkarpenko:ffmpeg-kit-audio
#       是完整音频变体（FFmpeg 8.0.x，avcodec 62.28.102 / avformat 62.12.102），
#       连视频编解码器都打包（libavcodec.so 约 11MB 未压缩），APK 里占 ~10MB。
#       本脚本从同一 FFmpeg 8.0 分支裁剪出只含音频工具页所需能力的 .so，
#       APK 预计 30MB → ~25MB，8 种输出格式 / 封面 / 歌词 / 裁剪全部保留。
#
# 约束（必须与插件 fork 对齐，否则 libffmpegkit.so dlopen 失败）：
#   - 同一 FFmpeg 8.0.x 分支（avcodec 62 主版本，ABI 稳定）
#   - 通用 API 全部保留（只裁剪编解码器/封装器/滤镜实现）
#   - 保留 CONFIG 守卫的子系统：avdevice / avfilter / swscale / network
#     （libffmpegkit.so 内的 ffmpeg.c 引用 avdevice_register_all 等符号）
#
# 产物：dist/arm64-v8a/lib{avcodec,avformat,avfilter,avutil,swresample,swscale,avdevice}.so
#       拷贝到 android/app/src/main/jniLibs/arm64-v8a/ 覆盖 AAR 内同名 .so 即可。
#
# 运行环境：WSL2 Ubuntu（需 make/gcc/pkg-config/curl/git），NDK 用 Windows 版经
#          WSL interop 调用（clang.exe 吃 Windows 路径，故构建树放 /mnt/c 下）。
# 用法：  bash build-android.sh
# =============================================================================
set -euo pipefail

# ---------- 可配置 ----------
# 路径必须全 ASCII：中文路径（如 C:\Users\小奇）在 pkg-config 输出 → clang
# 链路上 UTF-8 字节会损坏成替换字符，FFmpeg configure 检测依赖库必然失败。
# 通过 Windows junction 把 NDK 和构建树映射到无中文路径（C:\ndk27 / C:\ffbuild）。
NDK="/mnt/c/ndk27"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
API=24

# 构建树放 Windows 盘（Windows clang 进程只能读写 Windows 路径）
BASE="/mnt/c/ffbuild"
WIN_BASE="C:/ffbuild"
PREFIX="$BASE/prefix"
WIN_PREFIX="$WIN_BASE/prefix"

DIST="$(cd "$(dirname "$0")" && pwd)/dist/arm64-v8a"
JOBS=$(nproc)

# NDK 27 工具命名：clang 系列无扩展名（PE 文件），llvm-* 系列带 .exe。
# 经 WSL interop 调用 Windows 程序时，参数/源文件路径必须用 Windows 风格
# （C:/...），configure 在 /mnt/c 下用相对路径 conftest.c 亦正常。
NDK_BIN_FULL="$NDK_BIN"

# ---------- Windows 工具 shim ----------
# Windows 工具（llvm-*.exe / clang）无法访问 /mnt/<drive>/ 绝对路径，
# libtool 的 install 阶段会把绝对 Linux 路径传给 ranlib 等导致
# "unable to load '.../libogg.a'" 失败。生成 bash shim 包装器，
# 把所有 /mnt/<drive>/ 前缀参数转成 <DRIVE>:/ 再转发给真身。
SHIM_DIR="$BASE/shims"
mkdir -p "$SHIM_DIR"
mk_shim() { # mk_shim <name> <real-tool>
  local name="$1" real="$2"
  cat > "$SHIM_DIR/$name" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
    case "\$a" in
      *"/mnt/"*) args+=("\$(printf '%s' "\$a" | sed -E 's|/mnt/([a-z])/|\U\1:/|g')") ;;
      *) args+=("\$a") ;;
    esac
  done
exec "$real" "\${args[@]}"
EOF
  chmod +x "$SHIM_DIR/$name"
}
mk_shim clang  "$NDK_BIN_FULL/aarch64-linux-android${API}-clang"
mk_shim ar     "$NDK_BIN_FULL/llvm-ar.exe"
mk_shim ranlib "$NDK_BIN_FULL/llvm-ranlib.exe"
mk_shim nm     "$NDK_BIN_FULL/llvm-nm.exe"
mk_shim strip  "$NDK_BIN_FULL/llvm-strip.exe"
CC="$SHIM_DIR/clang"
AR="$SHIM_DIR/ar"
RANLIB="$SHIM_DIR/ranlib"
NM="$SHIM_DIR/nm"
STRIP="$SHIM_DIR/strip"
SYSROOT_WIN="C:/ndk27/toolchains/llvm/prebuilt/windows-x86_64/sysroot"

# autotools 依赖库（libogg/opus 等）的 configure 编译测试程序时没有显式 sysroot，
# 必须在 CFLAGS/LDFLAGS 里带上，否则 clang 找不到 Android libc 头文件/库。
export CFLAGS="-O2 -fPIC --sysroot=$SYSROOT_WIN -I$WIN_PREFIX/include"
export LDFLAGS="--sysroot=$SYSROOT_WIN -L$WIN_PREFIX/lib"
export CPPFLAGS="-I$WIN_PREFIX/include"

log() { echo -e "\n\033[1;36m[ffmpeg-trim]\033[0m $*"; }

mkdir -p "$BASE/src" "$DIST"

# ---------- 1. 准备源码 ----------
# WSL 无外网时：先用 Windows 主机把 tarball 下载到 $BASE/src-dl/，本脚本只负责解包。
# 需要：ffmpeg-8.0.3.tar.xz、lame-3.100.tar.gz、opus-1.5.2.tar.gz、
#       libogg-1.3.5.tar.gz、libvorbis-1.3.7.tar.gz
# 注意：必须用官方 autotools 发布包（含 configure）。GitHub 的 archive tarball 是
#       git 快照，不含生成的 configure，交叉编译前无法 autoreconf（WSL 无网装不了）。
SRCDL="$BASE/src-dl"
mkdir -p "$BASE/src" "$DIST"
unpack() { # unpack <tarball> <destdir>
  local tb="$SRCDL/$1"
  local dir="$BASE/src/$2"
  if [ -d "$dir" ]; then
    if [ ! -f "$dir/configure" ]; then
      log "目录 $2 缺少 configure（残留或不完整），重新解包 ..."
      rm -rf "$dir"
    else
      return 0
    fi
  fi
  if [ ! -f "$tb" ]; then echo "!! 缺少 $tb（先用主机下载放入）"; exit 1; fi
  log "解包 $1 ..."
  mkdir -p "$dir"
  tar xf "$tb" -C "$dir" --strip-components=1
  if [ ! -f "$dir/configure" ]; then
    echo "!! $1 解包后仍无 configure——该 tarball 是 git 快照，请换官方 autotools 发布包"; exit 1
  fi
}
unpack ffmpeg-8.0.3.tar.xz ffmpeg
unpack lame-3.100.tar.gz lame
unpack opus-1.5.2.tar.gz opus
unpack libogg-1.3.5.tar.gz libogg
unpack libvorbis-1.3.7.tar.gz libvorbis

cross_configure() { # cross_configure <srcdir> <args...>
  local srcdir="$1"; shift
  ( cd "$srcdir" && ./configure \
      --host=aarch64-linux-android --prefix="$PREFIX" \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" NM="$NM" STRIP="$STRIP" \
      CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" CPPFLAGS="$CPPFLAGS" \
      "$@" )
}

# ---------- 2. 外部编码器库（静态库，最终链进 libavcodec.so） ----------
# 注意：所有包都必须 --disable-dependency-tracking。Windows clang.exe 的 -MD
#       依赖输出是 C:/... 冒号路径，automake 的 .deps/*.Plo 会触发
#       "multiple target patterns"；全量构建用不到增量依赖，直接关掉。
build_lib() { # build_lib <srcdir> <configure args...>
  local srcdir="$1"; shift
  log "构建 $(basename "$srcdir") ..."
  cross_configure "$srcdir" --disable-dependency-tracking "$@"
  make -C "$srcdir" -j"$JOBS" >/dev/null
  make -C "$srcdir" install >/dev/null
}

[ -f "$PREFIX/lib/libogg.a" ]    || build_lib "$BASE/src/libogg"    --disable-shared --enable-static
[ -f "$PREFIX/lib/libvorbis.a" ] || build_lib "$BASE/src/libvorbis" --disable-shared --enable-static \
    --with-ogg-libraries="$PREFIX/lib" --with-ogg-includes="$PREFIX/include"
[ -f "$PREFIX/lib/libopus.a" ]   || build_lib "$BASE/src/opus"      --disable-shared --enable-static \
    --disable-doc --disable-extra-programs
[ -f "$PREFIX/lib/libmp3lame.a" ]|| build_lib "$BASE/src/lame"      --disable-shared --enable-static \
    --disable-frontend --disable-decoder --disable-gtktest

# ---------- 3. 裁剪版 FFmpeg ----------
# FFmpeg configure 用 $TMPDIR 放测试文件（默认 /tmp，Windows clang 读不了），
# 必须指到 /mnt/c 下，shim 才能转成 Windows 路径。
export TMPDIR="/mnt/c/ffbuild/tmp"
mkdir -p "$TMPDIR"
# FFmpeg 通过 pkg-config 检测 opus/vorbis，须指向交叉 prefix（WSL pkg-config
# 能读 /mnt/c，输出的 -I/-L 再经 shim 转 Windows 路径给 clang）。
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
cd "$BASE/src/ffmpeg"
if [ ! -f config.h ]; then
  log "configure 裁剪版 FFmpeg ..."
  ./configure \
    --prefix="$PREFIX" \
    --cc="$CC" --ar="$AR" --ranlib="$RANLIB" --nm="$NM" --strip="$STRIP" \
    --sysroot="$SYSROOT_WIN" \
    --target-os=android --arch=aarch64 --cpu=armv8-a \
    --enable-cross-compile --enable-pic \
    --enable-shared --disable-static \
    --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
    --extra-libs="-lm -logg -lvorbis" \
    --disable-everything \
    --disable-programs --disable-doc --disable-debug --disable-autodetect \
    --enable-small \
    --enable-network \
    --enable-protocol=file \
    --enable-demuxer=mp3,mov,aac,flac,ogg,wav,asf,ape,wv,aiff,matroska \
    --enable-muxer=mp3,ipod,adts,flac,wav,ogg,opus,asf \
    --enable-decoder=mp3,mp3float,aac,alac,flac,vorbis,opus,wmav1,wmav2,wmapro,ape,wavpack \
    --enable-decoder=pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32be,pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw \
    --enable-decoder=adpcm_ima_wav,adpcm_ima_qt,adpcm_ms \
    --enable-encoder=libmp3lame,aac,flac,libvorbis,libopus,wmav2,pcm_s16le \
    --enable-parser=mpegaudio,aac,flac,vorbis,opus,wma,ape,wavpack \
    --enable-filter=atrim,trim,asetpts,setpts,aformat,aresample,anull,anullsrc,aselect,select,apad,volume,atempo \
    --enable-libmp3lame --enable-libopus --enable-libvorbis \
    --enable-swresample --enable-swscale --enable-avdevice --enable-avfilter
fi

log "编译 FFmpeg（-j$JOBS）..."
make -j"$JOBS" >/dev/null

# ---------- 4. 收集产物（版本化 .so 的真身复制为裸名，SONAME 保持不变） ----------
log "收集 .so 到 $DIST ..."
for lib in avcodec avformat avfilter avutil swresample swscale avdevice; do
  real=$(ls -1 "$BASE/src/ffmpeg/lib$lib/"lib$lib.so.* 2>/dev/null | grep -v '\.so$' | sort | tail -1)
  if [ -z "$real" ]; then
    echo "!! 缺少 lib$lib.so"; exit 1
  fi
  cp -f "$real" "$DIST/lib$lib.so"
  "$STRIP" "$DIST/lib$lib.so"
done

# ---------- 5. 体积报告 ----------
log "构建完成，产物体积（未压缩）："
ls -lS "$DIST" | awk 'NR>1 { printf "  %-28s %6.2f MB\n", $NF, $5/1048576 }'
